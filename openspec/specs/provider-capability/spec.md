# provider-capability Specification

## Purpose

Defines official provider installation tracking, credential-free opaque account references, 14-axis scoped capability snapshots, documented-only fail-closed rules, and concurrent account isolation gating.

## Requirements

### Requirement: Official provider installation tracking and credential-free account references
The Core SHALL record provider installations with executable SHA-256 identity and version, manage `AccountAuthState` transitions via official checks without turning query failures into `authenticated` or `unsupported`, and reject any credentials, cookies, or raw tokens from opaque `AccountReference` rows and logs.

#### Scenario: Credential or token detected in reference or diagnostic text
- **WHEN** an account reference or diagnostic string contains bearer tokens, API key prefixes, or cookie headers
- **THEN** `CredentialSanitizer` rejects the input with `INVALID_INPUT` and persists zero credentials to SQLite or logs

### Requirement: 14-axis scoped CapabilitySnapshot and concurrent account isolation gate
`CapabilityEvaluator` SHALL evaluate required capabilities against an exact 14-axis `CapabilityScope`, treating `basis=documented` without verification as `unknown`, marking any scope/version/binary change as `STALE`, blocking remote workspace locations without `client.remoteWorkspace=supported`, and blocking concurrent runs unless `auth.accountIsolation=supported`.

#### Scenario: Documented-only capability or unknown required capability
- **WHEN** a required capability has status `unknown` or only `basis=documented`
- **THEN** execution gating blocks the action rather than inferring support

#### Scenario: Scope axis mismatch or binary version change
- **WHEN** any of the 14 `CapabilityScope` axes (`accountRef`, `workspaceID`, `workspaceLocationAuthority`, `workspaceTrust`, `clientID`, `clientKind`, `cliVersion`, `executableIdentity`, `adapterVersion`, `policyVersion`, protocol version) changes
- **THEN** the snapshot evaluates as `STALE` and blocks reuse

#### Scenario: Unverified account isolation under concurrent runs
- **WHEN** an active attempt exists and `auth.accountIsolation` is not `supported`
- **THEN** concurrent execution start is blocked fail-closed
