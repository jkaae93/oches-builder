# Design

## Context

`RECOVERY_FRESHNESS_ANCHOR.md` defines the two-phase boundary between the SQLite DB, the external append-only `RecoveryLedger`, and the separated `FreshnessAnchor`. Neither DB-internal hash chains nor DB-only timestamps defend against DB rollback.

## Goals / Non-Goals

**Goals:** atomic CAS anchor progression, JCS-canonicalized `DurableIntent` signing outside the DB directory, single-step crash reconciliation vs fail-closed `RECOVERY_QUARANTINED`, SQLite Online Backup API + blob manifest validation, deletion replay on restore, and unpredictable `storeGeneration` rotation.

**Non-Goals:** Tier 2 S3/GCS CAS or hardware TPM 2.0 NV hardware driver calls.

## Decisions

- `LocalSealedFreshnessAnchor` persists sealed anchor state outside the SQLite DB directory (`anchor` store abstraction) and enforces exact CAS match on `(workspaceID, epoch, sequence, headDigest)`.
- `RecoveryLedger` appends `SignedLedgerEntry` lines (`DurableIntent` + canonical `headDigest` + `keyID` + signature) to a directory separate from the SQLite database file.
- `RecoveryCoordinator.reconcileOnRestart()` rejects unsigned `INTENT_COMMITTED` DB rows even if an approval exists, transitioning directly to `RECOVERY_QUARANTINED` rather than retroactively signing DB rows.
- `restoreWorkspaceFromBackup` validates backup integrity & foreign keys in an isolated staging file, checks continuity against current `FreshnessAnchor` and `RecoveryLedger`, replays all post-snapshot deletions and revocations, rotates `storeGeneration`, transitions old `Starting`/`Running` attempts to `Unknown`, and bumps `FreshnessAnchor`.

## Risks / Trade-offs

- [Local Tier 1 cannot defend against full machine disk + Keychain image rollback] → explicitly documented as Tier 1 scope boundary in `RECOVERY_FRESHNESS_ANCHOR.md`.

## Migration Plan

Additive `durable_intents`, `deletion_requests`, and `backup_blobs` tables in SQLite.
