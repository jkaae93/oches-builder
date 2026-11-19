# Agent Definition

## ADDED Requirements

### Requirement: Strict neutral definition
Core SHALL validate version 1.0 definitions with the frozen ARC-04 fields and S3 bounds, rejecting unknown fields, duplicate keys, invalid identifiers, duplicate direction-specific ports and unsafe resource limits.

#### Scenario: Invalid definition
- **WHEN** a definition includes credentials, an unknown field or duplicate ports
- **THEN** validation fails without filesystem changes or provider execution

### Requirement: Evidence-bound application
Export plans SHALL bind definition, Adapter, capability and target revisions. Mandatory safety mappings that are lossy, unsupported or unknown SHALL block application. Application SHALL require verified plan-bound approval and report Partial or Unknown when all writes cannot be confirmed.

#### Scenario: Target changes after approval
- **WHEN** the target revision changes before application
- **THEN** the operation rejects the stale plan without overwriting the target
