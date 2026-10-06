/// TLS for the control channel and the UDP media key (include/network/tls.h,
/// docs/SECURITY.md).
///
/// mbedTLS is built without MBEDTLS_THREADING_C (it has no Windows backend),
/// so this file keeps it safe across the server's threads itself:
/// - one random generator, behind a mutex;
/// - handshakes, the only code that touches the shared key (ECDSA, whose
///   curve caches tables on first use), run one step at a time under a
///   global mutex. The socket reads return WANT_READ instead of blocking, so
///   the mutex is never held while waiting for a slow client;
/// - each session's context behind its own mutex: the client's handler
///   thread reads while other threads write (control messages, frames).

#include "network/tls.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <mutex>
#include <sstream>
#include <vector>

#include <mbedtls/aes.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ecp.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/md.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/pk.h>
#include <mbedtls/platform_util.h>
#include <mbedtls/sha256.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <psa/crypto.h>

#ifdef _WIN32
#include <winsock2.h>
using NativeSocket = SOCKET;
constexpr int kSendFlags = 0;
#else
#include <sys/select.h>
#include <sys/socket.h>
using NativeSocket = int;
#ifdef MSG_NOSIGNAL
constexpr int kSendFlags = MSG_NOSIGNAL;
#else
constexpr int kSendFlags = 0;  // macOS: main() ignores SIGPIPE
#endif
#endif

namespace immersive::tls {
namespace {

constexpr const char* kSubject = "CN=immersive-host";

std::once_flag g_init;
std::mutex g_rng_mutex;
mbedtls_entropy_context g_entropy;
mbedtls_ctr_drbg_context g_drbg;
bool g_rng_ok = false;
std::mutex g_handshake_mutex;

void init() {
    std::call_once(g_init, [] {
        psa_crypto_init();
        mbedtls_entropy_init(&g_entropy);
        mbedtls_ctr_drbg_init(&g_drbg);
        static const char pers[] = "immersive2-host";
        g_rng_ok = mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy,
                                         reinterpret_cast<const unsigned char*>(pers),
                                         sizeof(pers) - 1) == 0;
        if (!g_rng_ok) std::cerr << "[TLS] No random source: encryption is off\n";
    });
}

int rng(void*, unsigned char* out, size_t len) {
    std::lock_guard<std::mutex> lock(g_rng_mutex);
    return mbedtls_ctr_drbg_random(&g_drbg, out, len);
}

std::string error_text(int ret) {
    char buf[160];
    mbedtls_strerror(ret, buf, sizeof(buf));
    std::ostringstream s;
    s << buf << " (-0x" << std::hex << -ret << ")";
    return s.str();
}

/// Wait until `sock` has something to read (or an error to report), up to
/// `timeout_ms` (< 0 = forever). False on timeout.
bool wait_readable(NativeSocket sock, int timeout_ms) {
    fd_set set;
    FD_ZERO(&set);
    FD_SET(sock, &set);
    timeval tv{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
    const int n = select(static_cast<int>(sock) + 1, &set, nullptr, nullptr,
                         timeout_ms < 0 ? nullptr : &tv);
    return n != 0;  // < 0: let recv() report the error
}

std::string read_file(const std::filesystem::path& path) {
    std::ifstream f(path, std::ios::binary);
    return f ? std::string(std::istreambuf_iterator<char>(f), {}) : std::string();
}

/// Write `data` to `path`, readable by this user only where that exists.
bool write_private(const std::filesystem::path& path, const std::string& data) {
    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
    { std::ofstream(path, std::ios::binary | std::ios::trunc); }  // create empty first
    std::filesystem::permissions(path, std::filesystem::perms::owner_read | std::filesystem::perms::owner_write,
                                 std::filesystem::perm_options::replace, ec);
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    f << data;
    return static_cast<bool>(f.flush());
}

class IdentityImpl final : public Identity {
public:
    IdentityImpl() {
        mbedtls_pk_init(&key_);
        mbedtls_x509_crt_init(&crt_);
        mbedtls_ssl_config_init(&conf_);
    }
    ~IdentityImpl() override {
        mbedtls_ssl_config_free(&conf_);
        mbedtls_x509_crt_free(&crt_);
        mbedtls_pk_free(&key_);
    }

    /// Parse a saved pair; false if it is missing, broken or mismatched.
    bool load(const std::string& key_pem, const std::string& cert_pem) {
        if (key_pem.empty() || cert_pem.empty()) return false;
        if (mbedtls_pk_parse_key(&key_, reinterpret_cast<const unsigned char*>(key_pem.c_str()),
                                 key_pem.size() + 1, nullptr, 0, rng, nullptr) != 0 ||
            mbedtls_x509_crt_parse(&crt_, reinterpret_cast<const unsigned char*>(cert_pem.c_str()),
                                   cert_pem.size() + 1) != 0 ||
            mbedtls_pk_check_pair(&crt_.pk, &key_, rng, nullptr) != 0) {
            mbedtls_x509_crt_free(&crt_);
            mbedtls_x509_crt_init(&crt_);
            mbedtls_pk_free(&key_);
            mbedtls_pk_init(&key_);
            return false;
        }
        pem_ = cert_pem;
        return true;
    }

    /// A new key and certificate; their PEM in *key_pem / *cert_pem.
    bool create(std::string* key_pem, std::string* cert_pem) {
        if (mbedtls_pk_setup(&key_, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY)) != 0 ||
            mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(key_), rng, nullptr) != 0)
            return false;
        mbedtls_x509write_cert w;
        mbedtls_x509write_crt_init(&w);
        unsigned char serial[16];
        rng(nullptr, serial, sizeof(serial));
        serial[0] &= 0x7F;  // a positive number
        std::vector<unsigned char> buf(4096);
        bool ok = mbedtls_x509write_crt_set_serial_raw(&w, serial, sizeof(serial)) == 0 &&
                  mbedtls_x509write_crt_set_subject_name(&w, kSubject) == 0 &&
                  mbedtls_x509write_crt_set_issuer_name(&w, kSubject) == 0 &&
                  mbedtls_x509write_crt_set_validity(&w, "20240101000000", "20991231235959") == 0;
        if (ok) {
            mbedtls_x509write_crt_set_version(&w, MBEDTLS_X509_CRT_VERSION_3);
            mbedtls_x509write_crt_set_md_alg(&w, MBEDTLS_MD_SHA256);
            mbedtls_x509write_crt_set_subject_key(&w, &key_);
            mbedtls_x509write_crt_set_issuer_key(&w, &key_);
            ok = mbedtls_x509write_crt_pem(&w, buf.data(), buf.size(), rng, nullptr) == 0;
        }
        mbedtls_x509write_crt_free(&w);
        if (!ok) return false;
        *cert_pem = reinterpret_cast<const char*>(buf.data());
        std::fill(buf.begin(), buf.end(), 0);
        if (mbedtls_pk_write_key_pem(&key_, buf.data(), buf.size()) != 0) return false;
        *key_pem = reinterpret_cast<const char*>(buf.data());
        std::fill(buf.begin(), buf.end(), 0);
        if (mbedtls_x509_crt_parse(&crt_, reinterpret_cast<const unsigned char*>(cert_pem->c_str()),
                                   cert_pem->size() + 1) != 0)
            return false;
        pem_ = *cert_pem;
        return true;
    }

