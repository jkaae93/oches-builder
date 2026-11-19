# IMP-17 Codex comparison adapter progress

Date: 2026-11-19. Issue: #17. OpenSpec: `imp-17-codex-adapter`.

## Implemented Core components

- **Codex CLI comparison adapter** (`core/Sources/OchesCore/CodexCLIAdapter.swift`):
  - Pins locally observed CLI versions (`0.155.1` previously documented, `0.169.0` currently observed via `codex --version`), enforces trusted workspace, authenticated account ref, verified execution and external transfer approvals, verified capabilities (`providerInstall`, `authOfficial`, `runStart`, optional `runResume` + terminal predecessor, `authAccountIsolation`), 24h wall-clock limit, and `read-only` / `workspace-write` sandbox modes with `--ephemeral`.
  - Prohibits `--trust`, `--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`, `--approve-for-me`, and `danger-full-access`. Fails closed when a monetary spend cap is requested because `codex exec` does not enforce a provider spend cap.
  - Parses `codex exec --json` JSONL events (`thread.started`, `turn.started`, `item.*`, `turn.completed`, `turn.failed`, unknown events, malformed/truncated lines) and classifies `exit 0` without `turn.completed` or with truncated JSONL as `Unknown`. Computes `.rateTableEstimate` only with verified API-key usage and rate cards, keeping missing prices `UNKNOWN` (`amountMicroUSD == nil`) and subscription usage `SUBSCRIPTION_INCLUDED`.
- **Cross-provider comparison harness** (`core/Sources/OchesCore/ProviderComparisonHarness.swift`):
  - Compares Mock, Claude, and Codex entries under matching fixture and evaluation contracts and keeps `liveProviderVerified == false` unless all compared runs executed against live external Provider APIs.

## Verification

- Observed local CLI: `codex --version` -> `codex-cli 0.169.0` (read-only `--help` flag check; no live API call executed).
- `openspec validate imp-17-codex-adapter --strict`: passed.
- `swift test --package-path oches-builder/core --filter "ProviderAdaptersAndCostTests|ProviderCapabilityTests"`: 5/5 tests passed (including controlled local stub subprocess execution for Codex and cross-provider comparison against Mock and Claude).
- `swift test --package-path oches-builder/core`: full Core suite passed.

## Remaining external/product gates (issue #17 remains open)

- Live billable `codex exec --json` comparison runs against an approved isolated test account remain `NOT RUN`.
