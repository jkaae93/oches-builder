# Release Verification, Traceability, and Phase Gates

## ADDED Requirements

### Requirement: Honest status, denominator integrity, and release gate blocking
Release evaluation SHALL require every tracked evidence record to declare `version`, `environment`, `repeats`, `passedCount`, and `denominator`, SHALL reject `.pass` claims with zero or partial denominators or unresolved product residuals, and SHALL evaluate Phase 1 and Phase 2 release gates as `BLOCKED` whenever live Provider APIs, OS observer, notarization, accessibility, performance, or store gates remain `NOT RUN`.

#### Scenario: Unit suites pass while product gates remain NOT RUN
- **WHEN** automated unit/contract tests achieve 100% pass rates while required product gates record `notRun`
- **THEN** the Phase 1 and Phase 2 release gate verdicts evaluate strictly to `blocked` enumerating every blocking gate

### Requirement: Complete traceability and paired comparison integrity
Traceability verification SHALL account for all `R-01..R-12`, `V-01..V-23`, `X01..X24`, `A11Y-01..05`, `PERF-01..05`, and `CP-01..07` requirements with explicit local-suite vs product-gate statuses, and paired Mock/Claude/Codex comparison summaries SHALL preserve every failure/unknown cost count without zero-substitution.

#### Scenario: Unknown costs and 3-repeat paired comparison
- **WHEN** paired runs across Mock, Claude fixture, and Codex fixture include entries with `unavailable` cost
- **THEN** summaries report exact repeat denominators, non-zero `costUnavailableCount`, and `liveProviderVerified = false`
