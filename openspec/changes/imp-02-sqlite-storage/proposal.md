# Proposal

## Why

`IMP-01` established the wire contracts, `RevisionRef`, `WireErrorCode`, and canonical JCS hashing, but leaves storage unavailable. `ARC-10.md` and `SQLITE_STORAGE_RECOVERY_CONTRACT.md` require durable per-workspace authoritative storage for operational state, normalized events, and idempotency outcomes before authorization, recovery anchors, and runtime attempts can persist state.

## What Changes

- Configure and verify SQLite `journal_mode=WAL`, `synchronous=FULL`, and `foreign_keys=ON` on every connection, failing closed (`UNAVAILABLE`) if not enforced.
- Implement forward-only schema migrations without automatic downgrade, plus `PRAGMA integrity_check` and `PRAGMA foreign_key_check` verification transitioning to `RecoveryRequired` on failure.
- Implement `readSnapshot` and `listEvents` providing point-in-time consistent `(revision, state, eventCursor)` snapshots bound to `(workspaceId, storeGeneration)` and `CURSOR_EXPIRED` / `STALE_GENERATION` detection.
- Implement `commitTransition` atomically committing operational state, events, and `(actorId, workspaceId, operation, requestId)` idempotency records with RFC 8785 JCS input digests, optimistic `expectedRevision` locking, 30-day idempotency retention, and workspace-lifetime tombstones (`IDEMPOTENCY_EXPIRED`).
- Track `StorageHealthState` (`Available`, `Degraded`, `RecoveryRequired`) on `FULL`/`IOERR`/corruption errors.

Explicit non-goals: Tier 1 `FreshnessAnchor`, external `RecoveryLedger`, `DurableIntent` signing, online backup/restore, and deletion replay belong to IMP-05. Policy rules and multi-approval consumption belong to IMP-04. Windows and Linux filesystem durability tests remain `NOT RUN`.

## Capabilities

### New Capabilities

- `core-storage`: Per-workspace SQLite WAL/FULL storage, forward-only migrations, consistent snapshot/cursor reads, and atomic state/event/idempotency transactions.

### Modified Capabilities

None.

## Impact

- `docs/architecture/ARC-10.md`
- `docs/architecture/SQLITE_STORAGE_RECOVERY_CONTRACT.md`
- `docs/architecture/adr/ADR-020-sqlite-core-storage.md`
- `core/Sources/OchesCore/SQLiteStorage.swift` and `RevisionRef.swift`
