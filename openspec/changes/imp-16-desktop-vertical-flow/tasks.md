# Tasks

- [x] Create OpenSpec specification for IMP-16 Flutter Desktop vertical workflow.
- [x] Implement typed Core models, client interface, and fail-closed macOS client adapter (`lib/core/`).
- [x] Implement `VerticalFlowController` with 8-stage orchestration, 4Hz monitor throttle, requestId deduplication, stale draft/diff guards, read-only reconnect and cursor resync.
- [x] Implement accessible EN/KR `VerticalFlowShell` UI and wire into `OchesApp` while keeping fail-closed default when Core XPC is unavailable.
- [x] Add widget and controller regression tests for V-01, V-14, P4 and cost/unknown display (`test/vertical_flow_test.dart`), and record evidence (`docs/imp-16-desktop-evidence.md`).
- [ ] Run signed macOS Desktop + XPC service end-to-end integration and screen-reader WCAG 2.2 AA verification (product/packaging gate IMP-21/22).
