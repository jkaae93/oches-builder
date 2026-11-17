# ADR-020: SQLite Canonical Storage and Transaction Boundary

Status: Accepted for IMP-02 Phase 1 macOS arm64 implementation, 2026-11-17. Refs #2, Refs #23.

## Context

`ARC-10.md` and `SQLITE_STORAGE_RECOVERY_CONTRACT.md` require a per-workspace authoritative local store that persists operational state, ordered normalized events, and idempotency records atomically in a single local transaction, enforces `WAL` + `synchronous=FULL` + `foreign_keys=ON`, prevents schema auto-downgrade, verifies both `integrity_check` and `foreign_key_check`, serves point-in-time consistent `(state, revision, eventCursor)` snapshots, enforces 30-day idempotency retention with workspace-lifetime tombstones, and transitions to `Degraded` or `RecoveryRequired` on write/corruption errors without deleting or silently altering user files.

## Decision

1. Use the macOS system SQLite3 C API (`import SQLite3`) directly inside `OchesCore` (`SQLiteStore`) rather than introducing an external ORM or third-party Swift SQLite wrapper.
2. On every SQLite connection open, configure and explicitly verify `PRAGMA foreign_keys = ON`, `PRAGMA synchronous = FULL`, `PRAGMA journal_mode = WAL`, and `PRAGMA busy_timeout = 5000`. If `journal_mode` is not `wal`, `synchronous` is not `2` (`FULL`), or `foreign_keys` is not `1`, fail closed with `StorageError.unavailable` and block writes/executions.
3. Wrap all `commitTransition` mutations in `BEGIN IMMEDIATE` to serialize writers at transaction entry and record operational state, events, and the `(actorId, workspaceId, operation, requestId)` idempotency outcome inside the same SQLite transaction.
4. Wrap `readSnapshot` in a single read transaction (`BEGIN`) so operational state revision and the maximum durable event sequence cursor (`eventCursor`) always observe the exact same transactional snapshot even under concurrent writers.
5. Reject databases whose `schema_version` exceeds the binary's supported schema version (`StorageError.invalidMigration`) with zero automatic downgrade.

## Consequences and Verification

- Using system `SQLite3` keeps `core/Package.swift` dependency-free and ensures deterministic access to `sqlite3_backup_init`, `PRAGMA` verification, and exact SQLite result codes (`SQLITE_FULL`, `SQLITE_IOERR`, `SQLITE_BUSY`, `SQLITE_CORRUPT`).
- External CLI process spawns and mutable workspace files remain outside SQLite transaction atomicity; process creation and recovery boundaries are handled explicitly in IMP-05 and IMP-07.
- Verify with regression tests covering `WAL`/`FULL`/`foreign_keys` enforcement, schema migration version guards, `integrity_check` vs `foreign_key_check`, consistent snapshot/cursor reads during concurrent writes, real OS process crashes (`_exit`) at every write boundary, `SQLITE_FULL` rollback, concurrent `expectedRevision` conflicts, identical `requestId` conflicts/replays, and 30-day tombstone expiration (`IDEMPOTENCY_EXPIRED`).
- Windows, Linux, and power-loss endurance on non-local filesystems remain `NOT RUN`.
