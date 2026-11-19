# IMP-22 Release Readiness, Requirements Traceability & Non-Functional Gate Report

- **Issue**: `#22` (`[IMP-22] 출시 검증·추적성·비기능 게이트`)
- **OpenSpec**: [proposal.md](../openspec/changes/imp-22-release-traceability/proposal.md) · [design.md](../openspec/changes/imp-22-release-traceability/design.md) · [spec.md](../openspec/changes/imp-22-release-traceability/specs/release-traceability/spec.md)
- **Evaluator Module**: [ReleaseGateEvaluator.swift](../core/Sources/OchesCore/ReleaseGateEvaluator.swift) · [ReleaseGateEvaluatorTests.swift](../core/Tests/OchesCoreTests/ReleaseGateEvaluatorTests.swift)
- **Verification Script**: [verify_release_traceability.mjs](../scripts/verify_release_traceability.mjs)

## 1. Environment & Versions Observed

| Component | Observed Value | Notes |
|---|---|---|
| OS / Architecture | macOS 26.4 (`arm64`) | Local developer machine |
| Swift Toolchain | Apple Swift 6.3.3 | Local package build & `swift test` |
| Flutter / Dart | Flutter 3.41.6 | Local Desktop widget & state tests (`apps/desktop`) |
| Node.js | v25.9.0 | Chrome/VS Code extension tests, Noise IK OpenSSL vectors, traceability scripts |
| Python | Python 3.14.7 | JSON Schema & `verify-real-tasks.py` oracle checks |
| OpenSpec CLI | 2.0.0 | Strict spec validation (`imp-08`..`imp-22`) |
| Claude Code CLI (Installed) | `2.1.296 (Claude Code)` | `--version` observed; live billable external API execution **NOT RUN** |
| Codex CLI (Installed) | `codex-cli 0.169.0` | `--version` observed; live billable external API execution **NOT RUN** |

## 2. Phase Release Gates

- **Phase 1 Gate: BLOCKED** (`ReleasePhase.phase1LocalCoreDesktop`)
  - Local `OchesCore` unit/contract tests and `apps/desktop` Flutter widget/state tests pass locally, **but** live external Provider APIs (Claude / Codex), independent macOS process/filesystem observer daemon, Apple Developer ID code signing + Apple notarization, and 30-run hardware performance / VoiceOver accessibility evaluations remain **NOT RUN**.
- **Phase 2 Gate: BLOCKED** (`ReleasePhase.phase2ExtensionsAndPackaging`)
  - Chrome MV3 / Native Messaging Host unit/contract tests, VS Code local extension unit/contract tests, and SQLite upgrade/backup/rollback tests pass locally, **but** live Chrome 120+ browser Native Messaging execution, real VS Code 1.85+ Desktop runtime, Apple Developer ID notarization & auto-updater tests, Chrome Web Store review, and VS Code Marketplace publisher verification remain **NOT RUN**.

## 3. Fixed Real-Task & Cross-Provider Paired Comparison Summary

- **Recommendation Structural Fixture Suite (`docs/architecture/fixtures/recommendation-v0.1.json`)**: 20 fixtures across 4 groups (`simple` 5, `parallel` 5, `capability` 5, `safety` 5) × 3 deterministic evaluation repeats (`60/60` synthetic checks verified in `OchesCoreTests`).
- **Fixed Real-Task Benchmark (`docs/architecture/fixtures/real-tasks-v0.3.json` & `real-tasks-v0.2.json`)**: `verify-real-tasks.py` verified pinned Git commit oracle (`RWT-01` / `RWT-02`), 10 simulated oracle negative controls, and 7 malformed input controls with 0 external model executions.
- **Paired Provider Comparison Summary (`ProviderComparisonHarness` + `ReleaseGateEvaluator.summarizePairedComparison`)**:

