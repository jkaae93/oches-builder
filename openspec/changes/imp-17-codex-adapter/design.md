# Design

Follow `ARC-05.md`, `ARC-06.md`, `PROVIDER_MVP_FEASIBILITY.md`, and `PROVIDER_FORMAT_EVIDENCE.md`.

1. `CodexCLIAdapter` pins compatible local versions (`0.155.1`, `0.169.0`), enforces trusted workspace, authenticated account ref, verified execution and external transfer approvals, verified capabilities (`providerInstall`, `authOfficial`, `runStart`, optional `runResume` + terminal predecessor, `authAccountIsolation`), and fail-closed budget gating (blocking hard monetary cap requests because `codex exec` does not expose a provider-enforced monetary spend cap).
2. Explicitly prohibits `--trust`, `--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`, `--approve-for-me`, and `danger-full-access`, keeping sandbox modes strictly limited to `read-only` and `workspace-write` with `--ephemeral` by default.
3. `parseJSONL` and `reconcileOutcome` treat `exit 0` without `turn.completed` or with truncated/malformed JSONL as `Unknown`, never `Succeeded`. `buildCostRecord` uses `.subscriptionIncluded` for subscription accounts, `.rateTableEstimate` only when API-key usage and a verified rate card are present, and `.unknown` (`amountMicroUSD == nil`) otherwise.
4. `ProviderComparisonHarness` aggregates Mock, Claude, and Codex comparison entries under identical fixture, capability, and evaluation contracts while keeping `liveProviderVerified == false` whenever runs use mock or controlled local stubs rather than live billable API execution.
