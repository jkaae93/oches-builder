# Tasks: IMP-07 Mock Runtime, Session Lifecycle, and Cancel Races

## 1. Attempt Lifecycle State Machine and Prepare/Start Gate (Sub-PR A)

- [x] 1.1 Create `imp-07-mock-runtime-session` OpenSpec change and validate schema.
- [x] 1.2 Implement `ExecutionAttemptState` FSM, `TaskLifecycleState` separation, and SQLite-backed `prepare` / pre-spawn `start` commit in `RuntimeLifecycle.swift`.
- [x] 1.3 Add unit tests for all FSM transitions, terminal immutability, `app_exit` denial, `prepare` reservation without execution approval (0 spawns), `start` approval/capability/transfer checks (`X10`, `FC-03`), and storage failure spawn prevention.

## 2. Mock Supervisor, Cancel Races, PID Reuse, Observation Loss, and Resume (Sub-PR B)

- [ ] 2.1 Implement `ProcessIdentity`, controllable `MockRuntimeAdapter`, and `RuntimeSessionManager` (`start`, `observe`, `cancel`, `inspect`, `reconcileOnRestart`, `resume`) in `MockRuntimeSupervisor.swift`.
- [ ] 2.2 Add V-06/V-07/C04/FC-04/X10/X11/X12/CV09 regression tests covering crash before/after spawn, PID reuse rejection, `Starting` cancel race, `Running` cancel vs normal exit race (`Task Evaluating`), output loss/truncation reporting, and `resume` gating.
- [ ] 2.3 Sync `mock-runtime-session` spec to `openspec/specs/` and archive `imp-07-mock-runtime-session`.