| Provider | CLI / Adapter Version | Mode | Repeats | Local Fixture Pass / Denom | Cost Unknown Count | Live API Verified | Residual Limit |
|---|---|---|---|---|---|---|---|
| Mock Baseline | `mock-1.0` / `0.1.0` | `mockFixture` | 3 | 3 / 3 | 3 (`UNKNOWN`) | `false` | Deterministic local supervisor only |
| Claude Code | `2.1.296` / `0.1.0` | `controlledCLIFixture` | 3 | 3 / 3 | 0 (`SUBSCRIPTION_INCLUDED` / fixture) | `false` | Live API calls **NOT RUN** |
| Codex CLI | `0.169.0` / `0.1.0` | `controlledCLIFixture` | 3 | 3 / 3 | 3 (`UNKNOWN`, never `0`-substituted) | `false` | Live API calls **NOT RUN** |

---

## 4. Core Requirements Traceability (`R-01`..`R-12`)

| ID | Owner / Module | Contract / Unit Evidence | Local Suite Status | Product Gate Status | Residual Limits |
|---|---|---|---|---|---|
| R-01 | ARC-01/02 (`AnalyzerSafeRoot`, `AnalyzerExclusions`, `AnalyzerProfileDraft`) | `Analyzer*Tests`, [exclusions-v1.md](analyzer/exclusions-v1.md) | PASS | NOT RUN | Real macOS TCC / OS file observer |
| R-02 | ARC-03 (`RecommendationService`, `ArchitectureCandidateGenerator`) | `Architecture*Tests`, `Recommendation*Tests`, [imp-11-recommendation-evidence.md](imp-11-recommendation-evidence.md) | PASS | NOT RUN | Human domain appropriateness approval |
| R-03 | ARC-04/05 (`AgentDefinitionValidator`, `AgentApplyJournal`) | `AgentDefinition*Tests`, `AgentApply*Tests`, [imp-09-validation-evidence.md](imp-09-validation-evidence.md) | PASS | NOT RUN | Live FS race injection on real hosts |
| R-04 | ARC-05/06 (`ProviderRegistryAndAccounts`, `ClaudeCodeAdapter`, `CodexCLIAdapter`) | `ProviderAdaptersAndCostTests`, `ProviderCapabilityTests`, [imp-15-claude-evidence.md](imp-15-claude-evidence.md), [imp-17-codex-evidence.md](imp-17-codex-evidence.md) | PASS | BLOCKED (`NOT RUN`) | Live official Claude/Codex login & API execution |
| R-05 | ARC-06/07/10 (`SchedulerRunRepository`, `MockRuntimeSupervisor`, `SQLiteStore`) | `SchedulerRunRepositoryTests`, `MockRuntimeSessionTests`, [imp-12-scheduler-evidence.md](imp-12-scheduler-evidence.md) | PASS | BLOCKED (`NOT RUN`) | Live external child CLI process observation |
| R-06 | ARC-07/09 (`TaskDependencyValidator`, `PolicyAndApproval`, `AuthorizationEnforcer`) | `TaskDependencyValidatorTests`, `PolicyAndApprovalTests`, [imp-12-scheduler-evidence.md](imp-12-scheduler-evidence.md) | PASS | BLOCKED (`NOT RUN`) | OS sandbox enforcement unproven in v1 (R9) |
| R-07 | ARC-08/10 (`MemoryStore`, `ContextBuilder`) | `MemoryAndContextTests`, [imp-14-memory-evidence.md](imp-14-memory-evidence.md) | PASS | NOT RUN | Live LLM external transfer consent flow |
| R-08 | ARC-09/10 (`EvaluationEngine`, `EvaluationVerdictStore`, `CostAccountingEngine`) | `EvaluationObservabilityTests`, `ReleaseGateEvaluatorTests`, [imp-13-evaluation-evidence.md](imp-13-evaluation-evidence.md) | PASS | NOT RUN | Human 2-reviewer evaluation set |
| R-09 | ARC-06/10 (`SQLiteStorage`, `BackupAndDeletionRecovery`, `FreshnessAnchorAndLedger`) | `SQLiteStorageTests`, `FreshnessAnchorRecoveryTests`, [imp-14-memory-evidence.md](imp-14-memory-evidence.md) | PASS | NOT RUN | Hardware power-loss durability test |
| R-10 | ARC-11..14 (`NoiseIKChannel`, Chrome & VS Code Extensions, `PackagingAndMigrationManager`) | `NoiseIKChannelTests`, `NativeMessagingHostGateTests`, `chrome_extension.test.mjs`, `vscode_extension.test.mjs` | PASS | BLOCKED (`NOT RUN`) | Real browser/IDE/macOS notarized runtime |
| R-11 | ARC-15 (`TemplateSnapshotRepository`, `TemplateGraphDecoder`, `TemplateExchangeCandidate`) | `Template*Tests`, [imp-10-graph-evidence.md](imp-10-graph-evidence.md) | PASS | NOT RUN | End-to-end GUI graph authoring user study |
| R-12 | ARC-08/10/11 (`BackupAndDeletionRecovery`, `PackagingAndMigrationManager`, `MemoryStore`) | `FreshnessAnchorRecoveryTests`, `PackagingAndMigrationTests`, [imp-21-packaging-evidence.md](imp-21-packaging-evidence.md) | PASS | NOT RUN | Physical disk zeroing guarantees outside SQLite |

