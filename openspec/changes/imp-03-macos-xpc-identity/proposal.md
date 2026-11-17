# Proposal

## Why

`IMP-01` and `IMP-02` establish wire validation and durable SQLite storage, but Desktop↔Core requests cannot be trusted until mutual macOS peer identity verification, Keychain/Secure Enclave key protection, unauthenticated bootstrap restriction, key rotation/revocation, and a fail-closed risk-mutation gate are enforced (`ARC-11`, `ARC-11-G3-MACOS-DESIGN`).

## What Changes

- Implement macOS code-signing inspection (`Security` framework) and `XPCConnectionRequirementGuard` enforcing single-requirement configuration and mutual Team ID + signing identifier verification (rejecting ad-hoc, unsigned, wrong Team ID, tampered binaries, and UID/PID-only claims).
- Implement `ProtectedKeyStore` for P-256 signing and X25519 Noise key agreement failing closed with `KEY_UNAVAILABLE` and forbidding plaintext fallback.
- Implement `CoreBootstrapDescriptor` service discovery exposing only protocol version bounds and public Core key identifiers before mutual authentication, blocking `command`, `observe`, and `snapshot`.
- Implement SQLite-backed `ClientIdentityAndKeyRegistry` with single-use connection-bound challenges, fail-closed `rotateClientKey` (revokes old key and sessions first; no simultaneous active keys or auto-rollback on interruption), `revokeClient` (increments policy version, closes sessions, rejects future requests), and `verifyRiskMutationGate` blocking risky mutations without verified distribution-signed positive control.

Explicit non-goals: Extension Noise IK channel (IMP-18), Chrome/VS Code hosts (IMP-19/20), and live Developer ID notarized bundle distribution tests (`NOT RUN`).

## Capabilities

### New Capabilities

- `macos-xpc-identity`: Mutual macOS peer identity verification, Keychain/Secure Enclave key protection, discovery, key rotation/revocation, and risk-mutation gate.

### Modified Capabilities

None.

## Impact

- `docs/architecture/ARC-11.md`
- `docs/architecture/ARC-11-G3-MACOS-DESIGN.md`
- `docs/architecture/adr/ADR-021-macos-xpc-key-boundary.md`
- `core/Sources/OchesCore/MacOSXPCIdentity.swift`
- `core/Sources/OchesCore/ServiceDiscoveryAndKeyLifecycle.swift`
