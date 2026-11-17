## ADDED Requirements

### Requirement: Separated approval kinds and strict binding validation
Config apply, execution, external transfer, and template import approvals SHALL remain distinct `ApprovalKind`s with mandatory kind-specific bindings (`preparedAttemptID` for execution; recipient/input digest for external transfer), and execution approval SHALL NOT substitute for external transfer approval.

#### Scenario: Missing external transfer approval or reused attempt approval
- **WHEN** an execution with external transfer lacks a valid `EXTERNAL_TRANSFER` approval or presents an `EXECUTION` approval bound to another `attemptId`
- **THEN** authorization rejects the request with `APPROVAL_REQUIRED` or `DENIED` and performs zero side effects

### Requirement: Scope separation and fail-closed policy evaluation
Read scopes (`workspace:read`, `run:observe`, `diagnostics:read`, `observation:raw:read`) SHALL remain distinct, `approval:decide` SHALL be restricted to verified Desktop trusted UI sessions, and `unknown` or unverified enforcement boundaries SHALL never evaluate to `allow`.

#### Scenario: Diagnostics client requests raw observation
- **WHEN** a client holding `diagnostics:read` and `workspace:read` without `observation:raw:read` requests raw observation text
- **THEN** the policy engine denies access without disclosing raw content

### Requirement: Pre-execution atomic revalidation, audit coupling, and TOCTOU serialization
Authorization SHALL atomically revalidate active client registration, policy version, workspace, symlink-resolved canonical target path within workspace root, `expectedRevision`, `preparedAttemptID`, canonical JCS request digest, expiration, unconsumed approval, single-use nonce, and mandatory `audit_log` insertion in one SQLite `BEGIN IMMEDIATE` transaction.

#### Scenario: Target path modified or symlink swapped after approval
- **WHEN** the target path or symlink target changes or escapes the workspace root after approval issuance
- **THEN** pre-execution revalidation rejects the request without consuming state or producing external effects

#### Scenario: Audit log insertion failure
- **WHEN** writing the `audit_log` record fails during authorization commit
- **THEN** the entire SQLite transaction rolls back and returns `UNAVAILABLE` with zero consumed approvals or state mutations

#### Scenario: Concurrent TOCTOU race and lost-response retry
- **WHEN** concurrent execution requests race against each other or against revocation, or a client retries lost output with a fresh single-use nonce
- **THEN** `BEGIN IMMEDIATE` serializes at most one execution, revocation blocks unconsumed execution, and fresh-nonce retry returns the cached idempotent result once without re-consuming execution approval
