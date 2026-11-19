# Desktop readiness integration evidence

Date: 2026-11-18. Refs #8. Change: `imp-08-project-analysis`.

The Flutter shell now calls a native readiness method without project data. The macOS bridge validates bundle-configured service and signing identifiers, applies an XPC code-signing requirement, sends only readiness, and completes once on reply, connection failure or a three-second timeout. Flutter also bounds waiting to five seconds. Readiness cannot authorize analysis; all replies remain unavailable until protected dispatch and scope approval are integrated.

Verification on this macOS arm64 machine:

- `swift test --package-path core --filter Analyzer`: 35 tests passed.
- `flutter test` in `apps/desktop`: 4 tests passed, including missing-handler denial and a forged ready reply remaining unavailable.
- `flutter analyze`: no issues.
- `flutter build macos --debug`: passed.

Signed installed Desktop-to-Core service integration: NOT RUN. The bundle has no configured service identity, and the Core package does not yet deploy an analysis service or expose a verified scope-approval operation. These are remaining IMP-08 integration requirements. OpenSpec task 2.2 and overall issue completion remain pending. No project contents, account credentials or provider requests were transmitted during verification. Existing open PRs were not merged.
