# Design

## Context

`ARC-11-G3-MACOS-DESIGN.md` specifies `xpc_connection_set_peer_team_identity_requirement` with exact Team ID + signing identifier in both directions, single-requirement configuration per connection, Keychain/Secure Enclave key protection without plaintext fallback, and blocking high-risk changes until signed positive control passes.

## Goals / Non-Goals

**Goals:** real Mach-O signature inspection via `Security.framework`, fail-closed connection guards, `KEY_UNAVAILABLE` key-store boundary, restricted bootstrap discovery, atomic key rotation/revocation in SQLite, and fail-closed risk-mutation gating.

**Non-Goals:** live Developer ID certificate provisioning or Windows/Linux named-pipe/Unix-socket authentication.

## Decisions

- `MachOCodeSignatureInspector` checks static Mach-O signatures using `SecStaticCodeCreateWithPath`, `SecCodeCopySigningInformation`, `SecRequirementCreateWithString`, and `SecStaticCodeCheckValidity` with `anchor apple generic and identifier "<id>" and certificate leaf[subject.OU] = "<team>"`.
- `XPCConnectionRequirementGuard` tracks configuration state so duplicate requirement setup throws `.duplicateRequirementConfiguration`.
- `ClientIdentityAndKeyRegistry` stores `registered_clients` and `client_sessions` in `SQLiteStore`, revoking the previous key and closing sessions in `BEGIN IMMEDIATE` before activating a newly confirmed key, and refusing automatic rollback if rotation fails mid-way.

## Risks / Trade-offs

- [Ad-hoc test builds lack a real Apple Developer Team ID] → `verifyRiskMutationGate` blocks risky mutations unless `distributionSignedPeerVerified == true` is explicitly established from a verified distribution-signed peer.

## Migration Plan

Additive `registered_clients`, `xpc_challenges`, and `client_sessions` tables in SQLite (`CREATE TABLE IF NOT EXISTS`).