## 5. Verification Plan Scenarios (`V-01`..`V-23`)

| ID | Owner / Module | Contract / Unit Evidence | Local Suite Status | Product Gate Status | Residual Limits |
|---|---|---|---|---|---|
| V-01 | `apps/desktop/lib/state/vertical_flow_controller.dart`, `MockRuntimeSupervisor` | `apps/desktop/test/vertical_flow_test.dart`, `MockRuntimeSessionTests` | PASS | NOT RUN | Real live Flutter+XPC cancellation |
| V-02 | `AnalyzerSafeRoot`, `AnalyzerExclusions` | `AnalyzerSafeRootTests`, `AnalyzerExclusionsTests` | PASS | NOT RUN | Live APFS symlink / permissions edge test |
| V-03 | `ArchitectureCandidateGenerator`, `RecommendationService` | `ArchitectureCandidateGeneratorTests` | PASS | NOT RUN | Real repository semantic review |
| V-04 | `AgentExportPlan`, `AgentApplyAuthorization` | `AgentExportPlanTests`, `AgentApplyAuthorizationTests` | PASS | NOT RUN | Concurrent external editor test |
| V-05 | `CapabilitySnapshotValidator`, `ProviderRegistryAndAccounts` | `ProviderCapabilityTests`, `ProviderAdaptersAndCostTests` | PASS | NOT RUN | Multi-account isolation with real keys |
| V-06 | `SchedulerRunRepository`, `RuntimePrepareAndStartGate` | `SchedulerRunRepositoryTests` | PASS | NOT RUN | OS crash + PID reuse live test |
| V-07 | `SchedulerRunRepository.cancelTask`, `applyEvaluation` | `SchedulerRunRepositoryTests` | PASS | NOT RUN | Real POSIX SIGTERM/SIGINT signal race |
| V-08 | `ContextBuilder`, `MemoryStore`, `BackupAndDeletionRecovery` | `MemoryAndContextTests` | PASS | NOT RUN | External egress proxy verification |
| V-09 | `PolicyAndApproval`, `AuthorizationEnforcer`, `EnrolledKeyChannelAuthority` | `PolicyAndApprovalTests`, `NoiseIKChannelTests` | PASS | NOT RUN | Desktop GUI trusted approval hardware test |
| V-10 | `SQLiteStore.commitTransition`, `EvaluationVerdictStore` | `SQLiteStorageTests`, `SchedulerRunRepositoryTests` | PASS | NOT RUN | Process kill during WAL fsync |
| V-11 | `ArtifactManifestStore`, `EvaluationEngine`, `EvaluationVerdictStore` | `EvaluationObservabilityTests`, `SchedulerRunRepositoryTests` | PASS | NOT RUN | Independent file watcher daemon |
| V-12 | `SQLiteStore.listEvents`, `PackagingAndMigrationManager` | `SQLiteStorageTests`, `PackagingAndMigrationTests` | PASS | NOT RUN | Crash injector harness |
| V-13 | `ServiceDiscoveryAndKeyLifecycle`, `AuthorizationEnforcer`, `MacOSXPCIdentity` | `MacOSXPCIdentityTests`, `CoreBoundaryTests` | PASS | NOT RUN | Signed macOS XPC peer runtime |
| V-14 | `PackagingAndMigrationManager`, `ChromeWorkerController`, `VSCodeExtensionController` | `NativeMessagingHostGateTests`, `chrome_extension.test.mjs`, `vscode_extension.test.mjs` | PASS | NOT RUN | Real VS Code & Chrome release runtimes |
| V-15 | `TemplateExchangeCandidate`, `TemplateSnapshotRepository`, `TemplateValidationReport` | `TemplateExchangeCandidateTests`, `TemplateSnapshotRepositoryTests` | PASS | NOT RUN | User template import fuzzing |
| V-16 | `BackupAndDeletionRecovery`, `MemoryStore` | `FreshnessAnchorRecoveryTests`, `MemoryAndContextTests` | PASS | NOT RUN | OS Time Machine backup restore drill |
| V-17 | `BackupAndDeletionRecovery`, `FreshnessAnchorAndLedger` | `FreshnessAnchorRecoveryTests` | PASS | NOT RUN | Offline SQLite generation replay drill |
| V-18 | `FreshnessAnchorAndLedger` | `FreshnessAnchorRecoveryTests` | PASS | NOT RUN | Hardware enclave anchor storage |
| V-19 | `IndependentObservationVerifier`, `EvaluationEngine` | `EvaluationObservabilityTests` | PASS | NOT RUN | OS EndpointSecurity / FSEvents observer |
| V-20 | `CostAccountingEngine`, `ProviderComparisonHarness` | `ProviderAdaptersAndCostTests`, `ReleaseGateEvaluatorTests` | PASS | NOT RUN | Authoritative billing CSV reconciliation |
| V-21 | `NativeMessagingHostGate`, `ChromeWorkerController`, `content_script.mjs` | `NativeMessagingHostGateTests`, `chrome_extension.test.mjs` | PASS | NOT RUN | Live Chrome renderer tab-swap test |
| V-22 | `EnrolledKeyChannelAuthority`, `NoiseIKChannel` | `NoiseIKChannelTests` | PASS | NOT RUN | Same-user hostile relay simulation in OS |
| V-23 | `JSONCanonicalization`, `RawJSONKeyValidator`, `noise_ik_reference.mjs` | `JSONCanonicalizationTests`, `RawJSONKeyValidatorTests`, `NoiseIKChannelTests` | PASS | NOT RUN | Full cross-platform Unicode JCS corpus |

