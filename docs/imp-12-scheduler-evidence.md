# IMP-12 scheduler progress

Date: 2026-11-19. Issue: #12. OpenSpec: `imp-12-scheduler`.

Implemented a pure FIFO decision planner over internal task snapshots. It validates the DAG/workspace, preserves enqueue ordering among eligible tasks, requires predecessor Task success, allows at most four reserved/running/uncertain slots, serializes unverified installation/account isolation and prevents overlapping opaque exclusive-resource identities. Unknown attempts remain slot occupants, never automatic retry candidates. Runtime exit success alone is not accepted as evaluated Task success.

Tests cover four-slot FIFO selection, evaluating versus succeeded predecessors, unverified shared-account serialization, resource collisions, Unknown attempt/account blocking and workspace mismatch. Resource IDs are assumed already canonical and trusted; this layer does not resolve paths, establish sandboxing or authenticate snapshots. It does not reserve durably, spawn a process or grant approval.

Remaining: immutable versioned Run plans, atomic reservations, concurrent dispatch/crash handling, approved Runtime start/cancel, verified evaluation and bounded retry/backoff. IMP-09/10/11 product integration remains incomplete and none of those gates is bypassed by this planner.

## Run snapshot and atomic reservation primitive

Added a create-only Run plan snapshot with input pins, fixed plan-content digest and task/dependency records. Reservation updates task states and per-task reserved attempt IDs together with event/request result in the existing SQLite transition transaction. The repository exposes no DAG-edit operation. Replays use stable plan/request identity and return original reserved IDs even after Run state advances; new requests with stale revision or changed input pins reject.

`swift test --package-path core --filter SchedulerRunRepositoryTests` passed a restart/reopen test covering four reservations, FIFO task selection, exact replayed IDs, a competing stale request, changed pins and full-slot behavior. The competing request is sequential in this test; real concurrent-process reservation and crash tests remain pending. Reservations are internal scheduler IDs, not proof that ARC-06 has prepared an approved executable attempt.

This initial transaction covers one Run. Workspace-wide slots/account/resource conflicts across multiple Runs are not yet enforced by the repository and must be integrated atomically before product dispatch. Runtime preparation/approval/start, verified evaluation and retry remain pending; no process is launched. The combined OpenSpec Run/reservation task remains unchecked until cross-Run and Runtime identity integration is complete.

## Workspace-wide commit-time reservation checks

Added an internal scheduler-specific transition entry point. After idempotency lookup and inside the existing SQLite write transaction, it inspects all other ARC-07 Run states in the workspace and validates combined reserved/active/uncertain slots (maximum four), installation/account isolation and exclusive resource collisions. A conflict returns Busy and rolls back the complete reservation transition. Existing replay results bypass new reservation checks and do not create side effects.

Extended tests cover a second Run attempting to exceed four workspace reservations and two Runs sharing an unverified account or exclusive resource. Rejection preserves the second Run revision. These are sequential independent-request tests; true concurrent-process and crash verification remain pending. The planner currently proposes per-Run batches and may return Busy rather than reduce a batch to remaining workspace capacity; global FIFO selection/fairness is not yet integrated. Actual Runtime prepared identity, authorization and dispatch remain incomplete.

## Independent-process reservation race

Added a barrier-synchronized subprocess test with two independently opened SQLite connections and two different Runs each requesting four slots. Both children wait until ready, then race reservation. The successful child exits immediately with `_exit(71)` after commit; the rejected child exits with the Busy marker. The parent verifies one success/one Busy and persisted reservation counts of four/zero across the Runs.

`swift test --package-path core --filter SchedulerRunRepositoryTests` passes three tests, including this actual process race. The immediate post-commit child exit also verifies committed reservation visibility without normal shutdown, but not power-loss durability or interruption inside every transaction stage. Cross-Run FIFO fairness/partial batch utilization, Runtime preparation/approval/dispatch, verified evaluation and retry remain pending. No provider process is started by the test.

## Bounded retry decision policy

Added an internal retry decision policy for confirmed Runtime failure, separately verified evaluation failure and explicitly requested Interrupted recovery. At most three retries may be reserved; delays begin at one second and double (one/two/four within this bound, general cap 60 seconds). Unknown, active, prepared and cancelled attempts never become automatic retry candidates. Backward time, invalid counts and time overflow are blocked/rejected. Eligibility explicitly requires a new attempt and new approval.

`swift test --package-path core --filter SchedulerRetryPolicyTests` passes two tests covering delay boundaries, exhaustion, all non-failure attempt states, manual Interrupted versus Unknown, evaluation-failure reason, backward time and integer overflow. The reason enum is an internal trusted input, not proof of evaluation or user authorization. Durable retry counts/timers, atomic re-reservation, actual approval issuance and Runtime dispatch integration remain incomplete, so the combined retry/recovery task stays unchecked.

## Runtime record reconciliation

