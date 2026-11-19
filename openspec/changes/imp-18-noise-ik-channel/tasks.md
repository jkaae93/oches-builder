# Tasks

- [x] Create OpenSpec specification for IMP-18 `USER_ENROLLED_KEY` and `Noise_IK_25519_ChaChaPoly_SHA256`.
- [x] Implement `NoiseIKChannel` with JCS prologue binding, 0-RTT rejection, 60 KiB chunks, 4 KiB padding buckets and fail-closed session closure.
- [x] Implement `EnrolledKeyChannelAuthority` with key separation, 5-attempt comparison limits, key-vault unavailability blocking, rotation, revocation and Desktop per-request approvals.
- [x] Implement independent Node.js OpenSSL reference verifier (`core/contracts/noise_ik_reference.mjs`) and Swift cross-implementation vector/security regression tests (`NoiseIKChannelTests.swift`), and record evidence (`docs/imp-18-noise-channel-evidence.md`).
- [ ] Integrate Chrome MV3 Native Messaging and VS Code Extension clients over this Noise IK transport (IMP-19 / IMP-20).
