# IMP-16 Flutter Desktop vertical flow progress

Date: 2026-11-19. Issue: #16. OpenSpec: `imp-16-desktop-vertical-flow`.

## Implemented Desktop components

- **Typed Core models & fail-closed client boundary** (`apps/desktop/lib/core/core_models.dart`, `apps/desktop/lib/core/core_client.dart`, `apps/desktop/lib/main.dart`):
  - Models the 8 workflow stages (`scope`, `profile`, `recommendations`, `template`, `exportDiff`, `runApproval`, `monitor`, `evaluation`), canonical `RevisionRef`, capability badges (`SUPPORTED`/`UNSUPPORTED`/`UNKNOWN`), 5-state `CostSummaryView` formatting (never rendering `UNKNOWN` or `SUBSCRIPTION_INCLUDED` as `$0.00`), and `FailClosedMacOSCoreClient` preserving `OchesApp()`'s default `'Core is unavailable.'` gate when no authenticated Core client is bound.
- **Vertical workflow controller** (`apps/desktop/lib/state/vertical_flow_controller.dart`):
  - Enforces stable `requestId` deduplication during in-flight mutations, 250ms (4Hz) monitor pacing (`minMonitorRefreshInterval`, P4), read-only `reconnect()` with `cursorExpired` -> `fetchSnapshotForAttempt` resync (0 automatic starts, V-14), stale local draft/export diff apply blocking, separated execution + external transfer approvals, and V-01 `Cancel Requested` vs confirmed `Cancelled`/`Evaluating` distinction.
- **Accessible EN/KR Vertical Flow Shell** (`apps/desktop/lib/ui/vertical_flow_shell.dart`):
  - Implements Material 3 `NavigationRail` + stage panels with semantic labels, Korean/English toggle (P3, P5), truncation/dropped-event notices, and honest cost/evaluation rendering.

## Verification

- `cd oches-builder/apps/desktop && dart format --output=none --set-exit-if-changed lib test`: passed (0 changes needed).
- `cd oches-builder/apps/desktop && flutter analyze`: `No issues found!`.
- `cd oches-builder/apps/desktop && flutter test`: **7/7 tests passed** (`test/widget_test.dart` 4/4 + `test/vertical_flow_test.dart` 3/3 covering full 8-stage flow, EN/KR toggle, honest cost display, V-01 cancel/race handling, V-14 read-only reconnect & cursor expiry, stale template edit apply blocking, 4Hz throttle, and in-flight duplicate-click deduplication).
- `openspec validate imp-16-desktop-vertical-flow --strict`: passed.

## Remaining product/packaging gates (issue #16 remains open)

- Signed/notarized macOS XPC Core daemon round-trips (`IMP-21`) and live VoiceOver WCAG 2.2 AA audit remain product gates.
