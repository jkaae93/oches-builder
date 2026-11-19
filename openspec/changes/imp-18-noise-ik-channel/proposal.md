# Proposal

Implement IMP-18 `USER_ENROLLED_KEY` lifecycle (enrollment with T7 5-attempt comparison codes, separated Ed25519 signing and X25519 Noise static keys, rotation, immediate revocation, fail-closed key storage) and standard `Noise_IK_25519_ChaChaPoly_SHA256` end-to-end encrypted framing (JCS prologue, 0-RTT rejection, 60 KiB chunking, 4 KiB padding buckets, Desktop per-request approvals, and cross-implementation test vectors).
