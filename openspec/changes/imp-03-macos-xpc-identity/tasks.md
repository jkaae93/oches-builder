# Tasks: IMP-03 macOS XPC Mutual Identity & Key Protection

## 1. Peer Identity Guards, Mach-O Signature Inspection, and Protected Key Store (Sub-PR A)

- [x] 1.1 Record design decisions in `ADR-021-macos-xpc-key-boundary.md` and create `imp-03-macos-xpc-identity` OpenSpec change.
- [x] 1.2 Implement `CodeSigningPosture`, `PeerIdentityRequirement`, `XPCConnectionRequirementGuard`, `MachOCodeSignatureInspector`, and `ProtectedKeyStore` with `KEY_UNAVAILABLE` fail-closed semantics.
- [x] 1.3 Add regression tests using real `clang` + `codesign` Mach-O binaries (ad-hoc, tampered, identifier mismatch) and key-store lock/unavailable failures.

## 2. Service Discovery, Key Rotation/Revocation, and Risk Gate (Sub-PR B)

- [ ] 2.1 Implement `CoreBootstrapDescriptor` and `ClientIdentityAndKeyRegistry` in SQLite (challenge auth, `rotateClientKey`, `revokeClient`, `verifyRiskMutationGate`).
- [ ] 2.2 Add tests for bootstrap restriction, key rotation interruption/simultaneous-key denial, revocation session termination, and risk-mutation gate before distribution-signed positive control.
- [ ] 2.3 Sync `macos-xpc-identity` spec to `openspec/specs/` and archive `imp-03-macos-xpc-identity`.
