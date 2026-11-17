# Design

## Context

`ARC-06.md` and `test_runtime_lifecycle.py` define the exact attempt FSM (`Prepared`, `Starting`, `Running`, `CancelRequested`, `Succeeded`, `Failed`, `Cancelled`, `Interrupted`, `Unknown`) and require separating Runtime termination from Task evaluation.

## Goals / Non-Goals

**Goals:** enforce the exact attempt FSM, separate Runtime vs Task state, prevent spawns when `prepare` runs or storage/approval/capability fails, handle spawn crashes and PID reuse without auto-restart, distinguish `CancelRequested` from `Cancelled`, and report lost/truncated output without fabricating events.

**Non-Goals:** live Claude Code or Codex CLI adapter execution (`IMP-15`/`IMP-17`).

## Decisions

- `transitionAttemptState(from:event:)` mirrors `ARC-06.md` and `test_runtime_lifecycle.py`, keeping terminal states immutable and rejecting `app_exit` and `Unknown -> retry`.
- `RuntimeSessionManager.prepare` records a `Prepared` attempt in `execution_attempts` and sets `tasks.state = 'Prepared'` without requiring an execution approval and with zero spawns.
- `start` validates capability, concurrency isolation, execution approval, and mandatory external transfer approval inside SQLite `BEGIN IMMEDIATE`, transitioning `Prepared -> Starting` and checking idempotency (`Starting`/`Unknown` returns existing status with zero new spawn).
- `ProcessIdentity` pairs `pid` with an opaque `processStartToken`; `reconcileOnRestart` treats mismatched `processStartToken` (PID reuse) or absent process confirmation as `Unknown` (`Task Blocked`) with zero auto-restarts.

## Risks / Trade-offs

- [Mock supervisor tests run deterministically in-process/controlled handles] → provides full coverage of V-06/V-07/C04/FC-04/X10~X12 races, while real OS CLI processes remain `NOT RUN` until IMP-15/IMP-17.

## Migration Plan

Additive `tasks`, `execution_attempts`, and `runtime_events` tables in SQLite (`CREATE TABLE IF NOT EXISTS`).
