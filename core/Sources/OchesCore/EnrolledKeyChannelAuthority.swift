import CryptoKit
import Foundation
import SQLite3

public protocol SecureKeyVault: Sendable {
    func storeKeyMaterial(keyID: String, bytes: Data) throws
    func loadKeyMaterial(keyID: String) throws -> Data
    func deleteKeyMaterial(keyID: String) throws
}

public final class InMemorySecureKeyVault: SecureKeyVault, @unchecked Sendable {
    private let lock = NSLock()
    public var available: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _available }
        set { lock.lock(); defer { lock.unlock() }; _available = newValue }
    }
    private var _available: Bool
    private var entries: [String: Data] = [:]

    public init(available: Bool = true) {
        self._available = available
    }

    public func storeKeyMaterial(keyID: String, bytes: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard _available, !keyID.isEmpty else { throw NoiseChannelError.keyUnavailable }
        entries[keyID] = bytes
    }

    public func loadKeyMaterial(keyID: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard _available, let data = entries[keyID] else { throw NoiseChannelError.keyUnavailable }
        return data
    }

    public func deleteKeyMaterial(keyID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard _available else { throw NoiseChannelError.keyUnavailable }
        entries.removeValue(forKey: keyID)
    }
}

public struct EnrolledClientKeyRecord: Sendable, Equatable, Codable {
    public let clientID: String
    public let workspaceID: String
    public let clientRole: String
    public let trustLevel: ClientTrustLevel
    public let signingKeyID: String
    public let signingPublicKeyBase64: String
    public let noiseStaticKeyID: String
    public let noiseStaticPublicKeyBase64: String
    public let permissions: [PermissionScope]
    public let enrollmentGeneration: UInt64
    public let enrolledAt: Int64
    public let expiresAt: Int64
    public let revoked: Bool
}

public struct EnrollmentTranscript: Sendable, Equatable, Codable {
    public let coreID: String
    public let coreNoiseStaticPublicKeyBase64: String
    public let clientID: String
    public let clientRole: String
    public let workspaceID: String
    public let clientSigningKeyID: String
    public let clientSigningPublicKeyBase64: String
    public let clientNoiseStaticKeyID: String
    public let clientNoiseStaticPublicKeyBase64: String
    public let permissions: [PermissionScope]
    public let enrollmentGeneration: UInt64
    public let nonce: String

    public init(
        coreID: String,
        coreNoiseStaticPublicKeyBase64: String,
        clientID: String,
        clientRole: String,
        workspaceID: String,
        clientSigningKeyID: String,
        clientSigningPublicKeyBase64: String,
        clientNoiseStaticKeyID: String,
        clientNoiseStaticPublicKeyBase64: String,
        permissions: [PermissionScope],
        enrollmentGeneration: UInt64,
        nonce: String
    ) {
        self.coreID = coreID
        self.coreNoiseStaticPublicKeyBase64 = coreNoiseStaticPublicKeyBase64
        self.clientID = clientID
        self.clientRole = clientRole
        self.workspaceID = workspaceID
        self.clientSigningKeyID = clientSigningKeyID
        self.clientSigningPublicKeyBase64 = clientSigningPublicKeyBase64
        self.clientNoiseStaticKeyID = clientNoiseStaticKeyID
        self.clientNoiseStaticPublicKeyBase64 = clientNoiseStaticPublicKeyBase64
        self.permissions = permissions
        self.enrollmentGeneration = enrollmentGeneration
        self.nonce = nonce
    }

    public func computeDigest() throws -> Data {
        try canonicalSHA256(.object([
            ("domain", .string("oches.enrollment.v1")),
            ("coreID", .string(coreID)),
            ("coreNoiseStaticPublicKeyBase64", .string(coreNoiseStaticPublicKeyBase64)),
            ("clientID", .string(clientID)),
            ("clientRole", .string(clientRole)),
            ("workspaceID", .string(workspaceID)),
            ("clientSigningKeyID", .string(clientSigningKeyID)),
            ("clientSigningPublicKeyBase64", .string(clientSigningPublicKeyBase64)),
            ("clientNoiseStaticKeyID", .string(clientNoiseStaticKeyID)),
            ("clientNoiseStaticPublicKeyBase64", .string(clientNoiseStaticPublicKeyBase64)),
            ("permissions", .array(permissions.map { .string($0.rawValue) })),
            ("enrollmentGeneration", .number(String(enrollmentGeneration))),
            ("nonce", .string(nonce)),
        ]))
    }
}

