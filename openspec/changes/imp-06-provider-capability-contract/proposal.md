# Proposal

## Why

`ARC-05.md`, `CAPABILITY_CONTRACT_V1.md`, and `PROVIDER_MVP_FEASIBILITY.md` require separating official provider installation detection, opaque `AccountReference` management (zero credentials stored in SQLite or logs), 14-axis scoped `CapabilitySnapshot` verification, and fail-closed gating when required capabilities are `unknown`, `unsupported`, `documented`-only, `stale`, or lack verified `auth.accountIsolation` for concurrent runs (`V-05`, `CV01`~`CV18`).

## What Changes

- Implement `ProviderInstallation`, `AccountAuthState` state machine, opaque `AccountReference` storage in SQLite (`provider_installations`, `account_references`), and strict `CredentialSanitizer` rejecting bearer tokens, API keys, cookies, or session tokens in references or diagnostic logs.
- Implement `CapabilityID` (all 12 capability IDs), 14-axis `CapabilityScope`, `CapabilityEntry`, `CapabilitySnapshot` (`basis == .documented` never promotes to `.supported` without experiment/policy verification), `CapabilityEvaluator` (detecting staleness on any scope axis change, blocking remote workspaces when `client.remoteWorkspace != .supported`, blocking `unknown` / `unsupported`), and `evaluateConcurrentAccountIsolation` blocking concurrent attempts when `auth.accountIsolation != .supported`.

Explicit non-goals: real Claude Code / Codex CLI invocation (`IMP-15` / `IMP-17`).

## Capabilities

### New Capabilities

- `provider-capability`: Provider installation discovery, opaque credential-free account references, 14-axis scoped capability snapshots, and concurrent isolation gating.

### Modified Capabilities

None.

## Impact

- `docs/architecture/ARC-05.md`
- `docs/architecture/CAPABILITY_CONTRACT_V1.md`
- `docs/architecture/PROVIDER_MVP_FEASIBILITY.md`
- `core/Sources/OchesCore/ProviderRegistryAndAccounts.swift`
- `core/Sources/OchesCore/CapabilitySnapshotValidator.swift`