    bool configure() {
        if (mbedtls_ssl_config_defaults(&conf_, MBEDTLS_SSL_IS_SERVER, MBEDTLS_SSL_TRANSPORT_STREAM,
                                        MBEDTLS_SSL_PRESET_DEFAULT) != 0 ||
            mbedtls_ssl_conf_own_cert(&conf_, &crt_, &key_) != 0)
            return false;
        mbedtls_ssl_conf_rng(&conf_, rng, nullptr);
        // TLS 1.2 only: no post-handshake messages, so reads never write.
        mbedtls_ssl_conf_min_tls_version(&conf_, MBEDTLS_SSL_VERSION_TLS1_2);
        mbedtls_ssl_conf_max_tls_version(&conf_, MBEDTLS_SSL_VERSION_TLS1_2);
        // Forward secrecy and AEAD only (no CBC suites, no RSA key exchange).
        static const int suites[] = {
            MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
            MBEDTLS_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
            MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
            0};
        mbedtls_ssl_conf_ciphersuites(&conf_, suites);
        return true;
    }

    const std::string& cert_pem() const override { return pem_; }

    std::string fingerprint() const override {
        unsigned char hash[32];
        mbedtls_sha256(crt_.raw.p, crt_.raw.len, hash, 0);
        static const char hex[] = "0123456789ABCDEF";
        std::string out;
        for (int i = 0; i < 8; ++i) {
            if (i && i % 2 == 0) out += ' ';
            out += hex[hash[i] >> 4];
            out += hex[hash[i] & 15];
        }
        return out;
    }

