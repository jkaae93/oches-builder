# macos-xpc-identity Specification

## Purpose

Enforces mutual macOS peer code-signing identity verification, protected key boundaries without plaintext fallback, restricted pre-authentication discovery, fail-closed key rotation/revocation, and risk-mutation gating.

## Requirements

### Requirement: Mutual macOS peer code-signing requirement enforcement
Both sides of a macOS Desktop↔Core XPC boundary SHALL enforce a single mutual peer identity requirement verifying an Apple-anchored distribution signature matching both expected Team ID and expected signing identifier, rejecting ad-hoc signatures, wrong teams, tampered binaries, duplicate requirement setup, and UID/PID-only claims.

#### Scenario: Ad-hoc, wrong-team, or tampered Mach-O binary rejected
- **WHEN** a peer binary is ad-hoc signed, signed by another team, has a mismatched signing identifier, or is modified after signing
- **THEN** signature inspection and `XPCConnectionRequirementGuard` deny the connection and record no active authenticated session

### Requirement: Protected key boundary without plaintext fallback
Signing and key-agreement keys SHALL reside behind `ProtectedKeyStore` abstractions and SHALL fail closed with `KEY_UNAVAILABLE` (`UNAVAILABLE`) when locked or inaccessible, never falling back to plaintext file storage.

#### Scenario: Key access unavailable or locked
- **WHEN** the protected key store is locked or raises an access failure
- **THEN** key operations fail with `KEY_UNAVAILABLE` and create no plaintext key artifacts

### Requirement: Restricted bootstrap discovery and risk-mutation gate
Pre-authentication service discovery SHALL expose only protocol version ranges and Core public key identifiers, blocking protected operations and blocking high-risk mutations until distribution-signed positive control is verified.

#### Scenario: Risky mutation before distribution-signed positive control
- **WHEN** a risky mutation or execution is requested without a verified distribution-signed positive control
- **THEN** the gate denies the request fail-closed

### Requirement: Fail-closed key rotation and client revocation
Key rotation SHALL revoke the prior key and active sessions before activating the replacement key without simultaneous active keys or automatic rollback on failure; client revocation SHALL increment policy version, close active sessions, and deny subsequent requests.

#### Scenario: Interrupted key rotation leaves zero active keys
- **WHEN** key rotation fails or lacks trusted Desktop UI confirmation after revoking the old key
- **THEN** both the old key and unconfirmed new key are rejected with zero simultaneous active keys and zero automatic rollback
