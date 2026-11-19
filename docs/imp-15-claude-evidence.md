# IMP-15 Claude primary adapter and cost accounting progress

Date: 2026-11-19. Issue: #15. OpenSpec: `imp-15-claude-adapter`.

## Implemented Core components

- **Five-state cost accounting & fail-closed budget gate** (`core/Sources/OchesCore/CostAccountingEngine.swift`):
  - Supports `AUTHORITATIVE_BILLING`, `PROVIDER_REPORTED_ESTIMATE`, `RATE_TABLE_ESTIMATE`, `SUBSCRIPTION_INCLUDED`, and `UNKNOWN` in append-only `attempt_cost_records` rows keyed by `(attempt_id, revision)` so billing adjustments append revisions without overwriting earlier estimates.
  - Enforces `amountMicroUSD == nil` for `UNKNOWN` and `SUBSCRIPTION_INCLUDED`, validates cache/total input semantics (`cachedIncludedInTotalInput` vs `cachedSeparateFromUncachedInput`, rejecting `cached > total`), validates event-ID deduplication, blocks cross-currency summation (`currencyConflict = true`, `confirmedTotalMicroUSD = nil`), and preserves unknown/missing-usage counts alongside known subtotals (E3, V-20).
  - Evaluates fail-closed budget gates (`evaluateBudgetGate`), rejecting monetary budget caps on subscription accounts or unverified providers (E4).
- **Claude Code primary adapter** (`core/Sources/OchesCore/ClaudeCodeAdapter.swift`):
  - Pins compatible local CLI version (`2.1.296` observed via `claude --version`), checks trusted workspace, authenticated account ref, execution + external transfer approvals, verified capabilities (`providerInstall`, `authOfficial`, `runStart`, optional `runResume` + terminal predecessor, `authAccountIsolation`), 24-hour wall-clock bound, and rejects bypass flags (`--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, `--bg`, `--background`).
  - Parses `stream-json` lines, redacts secret-like patterns in normalized summaries (with explicit incomplete-masking notice R8), tracks background task state, and treats `exit 0` with truncated streams, missing terminal `result`, or active background work as `Unknown` rather than `Succeeded` (V-05, V-06).

## Verification

- Observed local CLI: `claude --version` -> `2.1.296 (Claude Code)` (non-destructive flag check via `--help` only; no live API call or auth mutation executed).
- `openspec validate imp-15-claude-adapter --strict`: passed.
- `swift test --package-path oches-builder/core --filter "ProviderAdaptersAndCostTests|ProviderCapabilityTests"`: 5/5 tests passed (including controlled local stub subprocess execution of `ClaudeCodeAdapter.runControlledSubprocess`).
- `swift test --package-path oches-builder/core`: full Core suite passed.

## Remaining external/product gates (issue #15 remains open)

- Live billable `claude -p --output-format stream-json` runs against an approved isolated test account remain `NOT RUN` until explicit user approval and credentials are supplied.
