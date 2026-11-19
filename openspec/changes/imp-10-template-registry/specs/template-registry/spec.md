# Template Registry

## ADDED Requirements

### Requirement: Explicit acyclic task order
Task dependencies SHALL be acyclic and reference unique existing tasks. Data flow SHALL NOT create implicit execution ordering; a required producer/consumer order SHALL be present in the dependency graph.

#### Scenario: Data without dependency
- **WHEN** data flows from one task to another without an explicit dependency path
- **THEN** structural validation blocks execution rather than adding an inferred dependency

### Requirement: Immutable template and independent instance
Published versions SHALL remain immutable and instance edits SHALL preserve the source and other instances. Import SHALL NOT execute project or Provider operations.

#### Scenario: Independent instance edit
- **WHEN** one instance is edited
- **THEN** the original published version and other instances retain their contents
