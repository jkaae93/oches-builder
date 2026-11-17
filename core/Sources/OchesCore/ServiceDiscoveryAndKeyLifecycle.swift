import Foundation
import SQLite3

public enum ClientTrustLevel: String, Sendable, Equatable, Codable {
    case platformBound = "PLATFORM_BOUND"
    case userEnrolledKey = "USER_ENROLLED_KEY"
}

public enum ClientRegistrationStatus: String, Sendable, Equatable, Codable {
    case pendingUserConfirmation = "PENDING_USER_CONFIRMATION"
    case active = "ACTIVE"
    case revoked = "REVOKED"
    case expired = "EXPIRED"
}

public struct CoreBootstrapDescriptor: Sendable, Equatable {
    public let coreID: String
    public let protocolMajor: UInt32
    public let minimumMinor: UInt32
    public let maximumMinor: UInt32
    public let coreSigningPublicKeyID: String
    public let coreNoisePublicKeyID: String
    public let distributionSignedPeerVerified: Bool

    public init(
        coreID: String,
        protocolMajor: UInt32,
        minimumMinor: UInt32,
        maximumMinor: UInt32,
        coreSigningPublicKeyID: String,
        coreNoisePublicKeyID: String,
        distributionSignedPeerVerified: Bool
    ) {
        self.coreID = coreID
        self.protocolMajor = protocolMajor
        self.minimumMinor = minimumMinor
        self.maximumMinor = maximumMinor
        self.coreSigningPublicKeyID = coreSigningPublicKeyID
        self.coreNoisePublicKeyID = coreNoisePublicKeyID
        self.distributionSignedPeerVerified = distributionSignedPeerVerified
    }

    public func inspectPreAuthRequest(operation: String) -> SafeWireError? {
        if operation == "hello" || operation == "bootstrap" {
            return nil
        }
        return SafeWireError(code: .denied, detail: "AUTH_FAILED")
    }
}

public struct RegisteredClientRecord: Sendable, Equatable {
    public let clientID: String
    public let signingKeyID: String
    public let signingPublicKeyBase64: String
    public let noiseKeyID: String
    public let noisePublicKeyBase64: String
    public let trustLevel: ClientTrustLevel
    public let teamID: String
    public let signingIdentifier: String
    public let allowedWorkspaces: [String]
    public let allowedScopes: [String]
    public let status: ClientRegistrationStatus
    public let policyVersion: UInt64
    public let createdAt: Int64
    public let expiresAt: Int64
    public let revokedAt: Int64?

    public init(
        clientID: String,
        signingKeyID: String,
        signingPublicKeyBase64: String,
        noiseKeyID: String,
        noisePublicKeyBase64: String,
        trustLevel: ClientTrustLevel,
        teamID: String,
        signingIdentifier: String,
        allowedWorkspaces: [String],
        allowedScopes: [String],
        status: ClientRegistrationStatus,
        policyVersion: UInt64,
        createdAt: Int64,
        expiresAt: Int64,
        revokedAt: Int64?
    ) {
        self.clientID = clientID
        self.signingKeyID = signingKeyID
        self.signingPublicKeyBase64 = signingPublicKeyBase64
        self.noiseKeyID = noiseKeyID
        self.noisePublicKeyBase64 = noisePublicKeyBase64
        self.trustLevel = trustLevel
        self.teamID = teamID
        self.signingIdentifier = signingIdentifier
        self.allowedWorkspaces = allowedWorkspaces
        self.allowedScopes = allowedScopes
        self.status = status
        self.policyVersion = policyVersion
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }
}

public struct AuthenticatedConnectionSession: Sendable, Equatable {
    public let sessionID: String
    public let clientID: String
    public let keyID: String
    public let trustLevel: ClientTrustLevel
    public let policyVersion: UInt64
    public let distributionSignedPeerVerified: Bool
    public let active: Bool

    public init(
        sessionID: String,
        clientID: String,
        keyID: String,
        trustLevel: ClientTrustLevel,
        policyVersion: UInt64,
        distributionSignedPeerVerified: Bool,
        active: Bool
    ) {
        self.sessionID = sessionID
        self.clientID = clientID
        self.keyID = keyID
        self.trustLevel = trustLevel
        self.policyVersion = policyVersion
        self.distributionSignedPeerVerified = distributionSignedPeerVerified
        self.active = active
    }
}

public enum RegistryLifecycleError: Error, Sendable, Equatable {
    case clientNotFound
    case clientNotActive
    case invalidChallenge
    case challengeReplayOrExpired
    case signatureVerificationFailed
    case trustedUIConfirmationRequired
    case rotationInterruptedNoActiveKey
    case distributionPositiveControlRequired
    case storageFailure(String)

