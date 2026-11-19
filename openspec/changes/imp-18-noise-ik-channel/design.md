# Design

Follow `EXTENSION_SECURE_CHANNEL.md`, `CLIENT_INSTALLATION_AUTH_DESIGN.md`, `ADR-017`, and frozen T2/T6/T7/W1.

1. `NoiseIKChannel` implements standard Noise Revision 34 `Noise_IK_25519_ChaChaPoly_SHA256` on Apple `CryptoKit` (`Curve25519.KeyAgreement`, `ChaChaPoly`, `SHA256`, `HMAC<SHA256>`). Handshake prologue binds RFC 8785 JCS SHA-256 of `[protocolMajor, "Noise_IK_25519_ChaChaPoly_SHA256", coreID, clientID, enrollmentGeneration, clientRole]`.
2. Zero-RTT blocking: initiator message 1 is strictly 96 bytes (`e_pub[32] || enc_s[48] || enc_empty[16]`) and message 2 is strictly 48 bytes (`re_pub[32] || enc_empty[16]`). Any non-empty handshake payload is rejected with `.zeroRTTForbidden`.
3. Transport framing enforces the 256 KiB logical message cap (W1), splits payloads into 21-byte-header chunks bounded to 60 KiB (`61,440` bytes) plaintext (`61,456 <= 65,535` byte Noise limit), pads sensitive responses to 4 KiB (`4,096`-byte) buckets, and permanently closes the channel while discarding partial buffers on any AEAD, sequence, or padding error.
4. `EnrolledKeyChannelAuthority` stores `USER_ENROLLED_KEY` clients in SQLite (`enrolled_noise_clients`, `enrollment_code_attempts`), enforces separated signing and Noise static keys, enforces T7 5-attempt comparison code lockouts, models fail-closed key vaults (`KEY_UNAVAILABLE` with 0 plaintext fallback), propagates key rotation/revocation immediately, and enforces Desktop per-request approvals bound to the JCS command digest and single-use nonces on privileged scopes.
5. `core/contracts/noise_ik_reference.mjs` provides an independent Node.js OpenSSL `crypto` reference implementation cross-verified byte-for-byte against Swift `CryptoKit`.