    bool persistent() const override { return persistent_; }

    const mbedtls_ssl_config* conf() const { return &conf_; }
    bool persistent_ = false;

private:
    mbedtls_pk_context key_;
    mbedtls_x509_crt crt_;
    mbedtls_ssl_config conf_;
    std::string pem_;
};

class SessionImpl final : public Session {
public:
    explicit SessionImpl(NativeSocket sock) : sock_(sock) { mbedtls_ssl_init(&ssl_); }
    ~SessionImpl() override { mbedtls_ssl_free(&ssl_); }

    bool start(const IdentityImpl& id, int timeout_s, std::string* error) {
        timeout_s_ = timeout_s;
        int ret = mbedtls_ssl_setup(&ssl_, id.conf());
        if (ret != 0) {
            *error = error_text(ret);
            return false;
        }
        mbedtls_ssl_set_bio(&ssl_, this, &SessionImpl::bio_send, &SessionImpl::bio_recv, nullptr);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeout_s);
        for (;;) {
            {
                std::lock_guard<std::mutex> lock(g_handshake_mutex);
                ret = mbedtls_ssl_handshake(&ssl_);
            }
            if (ret == 0) return true;
            if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
                *error = error_text(ret);
                return false;
            }
            const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now()).count();
            if (left <= 0 || !wait_readable(sock_, static_cast<int>(left))) {
                *error = "the handshake timed out";
                return false;
            }
        }
    }

    int read(void* buf, size_t size) override {
        for (;;) {
            int ret;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                ret = mbedtls_ssl_read(&ssl_, static_cast<unsigned char*>(buf), size);
            }
            if (ret > 0) return ret;
            if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) return 0;
            const int t = timeout_s_.load();
            if (!wait_readable(sock_, t > 0 ? t * 1000 : -1)) return 0;
        }
    }

    bool write(const void* buf, size_t size) override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto* p = static_cast<const unsigned char*>(buf);
        while (size > 0) {
            const int ret = mbedtls_ssl_write(&ssl_, p, size);
            if (ret <= 0) return false;  // the send BIO blocks: no WANT_WRITE
            p += ret;
            size -= static_cast<size_t>(ret);
        }
        return true;
    }

    void set_timeout(int seconds) override { timeout_s_ = seconds; }

    void close_notify() override {
        std::lock_guard<std::mutex> lock(mutex_);
        mbedtls_ssl_close_notify(&ssl_);
    }

private:
    static int bio_send(void* ctx, const unsigned char* buf, size_t len) {
        auto* s = static_cast<SessionImpl*>(ctx);
        const int n = ::send(s->sock_, reinterpret_cast<const char*>(buf), static_cast<int>(len), kSendFlags);
        return n > 0 ? n : MBEDTLS_ERR_NET_SEND_FAILED;
    }

    /// Never blocks: WANT_READ when nothing has arrived, so no lock is held
    /// while a client takes its time.
    static int bio_recv(void* ctx, unsigned char* buf, size_t len) {
        auto* s = static_cast<SessionImpl*>(ctx);
        if (!wait_readable(s->sock_, 0)) return MBEDTLS_ERR_SSL_WANT_READ;
        const int n = ::recv(s->sock_, reinterpret_cast<char*>(buf), static_cast<int>(len), 0);
        return n >= 0 ? n : MBEDTLS_ERR_NET_RECV_FAILED;  // 0: the peer closed
    }

    NativeSocket sock_;
    mbedtls_ssl_context ssl_;
    std::mutex mutex_;
    std::atomic<int> timeout_s_{0};
};

}  // namespace

std::shared_ptr<Identity> Identity::load_or_create(const std::filesystem::path& dir) {
    init();
    if (!g_rng_ok) return nullptr;
    const auto key_path = dir / "identity-key.pem";
    const auto cert_path = dir / "identity-cert.pem";
    auto id = std::make_shared<IdentityImpl>();
    if (id->load(read_file(key_path), read_file(cert_path))) {
        id->persistent_ = true;
    } else {
        std::string key_pem, cert_pem;
        if (!id->create(&key_pem, &cert_pem)) {
            std::cerr << "[TLS] Could not make this PC's key\n";
            return nullptr;
        }
        id->persistent_ = write_private(key_path, key_pem) && write_private(cert_path, cert_pem);
        if (id->persistent_)
            std::cout << "[TLS] Made this PC's identity (" << cert_path.string() << ")\n";
        else
            std::cerr << "[TLS] Could not save this PC's identity in " << dir.string()
                      << ": headsets will ask for the PIN again after a restart\n";
    }
    if (!id->configure()) {
        std::cerr << "[TLS] Could not set up TLS\n";
        return nullptr;
    }
    return id;
}