Added an internal observation operation that fetches the reserved attempt from RuntimePrepareAndStartGate on the same SQLiteStore and checks workspace, Run, Task, installation and account identity before updating the scheduler snapshot. Runtime states use the existing ARC-06 mapping: Unknown/Interrupted become Blocked and Runtime Succeeded becomes Evaluating, never Task Succeeded. Observation identity participates in idempotency input; state/event/result use the existing revision-checked transaction.

The test inserts synthetic Runtime records to verify Unknown remains blocked/non-retried, Succeeded only reaches Evaluating and wrong Task identity rejects. It tests the stored-record boundary, not a Provider or complete authenticated prepare/start flow. Runtime task revision/instance/binding reconciliation, cross-Run task identity namespacing, verified evaluation success, authenticated dispatch and retry counters remain pending. No issue is marked complete from this integration.

## Core prepare/approval/start/cancel, durable retry and atomic evaluation integration

Added end-to-end Core IMP-12 scheduler orchestration across `EvaluationVerdictStore.swift`, `SQLiteStorage.swift`, `RuntimePrepareAndStartGate.swift`, `MockRuntimeSupervisor.swift`, `FIFOSchedulingPlanner.swift` and `SchedulerRunRepository.swift`:

- **Cross-Run partial capacity & task namespacing**: `FIFOSchedulingPlanner.select` now accepts `externalOccupied` tasks from other active ARC-07 Runs so Runs claim remaining workspace capacity (up to 4 slots) without over-reserving; `reserve` preserves idempotent replays on prior revisions without prematurely raising `Busy`, and `validateWorkspaceReservation` continues enforcing workspace-wide atomicity inside `BEGIN IMMEDIATE`. Prepared Runtime tasks namespace `taskID` as `arc07/run/<runID>/task/<taskID>` so identical task IDs across Runs never collide in `RuntimePrepareAndStartGate`.
- **Full `prepare → approval → start → cancel → observe → reconcile` (V-07 / V-09 / C-04)**: `prepareAttempt` computes deterministic `bindingDigest` and `executionRequestDigest` bound to `workspaceID`, `runID`, `taskID`, `runtimeTaskID`, `planDigest`, `inputPins`, `instanceRevision`, `installationID`, `accountRef` and `attemptSequence`, and reserves a `Prepared` attempt in `RuntimePrepareAndStartGate` with zero spawns. `RuntimePrepareAndStartGate.consumeApprovalInTx` now verifies all execution binding fields (`preparedAttemptID`, `runID`, `taskRevision`, `instanceRevision`, `bindingDigest`, `capabilitySnapshotID`, `executionRequestDigest`) plus `externalTransfer` `accountRef` and pre-spawn `snapshotID`. `startAttempt`, `cancelTask`, `observeRuntime` and `reconcileAfterRestart` verify full attempt identity/binding, route idempotent replays and stale revisions through `SQLiteStore.commitTransition` without duplicate spawns/cancellations, keep `CancelRequested` at `Running`, map normal exit race wins to `Evaluating`, and keep `Unknown` at `Blocked` with slot occupancy preserved and zero automatic retries.
- **Durable bounded retry & manual recovery (R3 / R10)**: `requestRetry` persists `retryCounts`, `lastFailureTimestamps` and `attemptHistory` in the Run snapshot, enforces 1s/2s/4s backoff and the 3-retry cap via `SchedulerRetryPolicy`, rejects `Unknown` or premature/unverified `evaluationFailure` retries, and requires reserving a new `attemptID`, incrementing `taskRevision`, and obtaining a fresh execution approval.
- **Atomic verified evaluation verdict transitions (C-07 / ARC-07 v0.3)**: Added `EvaluationVerdictStore` (`evaluation_records` table) and `SQLiteStore.commitSchedulerEvaluation` to validate non-stale `evaluation_records` matching `workspaceID`, `runID`, `taskID`, `taskRevision`, `attemptID`, `artifactManifestID`, `artifactManifestDigest`, `criteriaID/Version`, `policyVersion` and `verdict`, along with `execution_attempts.state == 'Succeeded'` inside the same `BEGIN IMMEDIATE` transaction as `applyEvaluation`. `PASS` transitions to `Succeeded` and unlocks dependent tasks; `INDETERMINATE` transitions to `Blocked`; `FAIL` transitions to `Failed`.

Verification (`2026-11-19`):
- `swift test --package-path oches-builder/core`: **155 tests executed, 0 failures** (including 9 tests in `SchedulerRunRepositoryTests` covering partial cross-Run capacity, task namespacing, V-07 cancel/exit races, V-09 approval binding/expiry/revocation/transfer/replay/stale-revision checks, restart `Unknown` blocking, durable 3-retry backoff/exhaustion + manual `Interrupted` recovery, and atomic `PASS`/`FAIL`/`INDETERMINATE` evaluation rejection & dependency unlocking).
- `openspec validate imp-12-scheduler --strict`: passed.

Remaining outside this Core scheduler unit boundary (issue #12 stays open): IMP-13 immutable artifact blob/manifest collection and independent observation, authenticated XPC product endpoints, Flutter Desktop wiring and real Claude/Codex Provider adapters.
