extends SceneTree
## Sealed UDP media and the PC's fingerprint (docs/PROTOCOL.md, Sealed
## datagrams; docs/SECURITY.md), headless:
##   godot --headless --xr-mode off --path client/project \
##       -s "$PWD/client/tests/seal_test.gd"
## The vectors were made outside Godot (Python, `cryptography` and hashlib),
## the way the host seals (tls.cpp MediaCipher) and fingerprints. Prints
## "RESULT fails=N".

const NetworkClient := preload("res://scripts/network_client.gd")

## key = bytes 0..47; the datagram 02 01 02 .. 27 (40 bytes); IV = 16 x A5.
const SEALED := "a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a55ad93282157b9d5fa03c6f7710baf16a0e88ab9415a128870944358c98ed4d450ccd2c01ab3eeb261fc84413897e2a3839f5accb960daf19b0b2bd97e1e0e7cd"
const PLAIN := "020102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021222324252627"

const CERT := """-----BEGIN CERTIFICATE-----
MIIBMjCB2qADAgECAhBkPvMemwomipGFK5l//YBqMAoGCCqGSM49BAMCMBkxFzAV
BgNVBAMMDmltbWVyc2l2ZS1ob3N0MCAXDTI0MDEwMTAwMDAwMFoYDzIwOTkxMjMx
MjM1OTU5WjAZMRcwFQYDVQQDDA5pbW1lcnNpdmUtaG9zdDBZMBMGByqGSM49AgEG
CCqGSM49AwEHA0IABJmkmoTg2s6y9Vgzsgjcg0hJ3/laEDNd5NrDptbBSwozje5B
lt7458p8mrpZZgdME7JWQflMvEhUb89ovVWK8RyjAjAAMAoGCCqGSM49BAMCA0cA
MEQCIGOf34rlMj/Mzs2K5P7BnzMTysnxLwC68vQ1Bo7wrVy7AiAS4YNvBDzzJs0l
HMCUwdYczzfPqgK40o2/a4t//C7mwg==
-----END CERTIFICATE-----
"""

var fails := 0

func check(cond: bool, what: String) -> void:
	print(("ok   " if cond else "FAIL ") + what)
	if not cond:
		fails += 1

func _initialize() -> void:
	var key := PackedByteArray()
	for i in 48:
		key.append(i)
	var opener = NetworkClient.SealOpener.new(key)
	var sealed := SEALED.hex_decode()
	check(opener.open(sealed) == PLAIN.hex_decode(), "a datagram sealed by the host's rule opens to itself")

	var changed := sealed.duplicate()
	changed[20] ^= 1
	check(opener.open(changed).is_empty(), "one bit changed in the ciphertext: dropped")
	changed = sealed.duplicate()
	changed[changed.size() - 1] ^= 1
	check(opener.open(changed).is_empty(), "one bit changed in the tag: dropped")
	check(opener.open(sealed.slice(0, sealed.size() - 16)).is_empty(), "cut short: dropped")
	check(opener.open(PLAIN.hex_decode()).is_empty(), "a plain datagram: dropped")
	var other := key.duplicate()
	other[40] ^= 1
	check(NetworkClient.SealOpener.new(other).open(sealed).is_empty(), "another connection's key: dropped")

	check(NetworkClient.fingerprint(CERT) == "4F3C C877 7CC3 E350",
		"fingerprint as the PC shows it -> %s" % NetworkClient.fingerprint(CERT))
	check(NetworkClient.fingerprint(CERT.replace("\n", "\r\n")) == "4F3C C877 7CC3 E350", "CRLF lines too")
	check(NetworkClient.fingerprint("not a certificate").is_empty(), "nothing for garbage")
	var cert := X509Certificate.new()
	check(cert.load_from_string(CERT) == OK, "the host's certificate loads as a TLS trust anchor")

	print("RESULT fails=%d" % fails)
	quit(1 if fails else 0)
