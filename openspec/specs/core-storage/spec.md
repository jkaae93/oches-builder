# core-storage Specification

## Purpose

Provides durable, per-workspace SQLite canonical storage with enforced `WAL` + `synchronous=FULL` + `foreign_keys=ON`, forward-only migrations, point-in-time consistent state/cursor snapshots, and atomic state/event/idempotency transactions.

## Requirements

### Requirement: Enforced SQLite durability and integrity configuration
Every SQLite connection opened by the Core SHALL configure and verify `journal_mode=WAL`, `synchronous=FULL`, and `foreign_keys=ON`, and SHALL fail closed with `UNAVAILABLE` if any setting cannot be enforced.

#### Scenario: Missing pragma enforcement blocks writes
- **WHEN** a storage connection cannot verify `journal_mode=WAL`, `synchronous=FULL`, or `foreign_keys=ON`
- **THEN** the store rejects writes and transitions rather than silently falling back to weaker durability settings

### Requirement: Forward-only migrations and integrity checks
The store SHALL reject databases with a schema version newer than supported without automatic downgrade, and SHALL run both `PRAGMA integrity_check` and `PRAGMA foreign_key_check` transitioning to `RecoveryRequired` if either detects violations.

#### Scenario: Foreign key violation detected independently of integrity_check
- **WHEN** a database passes `PRAGMA integrity_check` but fails `PRAGMA foreign_key_check`
- **THEN** `verifyIntegrity` transitions the store to `RecoveryRequired` and preserves the original database without deletion

### Requirement: Point-in-time consistent snapshot and cursor replay
`readSnapshot` SHALL read operational state, generation-bound `RevisionRef`, and the durable `EventCursor` inside one consistent read transaction, and `listEvents` SHALL validate `(workspaceId, storeGeneration)` and retained cursor bounds.

#### Scenario: Concurrent transition during snapshot read
- **WHEN** a transition commits while a reader holds a snapshot transaction between reading state and reading `eventCursor`
- **THEN** the returned snapshot contains the pre-commit state revision and pre-commit `eventCursor`, and replaying `listEvents` after that cursor returns the newly committed event

#### Scenario: Expired or wrong-generation cursor
- **WHEN** `listEvents` receives a cursor before the retained sequence floor or from a different `storeGeneration`
- **THEN** it returns `CURSOR_EXPIRED` or `STALE` (`STALE_GENERATION`) rather than silently omitting events

### Requirement: Atomic state, event, and idempotency transitions
`commitTransition` SHALL verify optimistic `expectedRevision`, record state updates, normalized events, and the `(actorId, workspaceId, operation, requestId)` idempotency digest and result in a single SQLite `BEGIN IMMEDIATE` transaction.

#### Scenario: Process crash before commit at any write boundary
- **WHEN** a writer process terminates after updating state, after inserting events, or after inserting idempotency records prior to `COMMIT`
- **THEN** zero partial state, event, or idempotency records are visible upon restart

#### Scenario: Disk full during transition
- **WHEN** SQLite returns `SQLITE_FULL` mid-transition
- **THEN** the transaction rolls back completely with zero partial state or events and transitions the store health to `Degraded`

#### Scenario: Duplicate requestId with same vs different input
- **WHEN** a request repeats within the 30-day retention window with identical `(actorId, workspaceId, operation, requestId)` and canonical input digest
- **THEN** the store returns the original result with zero duplicate state or event writes, whereas different payload or `expectedRevision` returns `CONFLICT`

#### Scenario: Expired idempotency tombstone
- **WHEN** an idempotency record has passed its 30-day retention window or has been tombstoned
- **THEN** repeating the `requestId` transitions the record to a workspace-lifetime tombstone if needed and returns `IDEMPOTENCY_EXPIRED` without executing a new transition
