# Tasks: IMP-04 Policy, Per-Request Approvals, and Authorization

## 1. Policy Engine and Separated Approval Bindings (Sub-PR A)

- [x] 1.1 Create `imp-04-policy-approval-authz` OpenSpec change and validate schema.
- [x] 1.2 Implement `PermissionScope`, `ApprovalKind`, kind-specific `ApprovalBinding` validation (`ARC-09` v0.3), and `PolicyEngine` in `PolicyAndApproval.swift`.
- [x] 1.3 Add unit tests for approval binding requirements, scope separation (`FC-09`), unknown-policy denial, and trusted UI restriction on `approval:decide`.

## 2. Pre-Execution Atomic Revalidation, TOCTOU Prevention, and Audit Enforcement (Sub-PR B)

- [x] 2.1 Implement `AuthorizationEnforcer` with `approvals`, `auth_nonces`, and `audit_log` tables in SQLite.
- [x] 2.2 Add V-09/V-13/FC-03/FC-09/X10/X23 regression tests: post-approval path/symlink escape, revocation, expiration, scope change, cross-attempt reuse, missing transfer approval, concurrent TOCTOU races, lost-response fresh-nonce retry, and audit-write failure rollback.
- [x] 2.3 Sync `policy-approval-authz` spec to `openspec/specs/` and archive `imp-04-policy-approval-authz`.
