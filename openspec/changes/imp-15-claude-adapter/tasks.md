# Tasks

- [x] Create OpenSpec specification for IMP-15 cost accounting, budget gate and Claude primary adapter.
- [x] Implement `CostAccountingEngine` with 5 cost states, cache/deduplication guards, currency isolation, immutable revisions and fail-closed budget gate.
- [x] Implement `ClaudeCodeAdapter` with version pinning, forbidden flag guards, `stream-json` parsing, redaction and strict `Unknown`/background reconciliation.
- [x] Add regression tests covering V-05, V-06, V-20, E3, E4 and controlled local subprocess stub execution, and record evidence (`docs/imp-15-claude-evidence.md`).
- [ ] Run live billable Claude CLI execution tests against an isolated approved test account (product/external gate).
