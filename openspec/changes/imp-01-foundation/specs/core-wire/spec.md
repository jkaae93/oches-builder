# Core Wire

## Purpose

Defines the shared Core protocol boundary and prevents ambiguous or unsupported requests from becoming executable operations.

## ADDED Requirements

### Requirement: Strict wire input
The Core wire boundary SHALL accept UTF-8 JSON objects only after rejecting duplicate keys, non-finite values, unsafe integer numbers, malformed Unicode, and inputs exceeding documented limits. It SHALL preserve the distinction between omitted fields and null.

#### Scenario: Duplicate member
- **WHEN** a raw JSON object contains the same member name twice
- **THEN** the boundary rejects it before dispatch and performs no operation

#### Scenario: Unsafe numeric identifier
- **WHEN** an integer outside the IEEE-754 safe integer range appears as a JSON number
- **THEN** the boundary rejects it without rounding or dispatch

#### Scenario: Null and omission
- **WHEN** a field's operation schema distinguishes null from omission
- **THEN** validation preserves that distinction and rejects a disallowed form

### Requirement: Canonical request bytes
The boundary SHALL canonicalize accepted JSON using RFC 8785 JCS and SHA-256 without Unicode normalization or silently changing input semantics.

#### Scenario: Independent vectors
- **WHEN** supported values are canonicalized
- **THEN** their bytes match independently sourced RFC 8785 vectors, including UTF-16 key order and numeric serialization

### Requirement: Version negotiation
After authentication, the Core SHALL select the highest common minor version within a common major and the explicitly shared capabilities; it SHALL reject incompatible ranges and unknown required semantics without executing changes.

#### Scenario: Major mismatch
- **WHEN** peers have no common protocol major
- **THEN** the Core returns UNSUPPORTED with VERSION_UNSUPPORTED and does not dispatch a mutation

### Requirement: Request and result boundaries
Requests SHALL identify the negotiated protocol version, client, workspace, request, operation and payload. Responses SHALL associate the request ID with exactly one success or safe error result. Mutation schemas SHALL specify expected revision and approval references where applicable.

#### Scenario: Untrusted identity
- **WHEN** an envelope claims a client identity inconsistent with the verified connection
- **THEN** the request is denied before dispatch

### Requirement: Fail closed until security exists
The scaffold SHALL NOT treat a caller-supplied identity, an unimplemented authentication mechanism, or an unknown authorization result as proof of permission.

#### Scenario: Missing authenticated context
- **WHEN** a protected operation arrives without verified authentication and authorization
- **THEN** it is denied or unavailable and has no side effects

### Requirement: Error and state boundaries
Errors SHALL distinguish invalid input, denial, approval required, conflict, unsupported, unknown and unavailable without disclosing credentials or sensitive content. Revision, store generation and event cursor SHALL retain their separately documented meanings and SHALL NOT imply durable storage before its implementation.

#### Scenario: Storage unavailable
- **WHEN** a response requires a durable state that the scaffold cannot provide
- **THEN** it reports unavailable rather than fabricating a revision or successful result
