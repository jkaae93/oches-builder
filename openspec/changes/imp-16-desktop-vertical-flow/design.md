# Design

Follow `ARC-01.md`, `PROVIDER_MVP_FEASIBILITY.md`, and frozen P3/P4/P5/P6.

1. Preserve `MacOSCoreTransport` fail-closed behavior (`OchesApp()` renders `'Core is unavailable.'` unless a verified `OchesCoreClient` implementation is provided).
2. `VerticalFlowController` tracks workflow stages, local vs canonical template revisions, stale export plans, stable `requestId` deduplication during in-flight mutations, and a 250ms (4Hz) monitor refresh throttle (P4).
3. Cancel vs terminal state distinction (V-01): `requestCancel()` marks UI `cancelPending` (`Cancel Requested`) while polling Core; UI renders `Cancelled` only upon confirmed cancellation and `Evaluating` if normal exit wins the cancel race.
4. Reconnect safety and stale prevention (V-14): `reconnect()` performs read-only `connectAndInspect` and `pollObservation` (falling back to `fetchSnapshotForAttempt` on `cursorExpired`) with 0 automatic restarts; local template edits mark `localDraftDirty` and `exportPlan.stale`, blocking `applyConfigExport` until revalidated and re-planned.
5. `CostSummaryView` distinguishes all five canonical cost states and forbids rendering `$0.00` for `UNKNOWN` or `SUBSCRIPTION_INCLUDED`. `VerticalFlowShell` exposes semantic accessibility descriptions and Korean/English switching (P3, P5).
