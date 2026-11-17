# mock-runtime-session Specification

## Purpose

Defines separated ExecutionAttempt and Task lifecycles, `prepare` reservation vs approved `start` pre-spawn commits, controllable Mock runtime supervision, cancel/exit race resolution, PID-reuse rejection on restart, explicit observation loss reporting, and terminal-state resume gating.

## Requirements

### Requirement: Separated Runtime Attempt and Task Lifecycles with Prepare/Start Gate
`prepare` SHALL reserve a `Prepared` attempt in SQLite without execution approval and spawn zero processes; `start` SHALL validate capabilities, concurrent isolation, attempt-bound `EXECUTION` approval, and optional mandatory `EXTERNAL_TRANSFER` approval, committing `Starting` in SQLite before spawning any process and returning current state with zero additional spawns on duplicate `Starting`/`Unknown` retries.

#### Scenario: Prepare reserves attempt without spawning and start blocks missing approvals or storage errors
- **WHEN** `prepare` runs or `start` lacks a valid `EXECUTION` or mandatory `EXTERNAL_TRANSFER` approval or SQLite commit fails
- **THEN** zero processes are spawned and failed attempts do not report `Running` or `Succeeded`

#### Scenario: Runtime Succeeded separates from Task Succeeded
- **WHEN** a `Running` attempt confirms `normal_exit_confirmed`
- **THEN** the `ExecutionAttemptState` transitions to `Succeeded` and `TaskLifecycleState` transitions to `Evaluating` (never `Succeeded` prior to ARC-09 evaluation)

### Requirement: Cancel/exit race handling, PID reuse rejection, observation loss, and resume gating
Cancel requests SHALL record `CancelRequested` immediately without claiming `Cancelled` until process exit is confirmed; restart reconciliation SHALL reject PID reuse when `processStartToken` differs, keep unconfirmed attempts in `Unknown` (`Task Blocked`) with zero automatic restarts, report dropped/truncated output explicitly in `observe`, and allow `resume` only from a confirmed terminal attempt with `run.resume=supported` and a newly prepared attempt + fresh execution approval.

#### Scenario: Crash around spawn and PID reuse on restart
- **WHEN** Core crashes before/after spawn or restarts to find the PID occupied by a process with a different `processStartToken`
- **THEN** `reconcileOnRestart` sets the attempt to `Unknown` and task to `Blocked` with zero automatic restarts

#### Scenario: Cancel races with normal exit or Starting spawn
- **WHEN** `cancel` is requested during `Starting` before spawn confirmation or during `Running` concurrently with normal exit
- **THEN** `Starting` cancel terminates upon observing spawn confirmation -> `Cancelled`, and `Running` cancel finishing with normal exit records `Succeeded` (`Task Evaluating`)

#### Scenario: Output loss during observation
- **WHEN** runtime output events are dropped or truncated
- **THEN** `observe` reports `droppedEventsCount > 0` / `outputTruncated == true` without fabricating missing events
