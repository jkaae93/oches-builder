# Noise IK End-to-End Channel and User Enrolled Keys

## ADDED Requirements

### Requirement: User-enrolled key separation and lifecycle
Client enrollment SHALL separate signing and Noise static keys, classify enrolled clients strictly as `USER_ENROLLED_KEY`, lock out after 5 invalid comparison codes, fail closed without plaintext fallback on `KEY_UNAVAILABLE`, and propagate rotation and revocation immediately.

#### Scenario: Comparison lockout, key unavailability, and revocation
- **WHEN** 5 invalid comparison codes are entered, the key vault is unavailable, or a client is rotated/revoked
- **THEN** enrollment locks out, missing vaults throw `keyUnavailable`, and old static keys or revoked clients are rejected immediately

### Requirement: Noise IK handshake, 0-RTT blocking, chunking, and 4 KiB padding (V-22 / V-23)
`Noise_IK_25519_ChaChaPoly_SHA256` SHALL bind the JCS prologue hash, reject any 0-RTT payload, enforce 256 KiB message limits with 60 KiB chunks and 4 KiB padding buckets, close on any decryption/sequence/padding error, and require Desktop per-request approvals bound to the command digest for privileged operations.

#### Scenario: Cross-implementation vectors, 0-RTT, and command tamper rejection
- **WHEN** Swift `CryptoKit` and Node.js OpenSSL run identical inputs, a 0-RTT byte is injected, or a privileged command payload differs from the Desktop approval digest
- **THEN** Swift and Node produce byte-identical frames, 0-RTT rejects with `zeroRTTForbidden`, and tampered/relayed commands reject