std::unique_ptr<Session> Session::accept(const Identity& identity, std::uintptr_t sock,
                                         int timeout_s, std::string* error) {
    auto s = std::make_unique<SessionImpl>(static_cast<NativeSocket>(sock));
    if (!s->start(static_cast<const IdentityImpl&>(identity), timeout_s, error))
        return nullptr;
    return s;
}

struct MediaCipher::Impl {
    std::array<uint8_t, kKeySize> key{};
    mbedtls_aes_context enc, dec, iv;
    std::atomic<uint64_t> counter{0};
    const mbedtls_md_info_t* md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);

    Impl() {
        mbedtls_aes_init(&enc);
        mbedtls_aes_init(&dec);
        mbedtls_aes_init(&iv);
    }
    ~Impl() {
        mbedtls_aes_free(&enc);
        mbedtls_aes_free(&dec);
        mbedtls_aes_free(&iv);
        mbedtls_platform_zeroize(key.data(), key.size());
    }
    void set(const uint8_t* k) {
        std::memcpy(key.data(), k, kKeySize);
        mbedtls_aes_setkey_enc(&enc, key.data(), 128);
        mbedtls_aes_setkey_dec(&dec, key.data(), 128);
        uint8_t iv_key[16];
        rng(nullptr, iv_key, sizeof(iv_key));
        mbedtls_aes_setkey_enc(&iv, iv_key, 128);
        mbedtls_platform_zeroize(iv_key, sizeof(iv_key));
    }
};

MediaCipher::MediaCipher() : impl_(std::make_unique<Impl>()) {
    init();
    uint8_t k[kKeySize];
    rng(nullptr, k, sizeof(k));
    impl_->set(k);
    mbedtls_platform_zeroize(k, sizeof(k));
}

MediaCipher::MediaCipher(const uint8_t key[kKeySize]) : impl_(std::make_unique<Impl>()) {
    init();
    impl_->set(key);
}

MediaCipher::~MediaCipher() = default;

const uint8_t* MediaCipher::key() const { return impl_->key.data(); }

size_t MediaCipher::seal(const uint8_t* in, size_t size, uint8_t* out) const {
    uint8_t block[16] = {};
    const uint64_t n = impl_->counter.fetch_add(1);
    std::memcpy(block, &n, sizeof(n));
    mbedtls_aes_crypt_ecb(&impl_->iv, MBEDTLS_AES_ENCRYPT, block, out);  // the IV
    const size_t padded = (size / 16 + 1) * 16;
    std::memmove(out + 16, in, size);
    std::memset(out + 16 + size, static_cast<int>(padded - size), padded - size);
    uint8_t iv[16];
    std::memcpy(iv, out, 16);
    mbedtls_aes_crypt_cbc(&impl_->enc, MBEDTLS_AES_ENCRYPT, padded, iv, out + 16, out + 16);
    uint8_t tag[32];
    mbedtls_md_hmac(impl_->md, impl_->key.data() + 16, 32, out, 16 + padded, tag);
    std::memcpy(out + 16 + padded, tag, 16);
    return 16 + padded + 16;
}

long MediaCipher::open(const uint8_t* in, size_t size, uint8_t* out) const {
    if (size < 48 || (size - 32) % 16 != 0) return -1;
    const size_t body = size - 32;
    uint8_t tag[32];
    mbedtls_md_hmac(impl_->md, impl_->key.data() + 16, 32, in, 16 + body, tag);
    uint8_t diff = 0;  // constant time
    for (int i = 0; i < 16; ++i) diff |= static_cast<uint8_t>(tag[i] ^ in[16 + body + i]);
    if (diff) return -1;
    uint8_t iv[16];
    std::memcpy(iv, in, 16);
    mbedtls_aes_crypt_cbc(&impl_->dec, MBEDTLS_AES_DECRYPT, body, iv, in + 16, out);
    const uint8_t pad = out[body - 1];
    if (pad < 1 || pad > 16) return -1;
    return static_cast<long>(body - pad);
}

}  // namespace immersive::tls