    public var safeWireError: SafeWireError {
        switch self {
        case .distributionPositiveControlRequired, .trustedUIConfirmationRequired:
            return SafeWireError(code: .denied, detail: "AUTH_FAILED")
        case .clientNotFound, .clientNotActive, .invalidChallenge, .challengeReplayOrExpired, .signatureVerificationFailed, .rotationInterruptedNoActiveKey:
            return SafeWireError(code: .denied, detail: "AUTH_FAILED")
        case .storageFailure:
            return SafeWireError(code: .unavailable, detail: nil)
        }
    }
}

private let registrySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class ClientIdentityAndKeyRegistry: @unchecked Sendable {
    public let store: SQLiteStore
    public let keyStore: ProtectedKeyStore

    public init(store: SQLiteStore, keyStore: ProtectedKeyStore) throws {
        self.store = store
        self.keyStore = keyStore
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS registered_clients (
                client_id TEXT PRIMARY KEY,
                signing_key_id TEXT NOT NULL,
                signing_public_key TEXT NOT NULL,
                noise_key_id TEXT NOT NULL,
                noise_public_key TEXT NOT NULL,
                trust_level TEXT NOT NULL,
                team_id TEXT NOT NULL,
                signing_identifier TEXT NOT NULL,
                allowed_workspaces_json TEXT NOT NULL,
                allowed_scopes_json TEXT NOT NULL,
                status TEXT NOT NULL,
                policy_version INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                revoked_at INTEGER
            );
            CREATE TABLE IF NOT EXISTS xpc_challenges (
                challenge_id TEXT PRIMARY KEY,
                client_id TEXT NOT NULL,
                key_id TEXT NOT NULL,
                connection_id TEXT NOT NULL,
                nonce TEXT NOT NULL,
                expires_at INTEGER NOT NULL,
                consumed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS client_sessions (
                session_id TEXT PRIMARY KEY,
                client_id TEXT NOT NULL,
                key_id TEXT NOT NULL,
                connection_id TEXT NOT NULL,
                trust_level TEXT NOT NULL,
                policy_version INTEGER NOT NULL,
                distribution_verified INTEGER NOT NULL,
                active INTEGER NOT NULL DEFAULT 1
            );
            """
        )
    }

    public func registerClient(_ record: RegisteredClientRecord) throws {
        let wsData = try JSONSerialization.data(withJSONObject: record.allowedWorkspaces)
        let scData = try JSONSerialization.data(withJSONObject: record.allowedScopes)
        let wsJSON = String(decoding: wsData, as: UTF8.self)
        let scJSON = String(decoding: scData, as: UTF8.self)

        try store.withConnectionLock { db in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT OR REPLACE INTO registered_clients (
                        client_id, signing_key_id, signing_public_key, noise_key_id, noise_public_key,
                        trust_level, team_id, signing_identifier, allowed_workspaces_json, allowed_scopes_json,
                        status, policy_version, created_at, expires_at, revoked_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: record.clientID)
                try store.bindText(stmt, index: 2, value: record.signingKeyID)
                try store.bindText(stmt, index: 3, value: record.signingPublicKeyBase64)
                try store.bindText(stmt, index: 4, value: record.noiseKeyID)
                try store.bindText(stmt, index: 5, value: record.noisePublicKeyBase64)
                try store.bindText(stmt, index: 6, value: record.trustLevel.rawValue)
                try store.bindText(stmt, index: 7, value: record.teamID)
                try store.bindText(stmt, index: 8, value: record.signingIdentifier)
                try store.bindText(stmt, index: 9, value: wsJSON)
                try store.bindText(stmt, index: 10, value: scJSON)
                try store.bindText(stmt, index: 11, value: record.status.rawValue)
                sqlite3_bind_int64(stmt, 12, Int64(bitPattern: record.policyVersion))
                sqlite3_bind_int64(stmt, 13, record.createdAt)
                sqlite3_bind_int64(stmt, 14, record.expiresAt)
                if let revokedAt = record.revokedAt {
                    sqlite3_bind_int64(stmt, 15, revokedAt)
                } else {
                    sqlite3_bind_null(stmt, 15)
                }
                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else { throw RegistryLifecycleError.storageFailure("insert client failed: \(rc)") }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchClient(clientID: String) throws -> RegisteredClientRecord {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                """
                SELECT client_id, signing_key_id, signing_public_key, noise_key_id, noise_public_key,
                       trust_level, team_id, signing_identifier, allowed_workspaces_json, allowed_scopes_json,
                       status, policy_version, created_at, expires_at, revoked_at
                FROM registered_clients WHERE client_id = ?
                """
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: clientID)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_ROW else { throw RegistryLifecycleError.clientNotFound }

            let wsStr = store.columnText(stmt, index: 8)
            let scStr = store.columnText(stmt, index: 9)
            let workspaces = (try? JSONSerialization.jsonObject(with: Data(wsStr.utf8)) as? [String]) ?? []
            let scopes = (try? JSONSerialization.jsonObject(with: Data(scStr.utf8)) as? [String]) ?? []
            let trust = ClientTrustLevel(rawValue: store.columnText(stmt, index: 5)) ?? .userEnrolledKey
            let status = ClientRegistrationStatus(rawValue: store.columnText(stmt, index: 10)) ?? .revoked
            let revokedAt = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 14)

            return RegisteredClientRecord(
                clientID: store.columnText(stmt, index: 0),
                signingKeyID: store.columnText(stmt, index: 1),
                signingPublicKeyBase64: store.columnText(stmt, index: 2),
                noiseKeyID: store.columnText(stmt, index: 3),
                noisePublicKeyBase64: store.columnText(stmt, index: 4),
                trustLevel: trust,
                teamID: store.columnText(stmt, index: 6),
                signingIdentifier: store.columnText(stmt, index: 7),
                allowedWorkspaces: workspaces,
                allowedScopes: scopes,
                status: status,
                policyVersion: UInt64(bitPattern: sqlite3_column_int64(stmt, 11)),
                createdAt: sqlite3_column_int64(stmt, 12),
                expiresAt: sqlite3_column_int64(stmt, 13),
                revokedAt: revokedAt
            )
        }
    }

    public func issueChallenge(
        clientID: String,
        keyID: String,
        connectionID: String,
        nowEpochSeconds: Int64,
        ttlSeconds: Int64 = 60
    ) throws -> (challengeID: String, nonce: String, expiresAt: Int64) {
        let client = try fetchClient(clientID: clientID)
        guard client.status == .active, client.signingKeyID == keyID, nowEpochSeconds < client.expiresAt else {
            throw RegistryLifecycleError.clientNotActive
        }
        let challengeID = UUID().uuidString.lowercased()
        let nonce = UUID().uuidString.lowercased()
        let expiresAt = nowEpochSeconds + ttlSeconds

        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    "INSERT INTO xpc_challenges (challenge_id, client_id, key_id, connection_id, nonce, expires_at, consumed) VALUES (?, ?, ?, ?, ?, ?, 0)"
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: challengeID)
                try store.bindText(stmt, index: 2, value: clientID)
                try store.bindText(stmt, index: 3, value: keyID)
                try store.bindText(stmt, index: 4, value: connectionID)
                try store.bindText(stmt, index: 5, value: nonce)
                sqlite3_bind_int64(stmt, 6, expiresAt)
                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else { throw RegistryLifecycleError.storageFailure("issue challenge failed: \(rc)") }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return (challengeID, nonce, expiresAt)
    }

    public func authenticateConnection(
        challengeID: String,
        clientID: String,
        keyID: String,
        connectionID: String,
        signature: Data,
        distributionSignedPeerVerified: Bool,
        nowEpochSeconds: Int64
    ) throws -> AuthenticatedConnectionSession {
        let client = try fetchClient(clientID: clientID)
        guard client.status == .active, nowEpochSeconds < client.expiresAt else {
            throw RegistryLifecycleError.clientNotActive
        }
        guard client.signingKeyID == keyID else {
            throw RegistryLifecycleError.signatureVerificationFailed
        }
        guard let pubData = Data(base64Encoded: client.signingPublicKeyBase64) else {
            throw RegistryLifecycleError.signatureVerificationFailed
        }

        let sessionID = UUID().uuidString.lowercased()
        try store.withConnectionLock { db in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let qStmt = try store.prepare(
                    "SELECT nonce, expires_at, consumed FROM xpc_challenges WHERE challenge_id = ? AND client_id = ? AND key_id = ? AND connection_id = ?"
                )
                defer { sqlite3_finalize(qStmt) }
                try store.bindText(qStmt, index: 1, value: challengeID)
                try store.bindText(qStmt, index: 2, value: clientID)
                try store.bindText(qStmt, index: 3, value: keyID)
                try store.bindText(qStmt, index: 4, value: connectionID)
                let rc = sqlite3_step(qStmt)
                guard rc == SQLITE_ROW else {
                    _ = try? store.execute("ROLLBACK")
                    throw RegistryLifecycleError.invalidChallenge
                }
                let nonce = store.columnText(qStmt, index: 0)
                let expiresAt = sqlite3_column_int64(qStmt, 1)
                let consumed = sqlite3_column_int(qStmt, 2)
                guard consumed == 0, nowEpochSeconds < expiresAt else {
                    _ = try? store.execute("ROLLBACK")
                    throw RegistryLifecycleError.challengeReplayOrExpired
                }

                let upd = try store.prepare("UPDATE xpc_challenges SET consumed = 1 WHERE challenge_id = ? AND consumed = 0")
                defer { sqlite3_finalize(upd) }
                try store.bindText(upd, index: 1, value: challengeID)
                let uRC = sqlite3_step(upd)
                guard uRC == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                    _ = try? store.execute("ROLLBACK")
                    throw RegistryLifecycleError.challengeReplayOrExpired
                }

                let transcript = Data("\(clientID)|\(keyID)|\(connectionID)|\(nonce)".utf8)
                guard keyStore.verify(publicKeyBytes: pubData, payload: transcript, signature: signature) else {
                    _ = try? store.execute("ROLLBACK")
                    throw RegistryLifecycleError.signatureVerificationFailed
                }

                let sessStmt = try store.prepare(
                    """
                    INSERT INTO client_sessions (session_id, client_id, key_id, connection_id, trust_level, policy_version, distribution_verified, active)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 1)
                    """
                )
                defer { sqlite3_finalize(sessStmt) }
                try store.bindText(sessStmt, index: 1, value: sessionID)
                try store.bindText(sessStmt, index: 2, value: clientID)
                try store.bindText(sessStmt, index: 3, value: keyID)
                try store.bindText(sessStmt, index: 4, value: connectionID)
                try store.bindText(sessStmt, index: 5, value: client.trustLevel.rawValue)
                sqlite3_bind_int64(sessStmt, 6, Int64(bitPattern: client.policyVersion))
                sqlite3_bind_int(sessStmt, 7, distributionSignedPeerVerified ? 1 : 0)
                let sRC = sqlite3_step(sessStmt)
                guard sRC == SQLITE_DONE else { throw RegistryLifecycleError.storageFailure("insert session failed") }

                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }

        return AuthenticatedConnectionSession(
            sessionID: sessionID,
            clientID: clientID,
            keyID: keyID,
            trustLevel: client.trustLevel,
            policyVersion: client.policyVersion,
            distributionSignedPeerVerified: distributionSignedPeerVerified,
            active: true
        )
    }

    public func isSessionActive(sessionID: String) throws -> Bool {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                """
                SELECT s.active, c.status, c.signing_key_id, s.key_id
                FROM client_sessions s
                JOIN registered_clients c ON c.client_id = s.client_id
                WHERE s.session_id = ?
                """
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: sessionID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            let active = sqlite3_column_int(stmt, 0) == 1
            let status = store.columnText(stmt, index: 1)
            let clientKeyID = store.columnText(stmt, index: 2)
            let sessionKeyID = store.columnText(stmt, index: 3)
            return active && status == ClientRegistrationStatus.active.rawValue && clientKeyID == sessionKeyID
        }
    }

    /// Key rotation revokes the previous key and all existing sessions first.
    /// If desktop confirmation or new-key PoP fails, both old and new keys remain inactive
    /// (zero simultaneous active keys, zero auto-rollback).
    public func rotateClientKey(
        clientID: String,
        newSigningKeyID: String,
        newSigningPublicKeyBase64: String,
        newNoiseKeyID: String,
        newNoisePublicKeyBase64: String,
        trustedDesktopConfirmed: Bool,
        newKeyProofSignature: Data?,
        rotationTranscript: Data,
        nowEpochSeconds: Int64
    ) throws -> RegisteredClientRecord {
        let current = try fetchClient(clientID: clientID)

        // Phase 1: Revoke previous key, increment policy version, and close all active sessions
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let revStmt = try store.prepare(
                    "UPDATE registered_clients SET status = ?, policy_version = policy_version + 1, revoked_at = ? WHERE client_id = ?"
                )
                defer { sqlite3_finalize(revStmt) }
                try store.bindText(revStmt, index: 1, value: ClientRegistrationStatus.revoked.rawValue)
                sqlite3_bind_int64(revStmt, 2, nowEpochSeconds)
                try store.bindText(revStmt, index: 3, value: clientID)
                guard sqlite3_step(revStmt) == SQLITE_DONE else {
                    throw RegistryLifecycleError.storageFailure("revoke old key failed")
                }

                let sessStmt = try store.prepare("UPDATE client_sessions SET active = 0 WHERE client_id = ?")
                defer { sqlite3_finalize(sessStmt) }
                try store.bindText(sessStmt, index: 1, value: clientID)
                guard sqlite3_step(sessStmt) == SQLITE_DONE else {
                    throw RegistryLifecycleError.storageFailure("close sessions failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        try? keyStore.revokeKey(keyID: current.signingKeyID)

        // Phase 2: Require trusted Desktop confirmation & valid new-key PoP; never auto-rollback
        guard trustedDesktopConfirmed else {
            throw RegistryLifecycleError.rotationInterruptedNoActiveKey
        }
        guard let sig = newKeyProofSignature,
              let pubBytes = Data(base64Encoded: newSigningPublicKeyBase64),
              keyStore.verify(publicKeyBytes: pubBytes, payload: rotationTranscript, signature: sig) else {
            throw RegistryLifecycleError.rotationInterruptedNoActiveKey
        }

        // Phase 3: Activate replacement key
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let actStmt = try store.prepare(
                    """
                    UPDATE registered_clients
                    SET signing_key_id = ?, signing_public_key = ?, noise_key_id = ?, noise_public_key = ?,
                        status = ?, policy_version = policy_version + 1, revoked_at = NULL
                    WHERE client_id = ?
                    """
                )
                defer { sqlite3_finalize(actStmt) }
                try store.bindText(actStmt, index: 1, value: newSigningKeyID)
                try store.bindText(actStmt, index: 2, value: newSigningPublicKeyBase64)
                try store.bindText(actStmt, index: 3, value: newNoiseKeyID)
                try store.bindText(actStmt, index: 4, value: newNoisePublicKeyBase64)
                try store.bindText(actStmt, index: 5, value: ClientRegistrationStatus.active.rawValue)
                try store.bindText(actStmt, index: 6, value: clientID)
                guard sqlite3_step(actStmt) == SQLITE_DONE else {
                    throw RegistryLifecycleError.storageFailure("activate new key failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }

        return try fetchClient(clientID: clientID)
    }

    public func revokeClient(clientID: String, nowEpochSeconds: Int64) throws -> RegisteredClientRecord {
        let current = try fetchClient(clientID: clientID)
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let upd = try store.prepare(
                    "UPDATE registered_clients SET status = ?, policy_version = policy_version + 1, revoked_at = ? WHERE client_id = ?"
                )
                defer { sqlite3_finalize(upd) }
                try store.bindText(upd, index: 1, value: ClientRegistrationStatus.revoked.rawValue)
                sqlite3_bind_int64(upd, 2, nowEpochSeconds)
                try store.bindText(upd, index: 3, value: clientID)
                guard sqlite3_step(upd) == SQLITE_DONE else {
                    throw RegistryLifecycleError.storageFailure("revoke client failed")
                }

                let sess = try store.prepare("UPDATE client_sessions SET active = 0 WHERE client_id = ?")
                defer { sqlite3_finalize(sess) }
                try store.bindText(sess, index: 1, value: clientID)
                guard sqlite3_step(sess) == SQLITE_DONE else {
                    throw RegistryLifecycleError.storageFailure("close sessions failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        try? keyStore.revokeKey(keyID: current.signingKeyID)
        return try fetchClient(clientID: clientID)
    }

    /// Blocks risky mutations/executions fail-closed unless both session identity and
    /// distribution-signed positive control have been verified (`ARC-11-G3-MACOS-DESIGN.md`).
    public func verifyRiskMutationGate(sessionID: String) throws {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                """
                SELECT s.active, s.distribution_verified, c.status, c.signing_key_id, s.key_id
                FROM client_sessions s
                JOIN registered_clients c ON c.client_id = s.client_id
                WHERE s.session_id = ?
                """
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: sessionID)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw RegistryLifecycleError.clientNotActive
            }
            let active = sqlite3_column_int(stmt, 0) == 1
            let distVerified = sqlite3_column_int(stmt, 1) == 1
            let status = store.columnText(stmt, index: 2)
            let currentKey = store.columnText(stmt, index: 3)
            let sessKey = store.columnText(stmt, index: 4)

            guard active, status == ClientRegistrationStatus.active.rawValue, currentKey == sessKey else {
                throw RegistryLifecycleError.clientNotActive
            }
            guard distVerified else {
                throw RegistryLifecycleError.distributionPositiveControlRequired
            }
        }
    }
}
