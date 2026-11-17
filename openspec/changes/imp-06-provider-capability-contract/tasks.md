# Tasks: IMP-06 Provider Installation, Account References, and Capability Contract

## 1. Provider Discovery, Opaque Account References, and Credential Exclusion (Sub-PR A)

- [x] 1.1 Create `imp-06-provider-capability-contract` OpenSpec change and validate schema.
- [x] 1.2 Implement `ProviderInstallation`, `AccountAuthState`, opaque `AccountReference` SQLite storage, and `CredentialSanitizer` in `ProviderRegistryAndAccounts.swift`.
- [x] 1.3 Add tests for installation discovery, binary hash/version change detection, `AccountAuthState` transitions, and zero-credential enforcement in DB/logs.

## 2. Scoped Capability Snapshot and Concurrent Isolation Gate (Sub-PR B)

- [ ] 2.1 Implement all 12 `CapabilityID`s, 14-axis `CapabilityScope`, `CapabilitySnapshot` (`documented` fail-closed rule), `CapabilityEvaluator` (staleness, remote guard, required intersection), and `evaluateConcurrentAccountIsolation` in `CapabilitySnapshotValidator.swift`.
- [ ] 2.2 Add V-05 & CV01~CV18 regression tests covering unknown/documented-only blocking, all scope axis staleness checks, remote workspace blocking, and concurrent isolation blocking.
- [ ] 2.3 Sync `provider-capability` spec to `openspec/specs/` and archive `imp-06-provider-capability-contract`.
