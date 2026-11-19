# Design

- **Formal Release Gate Evaluator (`ReleaseGateEvaluator.swift`)**:
  - Enforces strict denominator integrity (`validateIntegrity()`): no record can claim `.pass` when `denominator == 0` or `passedCount < denominator`, and `.productGate` records carrying unverified residuals cannot be promoted to `.pass`.
  - Phase 1 (`phase1LocalCoreDesktop`) and Phase 2 (`phase2ExtensionsAndPackaging`) gates evaluate to `.fail` on any failing required case, `.blocked` with explicit blocking reasons when any required product gate is `.notRun`, `.blocked`, or `.indeterminate`, and `.pass` ONLY when 100% of required cases pass with verified denominators.
- **Paired Comparison Aggregation (`PairedComparisonEvaluator`)**:
  - Aggregates paired fixtures (`recommendation-v0.1.json` 20x3 deterministic runs + `real-tasks-v0.3.json` `RWT-01/02`) over Mock / Claude-fixture / Codex-fixture entries from `ProviderComparisonHarness`, reporting `costUnavailableCount` without zero-substitution and setting `liveProviderVerified = false` unless real external API runs succeeded.
- **Automated Traceability Verification (`scripts/verify_release_traceability.mjs`)**:
  - Cross-checks every `R-01..12`, `V-01..23`, `X01..24`, `A11Y-01..05`, `PERF-01..05`, and `CP-01..07` row in `docs/imp-22-release-readiness.md`, validates `recommendation-v0.1.json` + `real-tasks-v0.3.json` fixtures, confirms all OpenSpec directories and evidence files `imp-08..22` exist, and ensures Phase 1 & Phase 2 remain honestly marked `BLOCKED`.
