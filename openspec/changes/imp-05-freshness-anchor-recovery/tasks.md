# Tasks: IMP-05 FreshnessAnchor, DurableIntent, and Deletion Recovery

## 1. Tier 1 FreshnessAnchor, RecoveryLedger, and Crash Reconciliation (Sub-PR A)

- [x] 1.1 Create `imp-05-freshness-anchor-recovery` OpenSpec change and validate schema.
- [x] 1.2 Implement `LocalSealedFreshnessAnchor`, canonical JCS `DurableIntent`, signed external `RecoveryLedger`, and `RecoveryCoordinator` with `reconcileOnRestart()`.
- [x] 1.3 Add unit tests for CAS conflict, single-step crash recovery, lost anchor response recovery, unsigned DB row quarantine, rollback, same-sequence fork, `gap > 1`, revoked key, and missing anchor quarantine.

## 2. Deletion Lifecycle, Online Backup, Isolated Restore, and Ledger Replay (Sub-PR B)

- [ ] 2.1 Implement `DeletionRequestLifecycle` (`PENDING -> DELETING -> COMPLETE | FAILED`), SQLite Online Backup API + blob manifest pinning, `restoreWorkspaceFromBackup` (integrity + FK check, post-snapshot deletion/revocation replay, `storeGeneration` rotation, `STALE_GENERATION`), and trusted UI quarantine release (`epoch + 1`).
- [ ] 2.2 Add V-16/V-17/V-18 regression tests for post-backup deletion resurrection prevention, incomplete deletion access blocking, old-generation cursor/revision `STALE_GENERATION` rejection, and quarantine release.
- [ ] 2.3 Sync `freshness-anchor-recovery` spec to `openspec/specs/` and archive `imp-05-freshness-anchor-recovery`.
