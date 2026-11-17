import CryptoKit
import Foundation
import SQLite3

public struct FreshnessAnchorState: Sendable, Equatable, Codable {
    public let workspaceID: String
    public let epoch: UInt64
    public let sequence: UInt64
    public let headDigest: String
    public let storeGeneration: String

    public init(workspaceID: String, epoch: UInt64, sequence: UInt64, headDigest: String, storeGeneration: String) {
        self.workspaceID = workspaceID
        self.epoch = epoch
        self.sequence = sequence
        self.headDigest = headDigest
        self.storeGeneration = storeGeneration
    }
}

public struct FreshnessAnchorTransition: Sendable, Equatable {
    public let workspaceID: String
    public let epoch: UInt64
    public let sequence: UInt64
    public let previousHeadDigest: String
    public let headDigest: String
    public let storeGeneration: String

    public init(
        workspaceID: String,
        epoch: UInt64,
        sequence: UInt64,
        previousHeadDigest: String,
        headDigest: String,
        storeGeneration: String
    ) {
        self.workspaceID = workspaceID
        self.epoch = epoch
        self.sequence = sequence
        self.previousHeadDigest = previousHeadDigest
        self.headDigest = headDigest
        self.storeGeneration = storeGeneration
    }
}

public protocol FreshnessAnchorStore: Sendable {
    func read() throws -> FreshnessAnchorState
    func advance(expected: FreshnessAnchorState, next: FreshnessAnchorTransition) throws -> FreshnessAnchorState
    func resetEpochWithTrustedUI(
        expected: FreshnessAnchorState,
        newEpoch: UInt64,
        newHeadDigest: String,
        newStoreGeneration: String
    ) throws -> FreshnessAnchorState
}

/// Tier 1 local sealed anchor model separated from the SQLite database file (`RECOVERY_FRESHNESS_ANCHOR.md`).
public final class LocalSealedFreshnessAnchor: FreshnessAnchorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: FreshnessAnchorState
    public var available: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _available }
        set { lock.lock(); defer { lock.unlock() }; _available = newValue }
    }
    private var _available: Bool

    public init(workspaceID: String, epoch: UInt64 = 1, storeGeneration: String, available: Bool = true) {
        self._available = available
        self.state = FreshnessAnchorState(
            workspaceID: workspaceID,
            epoch: epoch,
            sequence: 0,
            headDigest: "GENESIS",
            storeGeneration: storeGeneration
        )
    }

    public func read() throws -> FreshnessAnchorState {
        lock.lock()
        defer { lock.unlock() }
        guard _available else { throw StorageError.unavailable("FRESHNESS_ANCHOR_UNAVAILABLE") }
        return state
    }

    public func advance(expected: FreshnessAnchorState, next: FreshnessAnchorTransition) throws -> FreshnessAnchorState {
        lock.lock()
        defer { lock.unlock() }
        guard _available else { throw StorageError.unavailable("FRESHNESS_ANCHOR_UNAVAILABLE") }
        guard state == expected else {
            throw StorageError.versionConflict
        }
        guard next.workspaceID == state.workspaceID,
              next.epoch == state.epoch,
              next.sequence == state.sequence + 1,
              next.previousHeadDigest == state.headDigest,
              !next.headDigest.isEmpty,
              !next.storeGeneration.isEmpty else {
            throw StorageError.versionConflict
        }
        state = FreshnessAnchorState(
            workspaceID: state.workspaceID,
            epoch: state.epoch,
            sequence: next.sequence,
            headDigest: next.headDigest,
            storeGeneration: next.storeGeneration
        )
        return state
    }

    public func resetEpochWithTrustedUI(
        expected: FreshnessAnchorState,
        newEpoch: UInt64,
        newHeadDigest: String,
        newStoreGeneration: String
    ) throws -> FreshnessAnchorState {
        lock.lock()
        defer { lock.unlock() }
        guard _available else { throw StorageError.unavailable("FRESHNESS_ANCHOR_UNAVAILABLE") }
        guard state == expected, newEpoch == state.epoch + 1 else {
            throw StorageError.versionConflict
        }
        state = FreshnessAnchorState(
            workspaceID: state.workspaceID,
            epoch: newEpoch,
            sequence: state.sequence,
            headDigest: newHeadDigest,
            storeGeneration: newStoreGeneration
        )
        return state
    }
}

