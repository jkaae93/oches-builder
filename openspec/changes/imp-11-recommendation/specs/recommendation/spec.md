# Recommendation

## ADDED Requirements

### Requirement: Deterministic constraints
Each versioned constraint SHALL be evaluated against typed candidate facts. Missing or incompatible facts SHALL remain unknown and violations SHALL reject the candidate.

#### Scenario: Unknown required capability
- **WHEN** a required fact cannot be established
- **THEN** the recommendation cannot claim that requirement is satisfied

### Requirement: Baseline and provenance
Recommendations SHALL include a Single Agent baseline and preserve evidence, assumptions, alternatives and input versions. Recommendation acceptance SHALL NOT authorize execution.

#### Scenario: Changed input
- **WHEN** a referenced Profile, definition, capability or policy version changes
- **THEN** the previous proposal requires revalidation
