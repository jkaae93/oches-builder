# Proposal

## Why

`IMP-02` and `IMP-03` establish durable SQLite transactions and peer/key authentication, but risky operations (`CONFIG_EXPORT_APPLY`, `EXECUTION`, `EXTERNAL_TRANSFER`, `TEMPLATE_IMPORT_CONFIRM`) and differentiated read scopes (`workspace:read`, `run:observe`, `diagnostics:read`, `observation:raw:read`) require policy evaluation, per-request cryptographic/digest-bound approvals, pre-execution path/revision/scope revalidation, and atomic audit logging (`ARC-09`, `CLIENT_INSTALLATION_AUTH_DESIGN`).

## What Changes

- Define `PermissionScope`, separate approval kinds (`ApprovalKind`), kind-specific `ApprovalBinding` validation (`ARC-09` v0.3), and `PolicyEngine` (failing closed on `unknown`, unverified enforcement boundaries, and missing `approval:decide` trusted UI origin).
- Implement `AuthorizationEnforcer` backed by SQLite (`approvals`, `auth_nonces`, `audit_log` tables) performing atomic pre-execution revalidation (client active status, policy version, workspace, symlink-resolved canonical target path inside workspace root, `expectedRevision`, `preparedAttemptID`, JCS `requestDigest`, expiration, non-revoked/unconsumed state, and mandatory separate `externalTransfer` approval when external transfer occurs).
- Enforce mandatory audit logging in the same SQLite `BEGIN IMMEDIATE` transaction (rolling back and failing closed with `UNAVAILABLE` if audit write fails), single-use nonce consumption, and lost-response idempotent retrieval via fresh nonce (`retryRetrieveResultWithFreshNonce`).

Explicit non-goals: Provider execution runtime (IMP-07), Noise IK extension transport (IMP-18), and macOS OS sandbox/provider enforcement outside Core DB boundaries (`NOT RUN`).

## Capabilities

### New Capabilities

- `policy-approval-authz`: Policy evaluation, separated approval bindings, canonical path & revision TOCTOU revalidation, atomic audit logging, and single-use nonce authorization.

### Modified Capabilities

None.

## Impact

- `docs/architecture/ARC-09.md`
- `docs/architecture/CLIENT_INSTALLATION_AUTH_DESIGN.md`
- `core/Sources/OchesCore/PolicyAndApproval.swift`
- `core/Sources/OchesCore/AuthorizationEnforcer.swift`