public enum DurableIntentAction: String, Sendable, Equatable, Codable {
    case deleteState = "DELETE_STATE"
    case deleteArtifact = "DELETE_ARTIFACT"
    case revokeClient = "REVOKE_CLIENT"
    case restoreBackup = "RESTORE_BACKUP"
}

public struct DurableIntent: Sendable, Equatable, Codable {
    public let intentID: String
    public let workspaceID: String
    public let epoch: UInt64
    public let sequence: UInt64
    public let previousHeadDigest: String
    public let action: DurableIntentAction
    public let targetID: String
    public let targetDigest: String
    public let approvalID: String
    public let policyVersion: UInt64
    public let storeGeneration: String
    public let issuedAt: Int64

    public init(
        intentID: String,
        workspaceID: String,
        epoch: UInt64,
        sequence: UInt64,
        previousHeadDigest: String,
        action: DurableIntentAction,
        targetID: String,
        targetDigest: String,
        approvalID: String,
        policyVersion: UInt64,
        storeGeneration: String,
        issuedAt: Int64
    ) {
        self.intentID = intentID
        self.workspaceID = workspaceID
        self.epoch = epoch
        self.sequence = sequence
        self.previousHeadDigest = previousHeadDigest
        self.action = action
        self.targetID = targetID
        self.targetDigest = targetDigest
        self.approvalID = approvalID
        self.policyVersion = policyVersion
        self.storeGeneration = storeGeneration
        self.issuedAt = issuedAt
    }

    public func canonicalBytes() throws -> Data {
        let jsonValue: RawJSONValue = .object([
            ("intentId", .string(intentID)),
            ("workspaceId", .string(workspaceID)),
            ("epoch", .number(String(epoch))),
            ("sequence", .number(String(sequence))),
            ("previousHeadDigest", .string(previousHeadDigest)),
            ("action", .string(action.rawValue)),
            ("targetId", .string(targetID)),
            ("targetDigest", .string(targetDigest)),
            ("approvalId", .string(approvalID)),
            ("policyVersion", .number(String(policyVersion))),
            ("storeGeneration", .string(storeGeneration)),
            ("issuedAt", .number(String(issuedAt))),
        ])
        return try canonicalizeJSON(jsonValue)
    }

