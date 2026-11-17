# ADR-021: macOS Mutual XPC Peer Identity and Protected Key Boundary

Status: Accepted for IMP-03 Phase 1 macOS arm64 implementation, 2026-11-17. Refs #3, Refs #23.

## Context

`ARC-11.md`, `ARC-11-G3-MACOS-DESIGN.md`, and `ADR-016` select mutual macOS XPC peer code signing verification (`xpc_connection_set_peer_team_identity_requirement` with exact signing identifier and matching Team ID) and hardware/Keychain-protected installation keys for Desktop↔Core communication, while failing closed when signing posture or key access cannot be proven.

## Decision

1. Model peer code-signing posture explicitly (`distributionSigned(teamID, signingIdentifier)`, `adHoc(signingIdentifier)`, `unsigned`, `invalid`), and inspect Mach-O binaries using Apple's `Security` framework (`SecStaticCodeCreateWithPath`, `SecCodeCopySigningInformation`, `SecRequirementCreateWithString`, `SecStaticCodeCheckValidity`).
2. Enforce single-configuration per XPC connection in `XPCConnectionRequirementGuard`: applying a peer requirement more than once on the same connection is treated as a programming/configuration error and fails closed.
3. Require mutual `distributionSigned` posture matching both `expectedTeamID` and `expectedSigningIdentifier` before granting privileged Desktop↔Core sessions. Reject `adHoc`, `unsigned`, wrong Team ID, wrong signing identifier, UID/PID-only claims, and unverified direct Host invocations.
4. Keep risky mutations/executions gated behind verified distribution-signed positive control (`verifyRiskMutationGate`). Without a verified distribution-signed peer positive control in the deployment environment, risky mutations stay blocked fail-closed.
5. Protect signing keys (P-256) and Noise static X25519 keys through `ProtectedKeyStore` abstractions targeting Secure Enclave / Keychain ACLs; when keys are locked or inaccessible, fail closed with `KEY_UNAVAILABLE` (`UNAVAILABLE`) and forbid plaintext file fallback.

## Consequences and Verification

- Positive and negative controls can be tested locally via real `clang` + `codesign` Mach-O binaries (ad-hoc, tampered bytes, mismatched identifier), connection guard unit tests, key rotation/revocation SQLite lifecycle tests, and risk-gate rejection tests.
- Live Developer ID / Apple-notarized distribution binary positive control across installed `.app` bundles and live `xpc_connection_t` endpoints remains `NOT RUN` until signed release artifacts exist; Windows and Linux remain `NOT RUN`.
