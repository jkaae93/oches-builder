# IMP-18 USER_ENROLLED_KEY and Noise IK channel progress

Date: 2026-11-19. Issue: #18. OpenSpec: `imp-18-noise-ik-channel`.

## Implemented components

- **Noise IK End-to-End Encrypted Framing** (`core/Sources/OchesCore/NoiseIKChannel.swift`):
  - Implements standard Noise Revision 34 `Noise_IK_25519_ChaChaPoly_SHA256` on Apple `CryptoKit` (`Curve25519.KeyAgreement`, `ChaChaPoly`, `SHA256`, `HMAC<SHA256>`).
  - Binds RFC 8785 JCS SHA-256 prologue hash (`[protocolMajor, "Noise_IK_25519_ChaChaPoly_SHA256", coreID, clientID, enrollmentGeneration, clientRole]`).
  - Strictly rejects any 0-RTT payload in handshake messages (`.zeroRTTForbidden`), enforces 256 KiB logical message cap (W1), splits messages into 60 KiB (`61,440`-byte) max plaintext chunks (`<= 65,535` byte Noise limit) with monotonic `chunkIndex`, supports 4 KiB padding buckets for sensitive responses, and permanently closes the channel while clearing partial buffers on any AEAD, sequence, or padding error.
- **User-Enrolled Key Lifecycle & Desktop Per-Request Approvals** (`core/Sources/OchesCore/EnrolledKeyChannelAuthority.swift`):
  - Enforces key separation (`Ed25519` signing key != `X25519` Noise static key), classifies enrolled clients strictly as `USER_ENROLLED_KEY`, enforces T7 5-attempt comparison code lockout, models fail-closed key vault unavailability (`KEY_UNAVAILABLE`, 0 plaintext fallback), propagates rotation/revocation immediately, and verifies + atomically consumes Desktop approvals bound to the JCS command digest and single-use nonces on privileged operations (`workspace:write`, `run:request`, `context:submit`, V-22).
- **Independent Cross-Implementation Reference** (`core/contracts/noise_ik_reference.mjs`):
  - Pure Node.js OpenSSL `crypto` implementation of `Noise_IK_25519_ChaChaPoly_SHA256` + 4 KiB padded chunk framing.

## Verification

- `node oches-builder/core/contracts/noise_ik_reference.mjs --self-test`: passed.
- `openspec validate imp-18-noise-ik-channel --strict`: passed.
- `swift test --package-path oches-builder/core --filter NoiseIKChannelTests`: **3/3 tests passed**, including byte-for-byte cross-implementation vector and mutual encryption/decryption verification between Swift `CryptoKit` and Node.js OpenSSL `crypto` (V-22, V-23).
- `swift test --package-path oches-builder/core`: full Core suite passed.

## Remaining product gates (issue #18 remains open)

- Integration into Chrome MV3 Native Messaging (`IMP-19`) and VS Code local extension (`IMP-20`) follows in the next wave.
