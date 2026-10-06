#pragma once

/// Encryption between the host and the headsets (docs/SECURITY.md).
///
/// - Identity: this PC's long-term key and self-signed certificate, made once
///   and kept in the config directory. Headsets pin it the first time they
///   pair and refuse any other afterwards; its fingerprint is what the person
///   at the PC compares with the one the headset shows while pairing.
/// - Session: TLS 1.2 (ECDHE-ECDSA, AEAD only) over a client's TCP control
///   socket. Reads and writes may come from different threads.
/// - MediaCipher: the key of one client's UDP video and audio, sent to it
///   inside its TLS session (MEDIA_KEY); every datagram is sealed with it.
///
/// mbedTLS stays inside tls.cpp: nothing here needs its headers.

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

namespace immersive::tls {

class Identity {
public:
    /// <dir>/identity-key.pem and <dir>/identity-cert.pem, made the first
    /// time (ECDSA P-256, CN=immersive-host). If they cannot be read or
    /// written, an identity for this run only (headsets would ask to pair
    /// again next time); nullptr only if no key can be made at all.
    static std::shared_ptr<Identity> load_or_create(const std::filesystem::path& dir);

    virtual ~Identity() = default;
    /// The certificate in PEM, as sent in IDENTITY.
    virtual const std::string& cert_pem() const = 0;
    /// The first 8 bytes of SHA-256 of the certificate (DER) as
    /// "1A2B 3C4D 5E6F 7A8B": what the headset shows when it asks for the PIN.
    virtual std::string fingerprint() const = 0;
    /// False when this identity could not be saved (it lasts this run only).
    virtual bool persistent() const = 0;
};

class Session {
public:
    /// The server side of a TLS handshake on `sock`, a connected TCP socket
    /// whose first byte is a TLS record. `timeout_s` bounds every wait for
    /// the client. nullptr on failure, with the reason in *error.
    static std::unique_ptr<Session> accept(const Identity& identity, std::uintptr_t sock,
                                           int timeout_s, std::string* error);

    virtual ~Session() = default;
    /// Up to `size` bytes; blocks until at least one. 0: closed, failed, or
    /// nothing for the timeout (set_timeout).
    virtual int read(void* buf, size_t size) = 0;
    /// All of `size` bytes, or false (the connection is unusable then).
    virtual bool write(const void* buf, size_t size) = 0;
    /// Seconds a read waits for the client; 0 = forever (keepalive notices a
    /// dead peer, and shutdown() of the socket ends the wait).
    virtual void set_timeout(int seconds) = 0;
    /// Tell the client we close (best effort).
    virtual void close_notify() = 0;
};

/// One client's UDP media key: AES-128-CBC, then HMAC-SHA-256 (first 16
/// bytes) over the IV and the ciphertext. A sealed datagram is
///   IV (16) | AES-128-CBC(PKCS#7-padded datagram) | tag (16).
/// IVs are AES of a counter under a second key that never leaves the host:
/// unique and unpredictable. seal() and open() may run on many threads.
class MediaCipher {
public:
    static constexpr size_t kKeySize  = 48;  ///< MEDIA_KEY: AES key (16) | HMAC key (32)
    static constexpr size_t kOverhead = 48;  ///< at most: IV, padding, tag

    MediaCipher();  ///< fresh random keys
    /// With a given MEDIA_KEY (tests, and the open() side).
    explicit MediaCipher(const uint8_t key[kKeySize]);
    ~MediaCipher();
    MediaCipher(const MediaCipher&) = delete;
    MediaCipher& operator=(const MediaCipher&) = delete;

    const uint8_t* key() const;
    /// Seal `size` bytes into `out` (room for size + kOverhead); the sealed size.
    size_t seal(const uint8_t* in, size_t size, uint8_t* out) const;
    /// Check and decrypt a sealed datagram into `out` (room for `size`
    /// bytes): the datagram's size, or -1 if it is not one of ours.
    long open(const uint8_t* in, size_t size, uint8_t* out) const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace immersive::tls
