# Memory and Context Management

## ADDED Requirements

### Requirement: Evidence-backed memory lifecycle and Dreaming gate
Memories SHALL bind to explicit evidence references, enforce a 90-day expiration on `Verified` status, represent entries in Markdown with YAML frontmatter, and reject Dreaming execution/proposals in v1.

#### Scenario: Memory verification and Dreaming v1 rejection
- **WHEN** a candidate memory has valid unrevoked evidence or a caller invokes Dreaming
- **THEN** verification sets `expiresAt = verifiedAt + 90 days`, and Dreaming fails with `dreamingUnsupportedV1`

### Requirement: Bounded context selection and pre-transfer revalidation
`ContextBuilder` SHALL enforce a 64 KiB context budget and explicit exclusion/partial-timeout accounting without executing external transfers during `selectContext`, and SHALL re-verify canonical memory, scopes, policy version, and evidence before consuming an `EXTERNAL_TRANSFER` approval.

#### Scenario: Evidence revocation or deletion after context selection (V-08 / C-06)
- **WHEN** evidence or caller permissions are revoked or mutated between `selectContext` and `revalidateAndAuthorizeTransfer`
- **THEN** transfer authorization rejects as stale with zero injected items even when a valid `EXTERNAL_TRANSFER` approval exists

### Requirement: Deletion propagation across index rebuild and backup restore (V-16)
Deleting a memory or its underlying evidence SHALL purge derived index rows, prevent `rebuildDerivedIndex` from resurrecting deleted memories, and ensure post-restore queries against an earlier backup expose zero deleted items.

#### Scenario: Index rebuild and backup restoration after deletion
- **WHEN** derived index is rebuilt or an older backup is restored after evidence/memory deletion
- **THEN** deleted memories and entries citing deleted evidence remain excluded and prior `selectionRevision` tokens fail as stale
