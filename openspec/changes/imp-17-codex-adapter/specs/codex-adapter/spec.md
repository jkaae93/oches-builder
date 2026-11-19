# Codex Comparison Adapter

## ADDED Requirements

### Requirement: Safe invocation planning and bypass prohibition
`CodexCLIAdapter` SHALL forbid `--trust`, `--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`, `--approve-for-me`, and `danger-full-access`, enforce version/capability/approval gates, and fail closed when a monetary spend cap is requested without provider enforcement.

#### Scenario: Forbidden trust or bypass flags
- **WHEN** `--trust` or any sandbox/approval bypass option is requested
- **THEN** invocation planning rejects with `forbiddenBypassFlag` before spawning

### Requirement: JSONL completion and cost classification
`CodexCLIAdapter` SHALL classify `exit 0` with truncated JSONL or missing `turn.completed` as `Unknown`, never coerce missing prices into `0`, and use `RATE_TABLE_ESTIMATE` only with a verified rate card on API-key accounts.

#### Scenario: Missing dollar fields or incomplete stream
- **WHEN** Codex JSONL terminates with `exitCode = 0` without `turn.completed`, or lacks a verified rate card on an API-key run
- **THEN** incomplete output yields `Unknown` outcome and missing cost yields `UNKNOWN` with `amountMicroUSD == nil`

### Requirement: Cross-provider comparison separation
`ProviderComparisonHarness` SHALL compare Mock, Claude, and Codex entries under matching fixture/evaluation contracts and report `liveProviderVerified = false` unless entries actually ran against live external Provider endpoints.

#### Scenario: Fixture comparison against Mock, Claude, and Codex
- **WHEN** Mock, controlled Claude stub, and controlled Codex stub entries are compared on the same fixture
- **THEN** per-provider cost summaries and evaluation states are reported accurately with `liveProviderVerified = false`
