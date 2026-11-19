# Claude Primary Adapter and Cost Accounting

## ADDED Requirements

### Requirement: Five-state cost accounting and immutable revisions (E3 / V-20)
Cost persistence and aggregation SHALL distinguish `AUTHORITATIVE_BILLING`, `PROVIDER_REPORTED_ESTIMATE`, `RATE_TABLE_ESTIMATE`, `SUBSCRIPTION_INCLUDED`, and `UNKNOWN`, keep `amountMicroUSD` nil for `UNKNOWN` and `SUBSCRIPTION_INCLUDED`, avoid summing conflicting currencies, validate cache/total input semantics, and append new revisions without overwriting historical estimates.

#### Scenario: Multi-currency, unknown failed attempt, and billing revision
- **WHEN** attempts have mixed currencies, missing usage on failure, subscription inclusion, or a post-hoc billing adjustment
- **THEN** cross-currency totals omit `confirmedTotalMicroUSD` with `currencyConflict = true`, unknown/subscription entries preserve `nil` amount, and billing adjustment appends `revision + 1` preserving earlier estimate history

### Requirement: Fail-closed budget and invocation gates (E4 / V-05)
`ClaudeCodeAdapter` SHALL require trusted workspace, pinned CLI version, authenticated account state, verified execution/transfer approvals, verified capability and account-isolation gates, and fail-closed monetary budget enforcement before spawning.

#### Scenario: Monetary cap on subscription or bypass flag
- **WHEN** a caller requests a monetary budget cap on a subscription account or passes `--dangerously-skip-permissions`
- **THEN** invocation planning rejects before process spawn

### Requirement: Stream-JSON parsing and strict completion reconciliation (V-06)
`ClaudeCodeAdapter` SHALL reject treating `exit 0` with truncated output, missing terminal `result`, or pending background tasks as `Succeeded`, preserving `Unknown` instead.

#### Scenario: Truncated stream or pending background task with exit 0
- **WHEN** Claude `stream-json` terminates with `exitCode = 0` but lacks a non-error terminal `result`, has truncated JSON, or reports active background work
- **THEN** outcome reconciliation returns `Unknown`, never `Succeeded`
