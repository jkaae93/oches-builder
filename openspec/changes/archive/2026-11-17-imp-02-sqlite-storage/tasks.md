# Tasks: IMP-02 SQLite Canonical Storage

## 1. Storage Foundation, Pragmas, Migration, and Consistent Reads (Sub-PR A)

- [x] 1.1 Record SQLite3 choice and transaction boundaries in `ADR-020-sqlite-core-storage.md` and create `imp-02-sqlite-storage` OpenSpec change.
- [x] 1.2 Expose `RevisionRef` publicly and implement `SQLiteStore` with `WAL`, `synchronous=FULL`, `foreign_keys=ON` verification, forward-only schema migration (no auto-downgrade), and `integrity_check` + `foreign_key_check`.
- [x] 1.3 Implement transactional `readSnapshot` and `listEvents` with `EventCursor`, `CURSOR_EXPIRED`, and `STALE_GENERATION` checks.
- [x] 1.4 Add regression tests for pragma enforcement, migration downgrade refusal, foreign-key violation detection, and consistent snapshot/cursor reads under concurrent writes.

## 2. Atomic Transitions, 30-Day Idempotency, Tombstones, and Fault Regression (Sub-PR B)

- [x] 2.1 Implement `commitTransition` atomically recording operational state, events, and idempotency outcome with RFC 8785 JCS input digest, optimistic `expectedRevision`, 30-day TTL, and workspace-lifetime tombstones.
- [x] 2.2 Implement `Degraded` and `RecoveryRequired` transitions on `FULL`/`IOERR`/corruption without silent fallback.
- [x] 2.3 Add V-10/V-12 regression tests: real process crash (`_exit`) at every write boundary, `SQLITE_FULL` disk-full rollback, concurrent `expectedRevision` conflicts, concurrent duplicate requests, mismatched input `CONFLICT`, and expired `IDEMPOTENCY_EXPIRED`.
- [x] 2.4 Sync `core-storage` spec to `openspec/specs/` and archive `imp-02-sqlite-storage`.