## 6. Cross-Contract Acceptance Matrix (`X01`..`X24`)

| ID | Owner / Module | Contract / Unit Evidence | Local Suite Status | Product Gate Status | Residual Limits |
|---|---|---|---|---|---|
| X01 | ARC-01/03 (`ArchitectureCandidateGenerator`, `ArchitectureProposalRepository`) | `ArchitectureProposalRepositoryTests` | PASS | NOT RUN | Live profile-proposal UI roundtrip |
| X02 | ARC-03 (`RecommendationVersionPins`) | `RecommendationVersionPinsTests` | PASS | NOT RUN | Live snapshot invalidation flow |
| X03 | ARC-03/11 (`TemplateSnapshotRepository`, `AuthorizationEnforcer`) | `CoreBoundaryTests`, `TemplateSnapshotRepositoryTests` | PASS | NOT RUN | Cross-user ACL penetration test |
| X04 | ARC-04/15 (`TemplateSnapshotRepository`) | `TemplateSnapshotRepositoryTests` | PASS | NOT RUN | Multi-client template edit conflict test |
| X05 | ARC-04 (`AgentDefinitionRepository`, `TemplateValidationReport`) | `TemplateValidationReportTests` | PASS | NOT RUN | Definition hot-reload end-to-end test |
| X06 | ARC-04 (`GraphPortValidator`, `TemplateGraphDecoder`) | `GraphPortValidatorTests`, `TemplateGraphDecoderTests` | PASS | NOT RUN | Adversarial YAML/JSON fuzzing |
| X07 | ARC-04/05 (`AgentExportPlan`, `CapabilitySnapshotValidator`) | `AgentExportPlanTests` | PASS | NOT RUN | Provider config round-trip on live CLI |
| X08 | ARC-04 (`AgentApplyJournal`, `AgentConfigFileWriter`) | `AgentConfigFileWriterTests` | PASS | NOT RUN | Concurrent FS modification test |
| X09 | ARC-05 (`CapabilitySnapshotValidator`, `ClaudeCodeAdapter`) | `ProviderCapabilityTests` | PASS | NOT RUN | Real CLI binary upgrade on host |
| X10 | ARC-06 (`RuntimePrepareAndStartGate`, `SchedulerRunRepository`) | `SchedulerRunRepositoryTests` | PASS | NOT RUN | Real external process + transfer block |
| X11 | ARC-06/07 (`SchedulerRunRepository`) | `SchedulerRunRepositoryTests` | PASS | NOT RUN | Crash recovery with real PID/start time |
| X12 | ARC-06/07 (`SchedulerRunRepository`, `MockRuntimeSupervisor`) | `SchedulerRunRepositoryTests` | PASS | NOT RUN | Real OS signal delivery timing |
| X13 | ARC-10 (`SQLiteStore.commitTransition`) | `SQLiteStorageTests` | PASS | NOT RUN | Multi-process IPC retry storm |
| X14 | ARC-10 (`SQLiteStore`, `PackagingAndMigrationManager`) | `SQLiteStorageTests`, `PackagingAndMigrationTests` | PASS | NOT RUN | Physical I/O error injection |
| X15 | ARC-10 (`SQLiteStore.listEvents`, `VSCodeExtensionController`) | `SQLiteStorageTests`, `vscode_extension.test.mjs` | PASS | NOT RUN | 100 events/s burst recovery benchmark |
| X16 | ARC-08/09 (`ContextBuilder`) | `MemoryAndContextTests` | PASS | NOT RUN | Outbound firewall verification |
| X17 | ARC-08/10 (`MemoryStore`, `BackupAndDeletionRecovery`) | `MemoryAndContextTests`, `FreshnessAnchorRecoveryTests` | PASS | NOT RUN | Spotlight/FTS external index leak check |
| X18 | ARC-08 (`ContextBuilder`) | `MemoryAndContextTests` | PASS | NOT RUN | Token-budget UI truncation inspection |
| X19 | ARC-09/10 (`EvaluationVerdictStore`, `ArtifactManifestStore`, `SchedulerRunRepository`) | `EvaluationObservabilityTests`, `SchedulerRunRepositoryTests` | PASS | NOT RUN | Real build artifact hashing daemon |
| X20 | ARC-09/10 (`EvaluationEngine`, `EvaluationVerdictStore`) | `EvaluationObservabilityTests`, `SchedulerRunRepositoryTests` | PASS | NOT RUN | Mutable FS race between verdict & commit |
| X21 | ARC-09 (`EvaluationEngine`) | `EvaluationObservabilityTests` | PASS | NOT RUN | Disk-full evaluation commit fault |
| X22 | ARC-11 (`AuthorizationEnforcer`, `EnrolledKeyChannelAuthority`) | `NoiseIKChannelTests`, `chrome_extension.test.mjs`, `vscode_extension.test.mjs` | PASS | NOT RUN | Real signed XPC + extension roundtrip |
| X23 | ARC-11/12/13 (`EnrolledKeyChannelAuthority`, `NativeMessagingHostGate`, `VSCodeExtensionController`) | `NativeMessagingHostGateTests`, `chrome_extension.test.mjs`, `vscode_extension.test.mjs` | PASS | NOT RUN | Live malicious extension test in IDE/Chrome |
| X24 | ARC-11/13/14 (`ChromeWorkerController`, `PackagingAndMigrationManager`, `ProtocolNegotiation`) | `chrome_extension.test.mjs`, `PackagingAndMigrationTests`, `ProtocolNegotiationTests` | PASS | NOT RUN | Real Chrome Service Worker eviction test |

