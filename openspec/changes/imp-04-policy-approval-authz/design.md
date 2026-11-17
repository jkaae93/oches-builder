# Design

## Context

`ARC-09.md` v0.3 separates apply, execution, external transfer, and template import approvals and binds every approval to subject, workspace, normalized target, scope, revision, JCS digest, policy version, and expiration/revocation state. `CLIENT_INSTALLATION_AUTH_DESIGN.md` requires atomic nonce/approval consumption with `audit_log` in SQLite and blocking execution on audit failure.

## Goals / Non-Goals

**Goals:** enforce strict separation of approval kinds and permission scopes, reject unverified enforcement boundaries even with user confirmation, revalidate symlink-resolved target paths and revisions immediately before execution inside `BEGIN IMMEDIATE`, and support safe lost-response retries via fresh single-use nonces.

**Non-Goals:** replacing OS-level filesystem sandboxing for arbitrary child processes (`IMP-06/07/15`).

## Decisions

- `PermissionScope` separates `workspace:read`, `run:observe`, `diagnostics:read`, and `observation:raw:read`; `approval:decide` is restricted to verified `.platformBound` Desktop trusted UI sessions.
- `ApprovalBinding` enforces kind-specific non-null fields (`preparedAttemptID` mandatory for `.execution`; `providerID`/`accountRef`/`recipientScope`/`inputDigest` mandatory for `.externalTransfer`).
- `AuthorizationEnforcer` resolves symlinks via `URL(fileURLWithPath:).resolvingSymlinksInPath()` and rejects any path escaping the workspace root or differing from the approved `normalizedTarget`.
- `audit_log` failure injection/error inside `BEGIN IMMEDIATE` rolls back nonce consumption, approval consumption, and state mutations.

## Risks / Trade-offs

- [External filesystem changes between revalidation and child-process use] → minimize window by checking canonical path inside `BEGIN IMMEDIATE` right before commit, and explicitly report boundary limits until sandboxed adapters run.

## Migration Plan

Additive `approvals`, `auth_nonces`, and `audit_log` tables in SQLite (`CREATE TABLE IF NOT EXISTS`).
