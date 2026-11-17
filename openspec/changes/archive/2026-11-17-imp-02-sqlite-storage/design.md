# Design

## Context

`SQLiteStore` wraps the macOS system `SQLite3` library (`ADR-020`). Every workspace has an isolated SQLite database file initialized with `storeGeneration` and `schema_version`.

## Goals / Non-Goals

**Goals:** enforce WAL + FULL + foreign_keys per connection, prevent schema downgrades, verify `integrity_check` and `foreign_key_check`, provide consistent point-in-time state/cursor reads, and commit state/events/idempotency atomically.

**Non-Goals:** recovery anchors and external ledger replay (IMP-05), policy/approval evaluation (IMP-04), or claiming non-macOS durability.

## Decisions

- `workspace_meta`: single row holding `(workspace_id, store_generation, schema_version)`.
- `operational_state`: `(object_id, workspace_id, owner_module, revision, state_json, updated_at)`.
- `event_log`: append-only `(seq AUTOINCREMENT, event_id UNIQUE, workspace_id, store_generation, object_id, source_id, kind, payload_json, observed_at)`.
- `event_retention_meta`: `(workspace_id, min_retained_seq)` tracking pruned sequence bounds for `CURSOR_EXPIRED`.
- `idempotency_records`: keyed by `(actor_id, workspace_id, operation, request_id)` storing `(input_digest, response_json, result_revision, result_cursor, created_at, expires_at, tombstoned)`.
- `readSnapshot` opens a read transaction (`BEGIN`) before querying `operational_state` and `event_log`, guaranteeing that `revision` and `eventCursor` reflect a single consistent point in time even while another connection executes `commitTransition`.
- `commitTransition` opens `BEGIN IMMEDIATE`, evaluates idempotency/tombstone expiration first, validates `expectedRevision` (`objectId`, `storeGeneration`, `revision`), updates `operational_state`, inserts events, records the idempotency outcome with a 30-day default TTL, and commits. Any failure rolls back cleanly.

## Risks / Trade-offs

- [WAL requires local filesystem semantics] → fail closed if WAL/FULL cannot be verified; reject remote/network assumptions until tested.
- [External CLI spawns are not atomic with SQLite] → keep process lifecycle out of `commitTransition`; reconcile externally in IMP-05 and IMP-07.

## Migration Plan

Initial SQLite schema version 1; newer versions fail closed (`invalidMigration`) without auto-downgrade.
