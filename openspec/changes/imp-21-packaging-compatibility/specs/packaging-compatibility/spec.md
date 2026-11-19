# Packaging, Updates, Compatibility, and Rollback

## ADDED Requirements

### Requirement: Bundled v1 installation, protocol/schema compatibility, and artifact verification (ARC-14 / P9 / W8)
Packaging and startup gates SHALL allow only local bundled Desktop+Core installation in v1, enforce protocol major equality and minor range overlap via `negotiateProtocol`, block any binary whose supported `schema_version` is lower than the database schema (`newerSchemaRequiresRecovery`), and reject tampered digests or unnotarized release artifacts.

#### Scenario: Incompatible protocol, tampered artifact, and rolled-back binary schema mismatch
- **WHEN** an installation is standalone Core without Desktop, a binary digest mismatches its manifest, or an older binary attempts to open a newer SQLite schema
- **THEN** startup/installation rejects fail-closed and refuses execution until recovery

### Requirement: Atomic SQLite migration backup/rollback, Native Host hardening, and uninstall separation
Database upgrades SHALL require single Core ownership, create a SHA-256-verified pre-upgrade backup before migration, restore the identical backup upon injected failure, reject world/group-writable Native Host binaries/manifests while triggering Core re-verification on hash changes, and never delete user workspace data without opt-in or delete official Provider credentials.

#### Scenario: Failed migration rollback, writable host rejection, and credential preservation
- **WHEN** a SQLite migration statement fails, a Native Host binary is world-writable or swapped, or uninstall runs without data purge opt-in
- **THEN** the database restores byte-identically to pre-upgrade state, insecure hosts fail validation, binary swaps require re-verification, and workspace data plus Provider credentials remain intact