public struct EnrollmentReceipt: Sendable, Equatable, Codable {
    public let record: EnrolledClientKeyRecord
    public let transcriptDigestHex: String
    public let coreNoiseStaticPublicKeyBase64: String
    public let coreSignatureBase64: String
}

public final class EnrolledKeyChannelAuthority: @unchecked Sendable {
    public static let registrationTTLSeconds: Int64 = 365 * 86_400
    public static let comparisonCodeTTLSeconds: Int64 = 600
    public static let maxComparisonAttempts: Int = 5
    public static let privilegedScopes: Set<PermissionScope> = [.workspaceWrite, .runRequest, .contextSubmit]

    public let store: SQLiteStore
    public let coreID: String
    public let coreSigningPrivateKey: Curve25519.Signing.PrivateKey
    public let coreNoiseStaticPrivateKey: Curve25519.KeyAgreement.PrivateKey

    public init(
        store: SQLiteStore,
        coreID: String,
        coreSigningPrivateKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
        coreNoiseStaticPrivateKey: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    ) throws {
        self.store = store
        self.coreID = coreID
        self.coreSigningPrivateKey = coreSigningPrivateKey
        self.coreNoiseStaticPrivateKey = coreNoiseStaticPrivateKey
        _ = try AuthorizationEnforcer(store: store)
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS enrolled_noise_clients (
                client_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                revoked INTEGER NOT NULL DEFAULT 0,
                expires_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS enrollment_code_attempts (
                challenge_id TEXT PRIMARY KEY,
                client_id TEXT NOT NULL,
                code_sha256 TEXT NOT NULL,
                failed_attempts INTEGER NOT NULL DEFAULT 0,
                expires_at INTEGER NOT NULL,
                consumed INTEGER NOT NULL DEFAULT 0
            );
            """
        )
    }

    public func startEnrollmentChallenge(
        challengeID: String,
        clientID: String,
        comparisonCode: String,
        nowEpochSeconds: Int64
    ) throws {
        guard !challengeID.isEmpty, !clientID.isEmpty, !comparisonCode.isEmpty, nowEpochSeconds >= 0 else {
            throw NoiseChannelError.denied("invalid enrollment challenge parameters")
        }
        let codeDigest = Data(SHA256.hash(data: Data(comparisonCode.utf8))).map { String(format: "%02x", $0) }.joined()
        let expiresAt = nowEpochSeconds + Self.comparisonCodeTTLSeconds

        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT INTO enrollment_code_attempts (
                        challenge_id, client_id, code_sha256, failed_attempts, expires_at, consumed
                    ) VALUES (?, ?, ?, 0, ?, 0)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: challengeID)
                try store.bindText(stmt, index: 2, value: clientID)
                try store.bindText(stmt, index: 3, value: codeDigest)
                sqlite3_bind_int64(stmt, 4, expiresAt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StorageError.versionConflict
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func completeEnrollment(
        challengeID: String,
        presentedComparisonCode: String,
        transcript: EnrollmentTranscript,
        clientProofSignatureBase64: String,
        desktopTrustedUIConfirmed: Bool,
        nowEpochSeconds: Int64
    ) throws -> EnrollmentReceipt {
        guard desktopTrustedUIConfirmed else {
            throw NoiseChannelError.denied("trusted Desktop UI confirmation required")
        }
        guard transcript.coreID == coreID,
              transcript.workspaceID.utf8.elementsEqual(store.workspaceID.utf8),
              transcript.coreNoiseStaticPublicKeyBase64 == coreNoiseStaticPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
              !transcript.permissions.isEmpty else {
            throw NoiseChannelError.denied("invalid enrollment transcript")
        }
        guard let signingPubBytes = Data(base64Encoded: transcript.clientSigningPublicKeyBase64),
              let noisePubBytes = Data(base64Encoded: transcript.clientNoiseStaticPublicKeyBase64),
              let sigBytes = Data(base64Encoded: clientProofSignatureBase64),
              signingPubBytes != noisePubBytes,
              let signingPubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPubBytes),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: noisePubBytes)) != nil else {
            throw NoiseChannelError.denied("invalid or non-separated client public keys")
        }

        let transcriptDigest = try transcript.computeDigest()
        let transcriptDigestHex = transcriptDigest.map { String(format: "%02x", $0) }.joined()
        var popPayload = transcriptDigest
        popPayload.append(Data(transcript.nonce.utf8))
        guard signingPubKey.isValidSignature(sigBytes, for: popPayload) else {
            throw NoiseChannelError.denied("client key proof-of-possession failed")
        }

        let presentedHash = Data(SHA256.hash(data: Data(presentedComparisonCode.utf8))).map { String(format: "%02x", $0) }.joined()

        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    "SELECT client_id, code_sha256, failed_attempts, expires_at, consumed FROM enrollment_code_attempts WHERE challenge_id = ?"
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: challengeID)
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    throw NoiseChannelError.denied("enrollment challenge not found")
                }
                let chalClientID = store.columnText(stmt, index: 0)
                let expectedHash = store.columnText(stmt, index: 1)
                let failedAttempts = Int(sqlite3_column_int(stmt, 2))
                let expiresAt = sqlite3_column_int64(stmt, 3)
                let consumed = sqlite3_column_int(stmt, 4)

                guard chalClientID == transcript.clientID,
                      consumed == 0,
                      nowEpochSeconds < expiresAt else {
                    throw NoiseChannelError.denied("enrollment challenge expired or mismatched")
                }
                guard failedAttempts < Self.maxComparisonAttempts else {
                    throw NoiseChannelError.comparisonAttemptsExceeded
                }

                if presentedHash != expectedHash {
                    let bump = try store.prepare(
                        "UPDATE enrollment_code_attempts SET failed_attempts = failed_attempts + 1 WHERE challenge_id = ?"
                    )
                    defer { sqlite3_finalize(bump) }
                    try store.bindText(bump, index: 1, value: challengeID)
                    _ = sqlite3_step(bump)
                    try store.execute("COMMIT")
                    if failedAttempts + 1 >= Self.maxComparisonAttempts {
                        throw NoiseChannelError.comparisonAttemptsExceeded
                    }
                    throw NoiseChannelError.denied("comparison code mismatch")
                }

                let consume = try store.prepare("UPDATE enrollment_code_attempts SET consumed = 1 WHERE challenge_id = ?")
                defer { sqlite3_finalize(consume) }
                try store.bindText(consume, index: 1, value: challengeID)
                guard sqlite3_step(consume) == SQLITE_DONE else {
                    throw StorageError.unavailable("consume challenge failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }

        let record = EnrolledClientKeyRecord(
            clientID: transcript.clientID,
            workspaceID: transcript.workspaceID,
            clientRole: transcript.clientRole,
            trustLevel: .userEnrolledKey,
            signingKeyID: transcript.clientSigningKeyID,
            signingPublicKeyBase64: transcript.clientSigningPublicKeyBase64,
            noiseStaticKeyID: transcript.clientNoiseStaticKeyID,
            noiseStaticPublicKeyBase64: transcript.clientNoiseStaticPublicKeyBase64,
            permissions: transcript.permissions,
            enrollmentGeneration: transcript.enrollmentGeneration,
            enrolledAt: nowEpochSeconds,
            expiresAt: nowEpochSeconds + Self.registrationTTLSeconds,
            revoked: false
        )
        try persistRecord(record)

        let receiptSig = try coreSigningPrivateKey.signature(for: transcriptDigest)
        return EnrollmentReceipt(
            record: record,
            transcriptDigestHex: transcriptDigestHex,
            coreNoiseStaticPublicKeyBase64: coreNoiseStaticPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            coreSignatureBase64: receiptSig.base64EncodedString()
        )
    }

    public func rotateEnrolledKeys(
        clientID: String,
        newSigningKeyID: String,
        newSigningPublicKeyBase64: String,
        newNoiseStaticKeyID: String,
        newNoiseStaticPublicKeyBase64: String,
        newKeyProofSignatureBase64: String,
        desktopTrustedUIConfirmed: Bool,
        nowEpochSeconds: Int64
    ) throws -> EnrolledClientKeyRecord {
        guard desktopTrustedUIConfirmed else {
            throw NoiseChannelError.denied("rotation requires Desktop UI confirmation")
        }
        let current = try fetchClient(clientID: clientID)
        guard !current.revoked else { throw NoiseChannelError.clientRevoked }

        guard let sigPubData = Data(base64Encoded: newSigningPublicKeyBase64),
              let noisePubData = Data(base64Encoded: newNoiseStaticPublicKeyBase64),
              let proofBytes = Data(base64Encoded: newKeyProofSignatureBase64),
              sigPubData != noisePubData,
              let sigPub = try? Curve25519.Signing.PublicKey(rawRepresentation: sigPubData),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: noisePubData)) != nil else {
            throw NoiseChannelError.denied("invalid rotated keys")
        }

        let nextGen = current.enrollmentGeneration + 1
        let rotDigest = try canonicalSHA256(.object([
            ("domain", .string("oches.enrollment.rotate.v1")),
            ("clientID", .string(clientID)),
            ("generation", .number(String(nextGen))),
            ("signingPublicKeyBase64", .string(newSigningPublicKeyBase64)),
            ("noiseStaticPublicKeyBase64", .string(newNoiseStaticPublicKeyBase64)),
        ]))
        guard sigPub.isValidSignature(proofBytes, for: rotDigest) else {
            throw NoiseChannelError.denied("rotated key proof invalid")
        }

        let updated = EnrolledClientKeyRecord(
            clientID: current.clientID,
            workspaceID: current.workspaceID,
            clientRole: current.clientRole,
            trustLevel: .userEnrolledKey,
            signingKeyID: newSigningKeyID,
            signingPublicKeyBase64: newSigningPublicKeyBase64,
            noiseStaticKeyID: newNoiseStaticKeyID,
            noiseStaticPublicKeyBase64: newNoiseStaticPublicKeyBase64,
            permissions: current.permissions,
            enrollmentGeneration: nextGen,
            enrolledAt: nowEpochSeconds,
            expiresAt: nowEpochSeconds + Self.registrationTTLSeconds,
            revoked: false
        )
        try persistRecord(updated)
        return updated
    }

    public func revokeClient(clientID: String) throws -> EnrolledClientKeyRecord {
        let current = try fetchClient(clientID: clientID)
        let revokedRecord = EnrolledClientKeyRecord(
            clientID: current.clientID,
            workspaceID: current.workspaceID,
            clientRole: current.clientRole,
            trustLevel: current.trustLevel,
            signingKeyID: current.signingKeyID,
            signingPublicKeyBase64: current.signingPublicKeyBase64,
            noiseStaticKeyID: current.noiseStaticKeyID,
            noiseStaticPublicKeyBase64: current.noiseStaticPublicKeyBase64,
            permissions: current.permissions,
            enrollmentGeneration: current.enrollmentGeneration,
            enrolledAt: current.enrolledAt,
            expiresAt: current.expiresAt,
            revoked: true
        )
        try persistRecord(revokedRecord)
        return revokedRecord
    }

    public func fetchClient(clientID: String) throws -> EnrolledClientKeyRecord {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare("SELECT payload_json FROM enrolled_noise_clients WHERE client_id = ?")
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: clientID)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw NoiseChannelError.denied("client not enrolled")
            }
            return try JSONDecoder().decode(EnrolledClientKeyRecord.self, from: Data(store.columnText(stmt, index: 0).utf8))
        }
    }

    public func acceptNoiseHandshake(
        clientID: String,
        protocolMajor: Int,
        message1: Data,
        nowEpochSeconds: Int64
    ) throws -> (message2: Data, session: NoiseTransportSession) {
        let record = try fetchClient(clientID: clientID)
        guard !record.revoked else { throw NoiseChannelError.clientRevoked }
        guard nowEpochSeconds < record.expiresAt else { throw NoiseChannelError.denied("enrollment expired") }

        let prologueHash = try NoisePrologueInput(
            protocolMajor: protocolMajor,
            coreID: coreID,
            clientID: record.clientID,
            enrollmentGeneration: record.enrollmentGeneration,
            clientRole: record.clientRole
        ).computePrologueHash()

        let responder = try NoiseIKHandshakeResponder(
            localStatic: coreNoiseStaticPrivateKey,
            prologueHash: prologueHash
        )
        _ = try responder.readMessage1(message1) { rsBytes in
            guard rsBytes.base64EncodedString() == record.noiseStaticPublicKeyBase64 else {
                throw NoiseChannelError.staticKeyMismatch
            }
        }
        let out = try responder.writeMessage2()
        return (out.message, out.session)
    }

    public func authorizeDecryptedCommand(
        clientID: String,
        session: NoiseTransportSession,
        commandScope: PermissionScope,
        workspaceID: String,
        commandPayload: RawJSONValue,
        nonceID: String,
        desktopApprovalID: String?,
        nowEpochSeconds: Int64
    ) throws -> Data {
        guard !session.isClosed else { throw NoiseChannelError.channelClosed }
        let record = try fetchClient(clientID: clientID)
        guard !record.revoked else { throw NoiseChannelError.clientRevoked }
        guard nowEpochSeconds < record.expiresAt else { throw NoiseChannelError.denied("enrollment expired") }
        guard record.workspaceID.utf8.elementsEqual(workspaceID.utf8),
              workspaceID.utf8.elementsEqual(store.workspaceID.utf8),
              record.permissions.contains(commandScope) else {
            throw NoiseChannelError.denied("workspace or scope not permitted")
        }

        let commandDigest = try canonicalSHA256(.object([
            ("domain", .string("oches.noise.command.v1")),
            ("clientID", .string(clientID)),
            ("workspaceID", .string(workspaceID)),
            ("scope", .string(commandScope.rawValue)),
            ("command", commandPayload),
        ]))
        let commandDigestHex = commandDigest.map { String(format: "%02x", $0) }.joined()

        try store.withConnectionLock { db in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let nStmt = try store.prepare(
                    "SELECT client_id, workspace_id, expires_at, consumed FROM auth_nonces WHERE nonce_id = ?"
                )
                defer { sqlite3_finalize(nStmt) }
                try store.bindText(nStmt, index: 1, value: nonceID)
                guard sqlite3_step(nStmt) == SQLITE_ROW else {
                    throw NoiseChannelError.denied("missing nonce")
                }
                let nClient = store.columnText(nStmt, index: 0)
                let nWs = store.columnText(nStmt, index: 1)
                let nExp = sqlite3_column_int64(nStmt, 2)
                let nConsumed = sqlite3_column_int(nStmt, 3)
                guard nClient == clientID,
                      nWs == workspaceID,
                      nConsumed == 0,
                      nowEpochSeconds < nExp else {
                    throw NoiseChannelError.denied("invalid or replayed nonce")
                }
                let updNonce = try store.prepare("UPDATE auth_nonces SET consumed = 1 WHERE nonce_id = ? AND consumed = 0")
                defer { sqlite3_finalize(updNonce) }
                try store.bindText(updNonce, index: 1, value: nonceID)
                guard sqlite3_step(updNonce) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                    throw NoiseChannelError.denied("nonce replay rejected")
                }

                if Self.privilegedScopes.contains(commandScope) {
                    guard let approvalID = desktopApprovalID, !approvalID.isEmpty else {
                        throw NoiseChannelError.approvalRequired([.execution])
                    }
                    let aStmt = try store.prepare(
                        "SELECT subject_client_id, workspace_id, normalized_target, issued_at, expires_at, status, consumed FROM approvals WHERE approval_id = ?"
                    )
                    defer { sqlite3_finalize(aStmt) }
                    try store.bindText(aStmt, index: 1, value: approvalID)
                    guard sqlite3_step(aStmt) == SQLITE_ROW else {
                        throw NoiseChannelError.approvalRequired([.execution])
                    }
                    let subject = store.columnText(aStmt, index: 0)
                    let aWs = store.columnText(aStmt, index: 1)
                    let target = store.columnText(aStmt, index: 2)
                    let issued = sqlite3_column_int64(aStmt, 3)
                    let exp = sqlite3_column_int64(aStmt, 4)
                    let status = store.columnText(aStmt, index: 5)
                    let consumed = sqlite3_column_int(aStmt, 6)

                    guard subject == clientID,
                          aWs == workspaceID,
                          target == commandDigestHex,
                          status == ApprovalStatus.approved.rawValue,
                          consumed == 0,
                          issued < exp,
                          nowEpochSeconds >= issued,
                          nowEpochSeconds < exp else {
                        throw NoiseChannelError.denied("Desktop approval mismatch or expired")
                    }

                    let updApp = try store.prepare("UPDATE approvals SET consumed = 1 WHERE approval_id = ? AND consumed = 0")
                    defer { sqlite3_finalize(updApp) }
                    try store.bindText(updApp, index: 1, value: approvalID)
                    guard sqlite3_step(updApp) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                        throw NoiseChannelError.denied("Desktop approval replay rejected")
                    }
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return commandDigest
    }

    private func persistRecord(_ record: EnrolledClientKeyRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadJSON = String(decoding: try encoder.encode(record), as: UTF8.self)
        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT OR REPLACE INTO enrolled_noise_clients (
                        client_id, workspace_id, payload_json, revoked, expires_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: record.clientID)
                try store.bindText(stmt, index: 2, value: record.workspaceID)
                try store.bindText(stmt, index: 3, value: payloadJSON)
                sqlite3_bind_int(stmt, 4, record.revoked ? 1 : 0)
                sqlite3_bind_int64(stmt, 5, record.expiresAt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StorageError.unavailable("persist enrolled client failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }
}
