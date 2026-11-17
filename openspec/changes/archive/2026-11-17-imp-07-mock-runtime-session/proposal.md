# Proposal

## Why

`IMP-02`, `IMP-04`, and `IMP-06` establish durable SQLite storage, authorization/approval consumption, and provider capability gating. Before connecting live Claude/Codex adapters (`IMP-15`/`IMP-17`), `ARC-06.md` and `INTERFACE_CONTRACT_V1.md` require separating `prepare` attempt reservation from approved `start`, separating `ExecutionAttemptState` from `TaskLifecycleState`, handling cancel/exit races and spawn crashes without duplicate spawns or auto-restarts from `Unknown`, and exposing explicit event loss/truncation markers during observation (`V-06`, `V-07`, `C04`, `FC-04`, `X10`~`X12`).

## What Changes

- Implement `ExecutionAttemptState` transition table, terminal state immutability, `app_exit` rejection, and `TaskLifecycleState` separation (`Runtime Succeeded -> Task Evaluating`, `Runtime Unknown/Interrupted -> Task Blocked`).
- Implement SQLite-backed `prepare` (reserves `Prepared` attempt without execution approval and spawns 0 processes) and `start` pre-spawn gate (validates fresh capability snapshot, execution approval bound to `(runID, taskRevision, preparedAttemptID, executionRequestDigest)`, optional mandatory `externalTransfer` approval, atomic `Starting` commit + approval consumption + idempotency guard where existing `Starting`/`Unknown` spawns 0 processes, and zero spawns on storage failure).
- Implement `ProcessIdentity(pid, processStartToken, attemptID)`, controllable `MockRuntimeAdapter`, and `RuntimeSessionManager` (`start`, `observe` with sequence + explicit `droppedEventsCount`/`outputTruncated`, `cancel` separating `CancelRequested` from `Cancelled` and handling `Starting` / `Running` races, `reconcileOnRestart` rejecting PID reuse when `processStartToken` differs and holding `Unknown` with 0 auto-restarts, and `resume` requiring confirmed terminal state + `run.resume=supported` + newly prepared attempt + fresh execution approval).

Explicit non-goals: live Claude/Codex CLI execution (`IMP-15`/`IMP-17`).

## Capabilities

### New Capabilities

- `mock-runtime-session`: Execution attempt lifecycle, `prepare` reservation vs approved `start`, Mock runtime supervision, cancel/exit race resolution, PID-reuse resistance, and explicit observation loss reporting.

### Modified Capabilities

None.

## Impact

- `docs/architecture/ARC-06.md`
- `docs/architecture/INTERFACE_CONTRACT_V1.md`
- `core/Sources/OchesCore/RuntimeLifecycle.swift`
- `core/Sources/OchesCore/MockRuntimeSupervisor.swift`
