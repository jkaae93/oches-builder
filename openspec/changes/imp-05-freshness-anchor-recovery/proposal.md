# Proposal

## Why

`IMP-02` through `IMP-04` implement SQLite transactions and approvals, but an older SQLite backup or full-database rollback can resurrect deleted records or bypass client revocations (`SQLITE_STORAGE_RECOVERY_CONTRACT`, `RECOVERY_FRESHNESS_ANCHOR`). Tier 1 sealed freshness anchors, signed `DurableIntent` records in an external append-only `RecoveryLedger`, fail-closed quarantine (`RECOVERY_QUARANTINED`), deletion lifecycle tracking, and `storeGeneration` rotation on backup restore are required before execution runtimes and memory stores rely on durable deletions.

## What Changes

- Implement Tier 1 `LocalSealedFreshnessAnchor` (`read`, CAS `advance` verifying `workspaceID`, `epoch`, `sequence + 1`, `previousHeadDigest`), canonical JCS `DurableIntent`, external append-only `RecoveryLedger` signed by `intentSigningKey`, and `RecoveryCoordinator.reconcileOnRestart()`.
- Enforce `RECOVERY_QUARANTINED` fail-closed isolation on missing/unavailable anchor, unsigned `INTENT_COMMITTED` DB rows, rollback (`anchor.sequence > ledger.sequence`), same-sequence fork, `gap > 1`, or revoked/invalid key signature, while allowing single-step idempotent retry (`ledger.sequence == anchor.sequence + 1`) only when signature and trusted UI approval chain remain valid.
- Implement `DeletionRequestLifecycle` (`PENDING -> DELETING -> COMPLETE | FAILED`), SQLite Online Backup API (`sqlite3_backup_init`/`step`/`finish`) with blob manifest pinning/verification, isolated backup restore (`PRAGMA integrity_check` + `PRAGMA foreign_key_check`), post-snapshot `RecoveryLedger` deletion & revocation replay, `storeGeneration` rotation, marking prior active attempts `Unknown`, `STALE_GENERATION` enforcement, and Desktop trusted UI quarantine release (`epoch + 1`).

Explicit non-goals: Tier 2 external cloud CAS anchor (`EXTERNAL_OBJECT_CAS_ANCHOR`) and Windows/Linux TPM 2.0 hardware NV index execution remain `NOT RUN`.

## Capabilities

### New Capabilities

- `freshness-anchor-recovery`: Tier 1 sealed freshness anchor, signed `DurableIntent` `RecoveryLedger`, fail-closed quarantine, online backup, isolated restore with `storeGeneration` rotation, and deletion replay.

### Modified Capabilities

None.

## Impact

- `docs/architecture/RECOVERY_FRESHNESS_ANCHOR.md`
- `docs/architecture/SQLITE_STORAGE_RECOVERY_CONTRACT.md`
- `core/Sources/OchesCore/FreshnessAnchorAndLedger.swift`
- `core/Sources/OchesCore/BackupAndDeletionRecovery.swift`
