## ADDED Requirements

### Requirement: Tier 1 FreshnessAnchor CAS and signed DurableIntent RecoveryLedger
Core SHALL track deletion, revocation, and restore transitions via RFC 8785 JCS canonical `DurableIntent` records committed in SQLite (`INTENT_COMMITTED`), signed into an external append-only `RecoveryLedger` with an active `intentSigningKey`, and advanced atomically via `FreshnessAnchor.advance(expected, next)`.

#### Scenario: Single-step crash or lost anchor response
- **WHEN** `RecoveryLedger` leads `FreshnessAnchor` by exactly 1 sequence with matching `previousHeadDigest`, valid `intentSigningKey` signature, and verified Desktop approval chain
- **THEN** `reconcileOnRestart` performs a single idempotent `anchor.advance` retry and restores `ACTIVE` posture

#### Scenario: Rollback, fork, unsigned DB row, gap > 1, revoked key, or missing anchor
- **WHEN** restart reconciliation detects an unsigned `INTENT_COMMITTED` DB row, `anchor.sequence > ledger.sequence`, same-sequence digest fork, `ledger.sequence - anchor.sequence > 1`, revoked `intentSigningKey`, or missing/unavailable anchor
- **THEN** Core transitions immediately to `RECOVERY_QUARANTINED` blocking all reads, writes, executions, and transfers

### Requirement: Deletion lifecycle, online backup, and post-snapshot ledger replay on restore
Deletion requests SHALL transition through `PENDING -> DELETING -> COMPLETE | FAILED` blocking reads immediately and never reporting `COMPLETE` until state, events, derived indexes, and tracked backups confirm deletion; backup restore SHALL validate an isolated copy via `integrity_check` and `foreign_key_check`, replay post-snapshot `RecoveryLedger` deletions and revocations, rotate `storeGeneration`, mark prior active attempts `Unknown`, and enforce `STALE_GENERATION`.

#### Scenario: Restoring an older backup after deletion and revocation
- **WHEN** a backup taken before a deletion or client revocation is restored
- **THEN** restore verifies current `FreshnessAnchor`/`RecoveryLedger` continuity, replays post-snapshot deletions and revocations so zero deleted records are resurrected, rotates `storeGeneration`, and rejects old-generation cursors/revisions with `STALE_GENERATION`

#### Scenario: Quarantine release requires verified Desktop trusted UI approval
- **WHEN** a workspace is in `RECOVERY_QUARANTINED`
- **THEN** only a verified Desktop trusted UI approval may release quarantine by advancing to `epoch + 1` and rotating `storeGeneration`
