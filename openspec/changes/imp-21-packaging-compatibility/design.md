# Design

- **Install Mode & Protocol Compatibility (`PackagingAndMigrationManager.swift`)**:
  - `validateInstallMode` enforces P9: only `bundledLocalDesktopAndCore` is allowed in v1; standalone Core without Desktop and remote distribution fail closed.
  - Delegates protocol negotiation to `negotiateProtocol(local:remote:)` (W8: exact major + overlapping minor range) and verifies `binaryMaxSupportedSchemaVersion >= dbSchemaVersion` so a rolled-back older binary refuses to mutate or auto-run against a newer schema (`newerSchemaRequiresRecovery`).
- **Artifact Integrity & Signing Metadata (`ArtifactSignatureVerifier`)**:
  - Computes CryptoKit SHA-256 of staged update binaries against manifest digest and checks Developer ID Team ID + notarization ticket requirement for release builds, keeping unsigned local development verification distinct from `NOT RUN` Apple notarization and Gatekeeper release gates.
- **SQLite Pre-Upgrade Backup & Rollback (`SQLiteMigrationManager`)**:
  - Checks Core single-ownership (`activeCoreOwnerPID == nil`), snapshots a byte-identical `.pre-upgrade.bak` + SHA-256 digest before `BEGIN IMMEDIATE`, runs migrations inside the transaction, and restores the byte-identical backup if any SQL statement fails or crashes before commit.
- **Native Host Registration & Uninstall (`NativeHostRegistrationManager`, `UninstallPlanner`)**:
  - Validates POSIX permissions (rejecting group/world-writable `0o022`), delegates JSON validation to `NativeMessagingManifestSpec.parseAndValidate`, and flags `requiresCoreReverification = true` on manifest/binary digest drift.
  - Separates client registration revocation, app bundle removal, and explicit opt-in workspace data deletion (`userConfirmedDataPurge`), while unconditionally preserving Provider official login paths (`~/.claude`, `~/.codex`, OS keychain entries).