    public func computeHeadDigest() throws -> String {
        let bytes = try canonicalBytes()
        return Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SignedLedgerEntry: Sendable, Equatable, Codable {
    public let intent: DurableIntent
    public let headDigest: String
    public let keyID: String
    public let signatureBase64: String

    public init(intent: DurableIntent, headDigest: String, keyID: String, signatureBase64: String) {
        self.intent = intent
        self.headDigest = headDigest
        self.keyID = keyID
        self.signatureBase64 = signatureBase64
    }
}

public enum WorkspaceRecoveryPosture: Sendable, Equatable {
    case active
    case recoveredActive
    case quarantined(reason: String)
}

/// Append-only RecoveryLedger stored outside the SQLite database directory.
public final class RecoveryLedger: @unchecked Sendable {
    public let ledgerFileURL: URL
    private let lock = NSLock()

    public init(ledgerDirectoryURL: URL, workspaceID: String) throws {
        try FileManager.default.createDirectory(at: ledgerDirectoryURL, withIntermediateDirectories: true)
        self.ledgerFileURL = ledgerDirectoryURL.appendingPathComponent("recovery-ledger-\(workspaceID).jsonl")
    }

    public func append(_ entry: SignedLedgerEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        let lineData = try JSONEncoder().encode(entry)
        var out = lineData
        out.append(0x0a)
        if !FileManager.default.fileExists(atPath: ledgerFileURL.path) {
            try out.write(to: ledgerFileURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: ledgerFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: out)
            try handle.synchronize()
        }
    }

    public func readAll() throws -> [SignedLedgerEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: ledgerFileURL.path) else {
            return []
        }
        let raw = try Data(contentsOf: ledgerFileURL)
        let lines = String(decoding: raw, as: UTF8.self).split(separator: "\n")
        return try lines.map { line in
            try JSONDecoder().decode(SignedLedgerEntry.self, from: Data(line.utf8))
        }
    }

    public func replaceEntriesForTesting(_ entries: [SignedLedgerEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        var combined = Data()
        for entry in entries {
            combined.append(try JSONEncoder().encode(entry))
            combined.append(0x0a)
        }
        try combined.write(to: ledgerFileURL, options: .atomic)
    }

    public func lastHead() throws -> (sequence: UInt64, headDigest: String) {
        let entries = try readAll()
        guard let last = entries.last else { return (0, "GENESIS") }
        return (last.intent.sequence, last.headDigest)
    }
}

public final class RecoveryCoordinator: @unchecked Sendable {
    public let store: SQLiteStore
    public let anchor: FreshnessAnchorStore
    public let ledger: RecoveryLedger
    public let keyStore: ProtectedKeyStore
    public private(set) var posture: WorkspaceRecoveryPosture = .active

    private var trustedUIApprovals: [String: (action: DurableIntentAction, targetDigest: String)] = [:]
    private var intentSigningPublicKeys: [String: (publicKeyBytes: Data, active: Bool)] = [:]
    private let lock = NSLock()

    public init(
        store: SQLiteStore,
        anchor: FreshnessAnchorStore,
        ledger: RecoveryLedger,
        keyStore: ProtectedKeyStore
    ) throws {
        self.store = store
        self.anchor = anchor
        self.ledger = ledger
        self.keyStore = keyStore
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS intent_approvals (
                approval_id TEXT PRIMARY KEY,
                action TEXT NOT NULL,
                target_digest TEXT NOT NULL,
                consumed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS durable_intents (
                intent_id TEXT PRIMARY KEY,
                epoch INTEGER NOT NULL,
                sequence INTEGER NOT NULL,
                previous_head_digest TEXT NOT NULL,
                head_digest TEXT NOT NULL,
                action TEXT NOT NULL,
                target_id TEXT NOT NULL,
                target_digest TEXT NOT NULL,
                approval_id TEXT NOT NULL,
                status TEXT NOT NULL
            );
            """
        )
    }

    public func registerIntentSigningKey(keyID: String, publicKeyBytes: Data, active: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        intentSigningPublicKeys[keyID] = (publicKeyBytes, active)
    }

    public func revokeIntentSigningKey(keyID: String) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = intentSigningPublicKeys[keyID] {
            intentSigningPublicKeys[keyID] = (existing.publicKeyBytes, false)
        }
    }

    public func issueTrustedUIApproval(
        approvalID: String,
        action: DurableIntentAction,
        targetDigest: String
    ) throws {
        lock.lock()
        trustedUIApprovals[approvalID] = (action, targetDigest)
        lock.unlock()

        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    "INSERT OR REPLACE INTO intent_approvals (approval_id, action, target_digest, consumed) VALUES (?, ?, ?, 0)"
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: approvalID)
                try store.bindText(stmt, index: 2, value: action.rawValue)
                try store.bindText(stmt, index: 3, value: targetDigest)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StorageError.unavailable("failed to store intent approval")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func commitIntentInDB(
        intentID: String,
        approvalID: String,
        action: DurableIntentAction,
        targetID: String,
        targetDigest: String,
        epoch: UInt64 = 1,
        policyVersion: UInt64 = 1,
        nowEpochSeconds: Int64
    ) throws -> (intent: DurableIntent, headDigest: String) {
        if case .quarantined = posture {
            throw StorageError.denied
        }
        let (prevSeq, prevHead) = try ledger.lastHead()
        let intent = DurableIntent(
            intentID: intentID,
            workspaceID: store.workspaceID,
            epoch: epoch,
            sequence: prevSeq + 1,
            previousHeadDigest: prevHead,
            action: action,
            targetID: targetID,
            targetDigest: targetDigest,
            approvalID: approvalID,
            policyVersion: policyVersion,
            storeGeneration: store.storeGeneration,
            issuedAt: nowEpochSeconds
        )
        let headDigest = try intent.computeHeadDigest()

        try store.withConnectionLock { db in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let appStmt = try store.prepare(
                    "UPDATE intent_approvals SET consumed = 1 WHERE approval_id = ? AND action = ? AND target_digest = ? AND consumed = 0"
                )
                defer { sqlite3_finalize(appStmt) }
                try store.bindText(appStmt, index: 1, value: approvalID)
                try store.bindText(appStmt, index: 2, value: action.rawValue)
                try store.bindText(appStmt, index: 3, value: targetDigest)
                guard sqlite3_step(appStmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                    throw AuthorizationError.approvalRequired([.execution])
                }

                let insStmt = try store.prepare(
                    """
                    INSERT INTO durable_intents (
                        intent_id, epoch, sequence, previous_head_digest, head_digest,
                        action, target_id, target_digest, approval_id, status
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'INTENT_COMMITTED')
                    """
                )
                defer { sqlite3_finalize(insStmt) }
                try store.bindText(insStmt, index: 1, value: intent.intentID)
                sqlite3_bind_int64(insStmt, 2, Int64(bitPattern: intent.epoch))
                sqlite3_bind_int64(insStmt, 3, Int64(bitPattern: intent.sequence))
                try store.bindText(insStmt, index: 4, value: intent.previousHeadDigest)
                try store.bindText(insStmt, index: 5, value: headDigest)
                try store.bindText(insStmt, index: 6, value: intent.action.rawValue)
                try store.bindText(insStmt, index: 7, value: intent.targetID)
                try store.bindText(insStmt, index: 8, value: intent.targetDigest)
                try store.bindText(insStmt, index: 9, value: intent.approvalID)
                guard sqlite3_step(insStmt) == SQLITE_DONE else {
                    throw StorageError.unavailable("failed to commit durable intent")
                }

                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return (intent, headDigest)
    }

    public func signAndAppendLedger(
        intent: DurableIntent,
        headDigest: String,
        keyID: String
    ) throws -> SignedLedgerEntry {
        let bytes = try intent.canonicalBytes()
        let sig = try keyStore.sign(keyID: keyID, payload: bytes)
        let entry = SignedLedgerEntry(
            intent: intent,
            headDigest: headDigest,
            keyID: keyID,
            signatureBase64: sig.base64EncodedString()
        )
        try ledger.append(entry)
        return entry
    }

    public func advanceAnchorAndComplete(_ entry: SignedLedgerEntry) throws -> FreshnessAnchorState {
        let current = try anchor.read()
        let next = FreshnessAnchorTransition(
            workspaceID: entry.intent.workspaceID,
            epoch: entry.intent.epoch,
            sequence: entry.intent.sequence,
            previousHeadDigest: entry.intent.previousHeadDigest,
            headDigest: entry.headDigest,
            storeGeneration: entry.intent.storeGeneration
        )
        let updated = try anchor.advance(expected: current, next: next)
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare("UPDATE durable_intents SET status = 'COMPLETE' WHERE intent_id = ?")
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: entry.intent.intentID)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw StorageError.unavailable("complete intent failed") }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return updated
    }

    public func quarantine(_ reason: String) -> WorkspaceRecoveryPosture {
        posture = .quarantined(reason: reason)
        return posture
    }

    public func ensureActiveForOperation() throws {
        switch posture {
        case .active, .recoveredActive:
            return
        case .quarantined(let reason):
            throw StorageError.unavailable("RECOVERY_QUARANTINED: \(reason)")
        }
    }

    public func reconcileOnRestart() -> WorkspaceRecoveryPosture {
        let anchorState: FreshnessAnchorState
        do {
            anchorState = try anchor.read()
        } catch {
            return quarantine("anchor missing or unavailable")
        }

        let entries: [SignedLedgerEntry]
        do {
            entries = try ledger.readAll()
        } catch {
            return quarantine("recovery ledger unreadable")
        }

        // Check for unsigned INTENT_COMMITTED DB rows missing from ledger -> never auto-sign; quarantine immediately
        do {
            let committedRows = try store.withConnectionLock { _ -> [(intentID: String, action: String, targetDigest: String, approvalID: String)] in
                let stmt = try store.prepare(
                    "SELECT intent_id, action, target_digest, approval_id FROM durable_intents WHERE status = 'INTENT_COMMITTED' ORDER BY sequence ASC"
                )
                defer { sqlite3_finalize(stmt) }
                var rows: [(String, String, String, String)] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rows.append((
                        store.columnText(stmt, index: 0),
                        store.columnText(stmt, index: 1),
                        store.columnText(stmt, index: 2),
                        store.columnText(stmt, index: 3)
                    ))
                }
                return rows
            }

            let ledgerIntentIDs = Set(entries.map { $0.intent.intentID })
            for row in committedRows where !ledgerIntentIDs.contains(row.intentID) {
                return quarantine("unsigned INTENT_COMMITTED DB row \(row.intentID) lacks RecoveryLedger entry")
            }
        } catch {
            return quarantine("failed reading durable_intents")
        }

        // Verify hash chain and signatures sequentially from GENESIS
        var expectedPrev = "GENESIS"
        for (idx, entry) in entries.enumerated() {
            let expectedSeq = UInt64(idx + 1)
            guard entry.intent.sequence == expectedSeq,
                  entry.intent.previousHeadDigest == expectedPrev else {
                return quarantine("ledger chain sequence or previousHeadDigest mismatch at \(expectedSeq)")
            }
            guard let computedDigest = try? entry.intent.computeHeadDigest(),
                  computedDigest == entry.headDigest else {
                return quarantine("ledger headDigest tamper detected at \(expectedSeq)")
            }
            lock.lock()
            let keyInfo = intentSigningPublicKeys[entry.keyID]
            lock.unlock()
            guard let keyInfo, keyInfo.active,
                  let sigData = Data(base64Encoded: entry.signatureBase64),
                  let canonicalBytes = try? entry.intent.canonicalBytes(),
                  keyStore.verify(publicKeyBytes: keyInfo.publicKeyBytes, payload: canonicalBytes, signature: sigData) else {
                return quarantine("invalid or revoked intentSigningKey at \(expectedSeq)")
            }
            expectedPrev = entry.headDigest
        }

        let ledgerSeq = entries.last?.intent.sequence ?? 0
        let ledgerHead = entries.last?.headDigest ?? "GENESIS"

        if anchorState.sequence > ledgerSeq {
            return quarantine("rollback detected: anchor sequence \(anchorState.sequence) > ledger sequence \(ledgerSeq)")
        }

        if anchorState.sequence == ledgerSeq {
            if anchorState.headDigest != ledgerHead {
                return quarantine("fork detected at sequence \(ledgerSeq)")
            }
            posture = .active
            return posture
        }

        // ledgerSeq > anchorState.sequence
        guard ledgerSeq - anchorState.sequence == 1, let pending = entries.last else {
            return quarantine("ledger gap > 1 (\(ledgerSeq) vs \(anchorState.sequence))")
        }

        guard pending.intent.previousHeadDigest == anchorState.headDigest else {
            return quarantine("pending intent previousHeadDigest does not match anchor head")
        }

        lock.lock()
        let approved = trustedUIApprovals[pending.intent.approvalID]
        lock.unlock()
        guard let approved,
              approved.action == pending.intent.action,
              approved.targetDigest == pending.intent.targetDigest else {
            return quarantine("missing or mismatched trusted UI approval chain for single-step retry")
        }

        do {
            _ = try advanceAnchorAndComplete(pending)
            posture = .recoveredActive
            return posture
        } catch {
            return quarantine("single-step anchor advance retry failed")
        }
    }

    public func releaseQuarantineWithTrustedUI(
        trustedDesktopConfirmed: Bool,
        newStoreGeneration: String
    ) throws -> FreshnessAnchorState {
        guard trustedDesktopConfirmed else {
            throw AuthorizationError.denied("trusted Desktop UI confirmation required to release quarantine")
        }
        let current = try anchor.read()
        let entries = try ledger.readAll()
        let headDigest = entries.last?.headDigest ?? "GENESIS"
        let next = try anchor.resetEpochWithTrustedUI(
            expected: current,
            newEpoch: current.epoch + 1,
            newHeadDigest: headDigest,
            newStoreGeneration: newStoreGeneration
        )
        posture = .active
        return next
    }
}