## 7. Non-Functional Gates (`A11Y-01`..`05`, `PERF-01`..`05`) & Compatibility Gates (`CP-01`..`07`)

| ID | Category | Contract / Unit Evidence | Local Status | Product Gate Status | Residual Limits |
|---|---|---|---|---|---|
| A11Y-01 | Keyboard navigation 100% flow | `apps/desktop/lib/ui/vertical_flow_shell.dart` keyboard-reachable controls & `vertical_flow_test.dart` | Partial (Widget) | NOT RUN | Full macOS VoiceOver + extension keyboard audit |
| A11Y-02 | Screen reader roles/labels/focus | Semantics & accessible button labels in Desktop, Side Panel, Webview | Partial (Static) | NOT RUN | Live assistive-tech traversal verification |
| A11Y-03 | Non-color state indicators | Explicit status strings (`Blocked`, `Unknown`, `APPROVAL_REQUIRED`, `STALE`) across Core/Desktop/Extensions | PASS (Unit/Widget) | NOT RUN | Live WCAG 4.1.3 live-region announcements |
| A11Y-04 | 1280×720 & 200% zoom layout | Responsive wrapping in `vertical_flow_shell.dart` & extension panels | Partial (Static) | NOT RUN | Real 200% macOS/browser zoom screenshots |
| A11Y-05 | Input/approval failure safety | Explicit error/recovery text with zero auto-execution on warnings | PASS (Unit/Widget) | NOT RUN | Human usability & assistive-tech failure drill |
| PERF-01 | Analyzer 1,000 files / 10 MiB <= 30s (30 runs p95) | Bounded limits enforced (`AnalyzerSafeRoot`) | NOT RUN | NOT RUN | Single dedicated hardware 30-run benchmark needed |
| PERF-02 | 100 templates local search <= 1s (30 runs p95) | `TemplateSnapshotRepository` indexed lookups | NOT RUN | NOT RUN | 100-template p95 timing suite needed |
| PERF-03 | Cancel click -> `CancelRequested` <= 1s (30 runs p95) | `SchedulerRunRepository.cancelTask` | NOT RUN | NOT RUN | Live GUI-to-XPC latency measurement needed |
| PERF-04 | 100 events/s × 10s snapshot/cursor recovery <= 5s | `SQLiteStore.listEvents` & cursor recovery verified logically | NOT RUN | NOT RUN | 30-run synthetic event storm benchmark needed |
| PERF-05 | Missing cost -> `unknown` (never 0) | `CostAccountingEngine`, `ReleaseGateEvaluatorTests` | PASS (Unit) | NOT RUN | Live billing statement reconciliation |
| CP-01 | Documented events vs verified adapter | `ProviderCapabilityValidator`, `ProviderComparisonHarness` | PASS (Unit) | NOT RUN | Real live Claude/Codex stream test |
| CP-02 | CLI/Adapter version change invalidation | `CapabilitySnapshotValidator`, `PackagingAndMigrationTests` | PASS (Unit) | NOT RUN | Real CLI version upgrade drill |
| CP-03 | Account isolation unproven classification | `ProviderRegistryAndAccounts` | PASS (Unit) | NOT RUN | Live multi-account test |
| CP-04 | VS Code remote URI blocking (P8) | `apps/vscode-extension/src/environment_guard.mjs`, `vscode_extension.test.mjs` | PASS (Unit) | UNSUPPORTED (v1) | SSH/WSL/Container intentionally disabled in v1 |
| CP-05 | Chrome Worker restart recovery | `apps/chrome-extension/src/worker_controller.mjs`, `chrome_extension.test.mjs` | PASS (Unit) | NOT RUN | Real Chrome Service Worker idle eviction |
| CP-06 | Official CLI license/ToS distinction | `ClaudeCodeAdapter`, `CodexCLIAdapter`, `ReleaseGateEvaluator` | PASS (Unit) | BLOCKED (`NOT RUN`) | Human commercial/ToS compliance review |
| CP-07 | Unknown/subscription cost non-zero-substitution | `CostAccountingEngine`, `ReleaseGateEvaluatorTests` | PASS (Unit) | NOT RUN | Real subscription & API billing comparison |
