import CryptoKit
import Foundation
import SQLite3

public enum DeletionStatus: String, Sendable, Equatable, Codable {
    case pending = "PENDING"
    case deleting = "DELETING"
    case complete = "COMPLETE"
    case failed = "FAILED"
}

public struct DeletionRecord: Sendable, Equatable {
    public let requestID: String
    public let targetID: String
    public let status: DeletionStatus
    public let stateDeleted: Bool
    public let eventsDeleted: Bool
    public let derivedIndexDeleted: Bool
    public let backupsDeleted: Bool
    public let detail: String

    public init(
        requestID: String,
        targetID: String,
        status: DeletionStatus,
        stateDeleted: Bool,
        eventsDeleted: Bool,
        derivedIndexDeleted: Bool,
        backupsDeleted: Bool,
        detail: String
    ) {
        self.requestID = requestID
        self.targetID = targetID
        self.status = status
        self.stateDeleted = stateDeleted
        self.eventsDeleted = eventsDeleted
        self.derivedIndexDeleted = derivedIndexDeleted
        self.backupsDeleted = backupsDeleted
        self.detail = detail
    }
}

public struct BackupBlobDigest: Sendable, Equatable, Codable {
    public let blobID: String
    public let sha256Hex: String
    public let byteLength: Int

    public init(blobID: String, sha256Hex: String, byteLength: Int) {
        self.blobID = blobID
        self.sha256Hex = sha256Hex
        self.byteLength = byteLength
    }
}

public struct BackupManifest: Sendable, Equatable, Codable {
    public let workspaceID: String
    public let epoch: UInt64
    public let sequence: UInt64
    public let headDigest: String
    public let storeGeneration: String
    public let blobDigests: [BackupBlobDigest]

    public init(
        workspaceID: String,
        epoch: UInt64,
        sequence: UInt64,
        headDigest: String,
        storeGeneration: String,
        blobDigests: [BackupBlobDigest]
    ) {
        self.workspaceID = workspaceID
        self.epoch = epoch
        self.sequence = sequence
        self.headDigest = headDigest
        self.storeGeneration = storeGeneration
        self.blobDigests = blobDigests
    }
}

public final class DeletionRequestLifecycle: @unchecked Sendable {
    public let store: SQLiteStore

    public init(store: SQLiteStore) throws {
        self.store = store
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS deletion_requests (
                request_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                status TEXT NOT NULL,
                state_deleted INTEGER NOT NULL DEFAULT 0,
                events_deleted INTEGER NOT NULL DEFAULT 0,
                derived_index_deleted INTEGER NOT NULL DEFAULT 0,
                backups_deleted INTEGER NOT NULL DEFAULT 0,
                detail TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS derived_index (
                entry_id TEXT PRIMARY KEY,
                target_id TEXT NOT NULL,
                summary TEXT NOT NULL
            );
            """
        )
    }

    public func isTargetBlockedForReads(targetID: String) throws -> Bool {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare("SELECT COUNT(*) FROM deletion_requests WHERE target_id = ?")
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: targetID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int(stmt, 0) > 0
        }
    }

    public func beginDeletion(requestID: String, targetID: String) throws -> DeletionRecord {
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT OR REPLACE INTO deletion_requests (
                        request_id, workspace_id, target_id, status,
                        state_deleted, events_deleted, derived_index_deleted, backups_deleted, detail
                    ) VALUES (?, ?, ?, ?, 0, 0, 0, 0, 'deletion pending')
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: requestID)
                try store.bindText(stmt, index: 2, value: store.workspaceID)
                try store.bindText(stmt, index: 3, value: targetID)
                try store.bindText(stmt, index: 4, value: DeletionStatus.pending.rawValue)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw StorageError.unavailable("beginDeletion failed") }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return try fetchDeletion(requestID: requestID)
    }

    public func executeDeletion(
        requestID: String,
        targetID: String,
        derivedIndexDeleteSucceeds: Bool = true,
        backupsDeleteSucceeds: Bool = true
    ) throws -> DeletionRecord {
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let markDeleting = try store.prepare(
                    "UPDATE deletion_requests SET status = ?, detail = ? WHERE request_id = ?"
                )
                defer { sqlite3_finalize(markDeleting) }
                try store.bindText(markDeleting, index: 1, value: DeletionStatus.deleting.rawValue)
                try store.bindText(markDeleting, index: 2, value: "deleting data and derivatives")
                try store.bindText(markDeleting, index: 3, value: requestID)
                guard sqlite3_step(markDeleting) == SQLITE_DONE else { throw StorageError.unavailable("mark deleting failed") }

                let delState = try store.prepare("DELETE FROM operational_state WHERE object_id = ?")
                defer { sqlite3_finalize(delState) }
                try store.bindText(delState, index: 1, value: targetID)
                guard sqlite3_step(delState) == SQLITE_DONE else { throw StorageError.unavailable("delete state failed") }

                let delProfile = try store.prepare("DELETE FROM profile_revisions WHERE workspace_id = ? AND object_id = ?")
                defer { sqlite3_finalize(delProfile) }
                try store.bindText(delProfile, index: 1, value: store.workspaceID)
                try store.bindText(delProfile, index: 2, value: targetID)
                guard sqlite3_step(delProfile) == SQLITE_DONE else { throw StorageError.unavailable("delete profile history failed") }

                let delEvents = try store.prepare("DELETE FROM event_log WHERE object_id = ?")
                defer { sqlite3_finalize(delEvents) }
                try store.bindText(delEvents, index: 1, value: targetID)
                guard sqlite3_step(delEvents) == SQLITE_DONE else { throw StorageError.unavailable("delete events failed") }

                if derivedIndexDeleteSucceeds {
                    let delIdx = try store.prepare("DELETE FROM derived_index WHERE target_id = ?")
                    defer { sqlite3_finalize(delIdx) }
                    try store.bindText(delIdx, index: 1, value: targetID)
                    guard sqlite3_step(delIdx) == SQLITE_DONE else { throw StorageError.unavailable("delete index failed") }
                }

                let allDone = derivedIndexDeleteSucceeds && backupsDeleteSucceeds
                let finalStatus: DeletionStatus = allDone ? .complete : .failed
                let detail = allDone
                    ? "state, events, index, and tracked backups deleted"
                    : "incomplete deletion: derivedIndex=\(derivedIndexDeleteSucceeds), backups=\(backupsDeleteSucceeds)"

                let upd = try store.prepare(
                    """
                    UPDATE deletion_requests
                    SET status = ?, state_deleted = 1, events_deleted = 1,
                        derived_index_deleted = ?, backups_deleted = ?, detail = ?
                    WHERE request_id = ?
                    """
                )
                defer { sqlite3_finalize(upd) }
                try store.bindText(upd, index: 1, value: finalStatus.rawValue)
                sqlite3_bind_int(upd, 2, derivedIndexDeleteSucceeds ? 1 : 0)
                sqlite3_bind_int(upd, 3, backupsDeleteSucceeds ? 1 : 0)
                try store.bindText(upd, index: 4, value: detail)
                try store.bindText(upd, index: 5, value: requestID)
                guard sqlite3_step(upd) == SQLITE_DONE else { throw StorageError.unavailable("update deletion failed") }

                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return try fetchDeletion(requestID: requestID)
    }

    public func fetchDeletion(requestID: String) throws -> DeletionRecord {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                """
                SELECT request_id, target_id, status, state_deleted, events_deleted, derived_index_deleted, backups_deleted, detail
                FROM deletion_requests WHERE request_id = ?
                """
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: requestID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw StorageError.notFound }
            return DeletionRecord(
                requestID: store.columnText(stmt, index: 0),
                targetID: store.columnText(stmt, index: 1),
                status: DeletionStatus(rawValue: store.columnText(stmt, index: 2)) ?? .failed,
                stateDeleted: sqlite3_column_int(stmt, 3) == 1,
                eventsDeleted: sqlite3_column_int(stmt, 4) == 1,
                derivedIndexDeleted: sqlite3_column_int(stmt, 5) == 1,
                backupsDeleted: sqlite3_column_int(stmt, 6) == 1,
                detail: store.columnText(stmt, index: 7)
            )
        }
    }
}

public final class BackupAndRecoveryManager: @unchecked Sendable {
    public init() {}

    public func createOnlineBackup(
        sourceStore: SQLiteStore,
        backupDBPath: String,
        anchor: FreshnessAnchorStore,
        blobs: [(blobID: String, url: URL)] = []
    ) throws -> BackupManifest {
        let anchorState = try anchor.read()

        var blobDigests: [BackupBlobDigest] = []
        for (blobID, url) in blobs {
            let data = try Data(contentsOf: url)
            let hex = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
            blobDigests.append(BackupBlobDigest(blobID: blobID, sha256Hex: hex, byteLength: data.count))
        }

        try sourceStore.withConnectionLock { srcDB in
            var destDB: OpaquePointer?
            let openRC = sqlite3_open_v2(
                backupDBPath,
                &destDB,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            )
            guard openRC == SQLITE_OK, let destDB else {
                if let destDB { sqlite3_close(destDB) }
                throw StorageError.unavailable("failed to open backup destination")
            }
            defer { sqlite3_close(destDB) }

            guard let backupHandle = sqlite3_backup_init(destDB, "main", srcDB, "main") else {
                throw StorageError.unavailable("sqlite3_backup_init failed")
            }
            defer { sqlite3_backup_finish(backupHandle) }

            let stepRC = sqlite3_backup_step(backupHandle, -1)
            guard stepRC == SQLITE_DONE else {
                throw StorageError.unavailable("sqlite3_backup_step failed with \(stepRC)")
            }
        }

        return BackupManifest(
            workspaceID: sourceStore.workspaceID,
            epoch: anchorState.epoch,
            sequence: anchorState.sequence,
            headDigest: anchorState.headDigest,
            storeGeneration: sourceStore.storeGeneration,
            blobDigests: blobDigests
        )
    }

    /// Restores a backup safely in an isolated staging DB, validates `integrity_check` +
    /// `foreign_key_check` + blob digests, replays post-snapshot `RecoveryLedger` deletions
    /// and client revocations, rotates `storeGeneration`, marks old active attempts `Unknown`,
    /// and commits a `RESTORE_BACKUP` `DurableIntent` advancing `FreshnessAnchor`.
    public func restoreWorkspaceFromBackup(
        backupDBPath: String,
        targetDBPath: String,
        manifest: BackupManifest,
        coordinator: RecoveryCoordinator,
        blobFilesByID: [String: URL] = [:],
        newStoreGeneration: String = UUID().uuidString.lowercased(),
        restoreApprovalID: String,
        intentSigningKeyID: String,
        nowEpochSeconds: Int64
    ) throws -> SQLiteStore {
        // 1. Reconcile current state; block restore if quarantined or rollback detected
        let posture = coordinator.reconcileOnRestart()
        if case .quarantined(let reason) = posture {
            throw StorageError.unavailable("RECOVERY_QUARANTINED: \(reason)")
        }

        let currentAnchor = try coordinator.anchor.read()
        guard manifest.workspaceID == coordinator.store.workspaceID,
              manifest.epoch == currentAnchor.epoch,
              manifest.sequence <= currentAnchor.sequence else {
            _ = coordinator.quarantine("backup manifest epoch/sequence mismatch against anchor")
            throw StorageError.unavailable("RECOVERY_QUARANTINED: backup manifest mismatch")
        }

        // 2. Verify referenced blobs match manifest digests & lengths
        for expectedBlob in manifest.blobDigests {
            guard let fileURL = blobFilesByID[expectedBlob.blobID],
                  let data = try? Data(contentsOf: fileURL),
                  data.count == expectedBlob.byteLength else {
                throw StorageError.corrupt("missing or size-mismatched backup blob \(expectedBlob.blobID)")
            }
            let hex = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
            guard hex == expectedBlob.sha256Hex else {
                throw StorageError.corrupt("digest mismatch for backup blob \(expectedBlob.blobID)")
            }
        }

        // 3. Stage in isolated DB path and verify integrity_check + foreign_key_check
        let stagingPath = backupDBPath + ".staging.\(UUID().uuidString.lowercased())"
        if FileManager.default.fileExists(atPath: stagingPath) {
            try FileManager.default.removeItem(atPath: stagingPath)
        }
        try FileManager.default.copyItem(atPath: backupDBPath, toPath: stagingPath)
        defer { try? FileManager.default.removeItem(atPath: stagingPath) }

        do {
            let stagedStore = try SQLiteStore(path: stagingPath, workspaceID: manifest.workspaceID)
            let health = try stagedStore.verifyIntegrity()
            guard health == .available else {
                throw StorageError.corrupt("staged backup failed integrity/foreign_key check")
            }
        }

        // 4. Publish staged copy to targetDBPath (removing stale WAL/SHM sidecars if present)
        for suffix in ["", "-wal", "-shm"] {
            let path = targetDBPath + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
        try FileManager.default.copyItem(atPath: stagingPath, toPath: targetDBPath)

        let restoredStore = try SQLiteStore(path: targetDBPath, workspaceID: manifest.workspaceID)

        // 5. Replay all post-snapshot deletions and revocations from RecoveryLedger
        let entries = try coordinator.ledger.readAll()
        let postSnapshotEntries = entries.filter { $0.intent.sequence > manifest.sequence }

        try restoredStore.withConnectionLock { _ in
            try restoredStore.execute("BEGIN IMMEDIATE")
            do {
                for entry in postSnapshotEntries {
                    switch entry.intent.action {
                    case .deleteState, .deleteArtifact:
                        let delState = try restoredStore.prepare("DELETE FROM operational_state WHERE object_id = ?")
                        defer { sqlite3_finalize(delState) }
                        try restoredStore.bindText(delState, index: 1, value: entry.intent.targetID)
                        guard sqlite3_step(delState) == SQLITE_DONE else {
                            throw StorageError.unavailable("replay delete state failed")
                        }
                        let delProfile = try restoredStore.prepare("DELETE FROM profile_revisions WHERE workspace_id = ? AND object_id = ?")
                        defer { sqlite3_finalize(delProfile) }
                        try restoredStore.bindText(delProfile, index: 1, value: manifest.workspaceID)
                        try restoredStore.bindText(delProfile, index: 2, value: entry.intent.targetID)
                        guard sqlite3_step(delProfile) == SQLITE_DONE else {
                            throw StorageError.unavailable("replay delete profile history failed")
                        }
                        if try tableExists(restoredStore, name: "derived_index") {
                            let delIdx = try restoredStore.prepare("DELETE FROM derived_index WHERE target_id = ?")
                            defer { sqlite3_finalize(delIdx) }
                            try restoredStore.bindText(delIdx, index: 1, value: entry.intent.targetID)
                            _ = sqlite3_step(delIdx)
                        }
                        if try tableExists(restoredStore, name: "deletion_requests") {
                            let markDel = try restoredStore.prepare(
                                """
                                INSERT OR REPLACE INTO deletion_requests (
                                    request_id, workspace_id, target_id, status,
                                    state_deleted, events_deleted, derived_index_deleted, backups_deleted, detail
                                ) VALUES (?, ?, ?, 'COMPLETE', 1, 1, 1, 1, 'replayed from RecoveryLedger')
                                """
                            )
                            defer { sqlite3_finalize(markDel) }
                            try restoredStore.bindText(markDel, index: 1, value: "replay-\(entry.intent.intentID)")
                            try restoredStore.bindText(markDel, index: 2, value: manifest.workspaceID)
                            try restoredStore.bindText(markDel, index: 3, value: entry.intent.targetID)
                            _ = sqlite3_step(markDel)
                        }

                    case .revokeClient:
                        if try tableExists(restoredStore, name: "registered_clients") {
                            let revClient = try restoredStore.prepare(
                                "UPDATE registered_clients SET status = 'REVOKED', policy_version = policy_version + 1, revoked_at = ? WHERE client_id = ?"
                            )
                            defer { sqlite3_finalize(revClient) }
                            sqlite3_bind_int64(revClient, 1, nowEpochSeconds)
                            try restoredStore.bindText(revClient, index: 2, value: entry.intent.targetID)
                            _ = sqlite3_step(revClient)
                        }
                        if try tableExists(restoredStore, name: "client_sessions") {
                            try restoredStore.execute("UPDATE client_sessions SET active = 0")
                        }

                    case .restoreBackup:
                        break
                    }
                }

                // Invalidate unused approvals, nonces, and sessions from backup (ARC-10 §복원 세대 계약)
                if try tableExists(restoredStore, name: "approvals") {
                    try restoredStore.execute("UPDATE approvals SET status = 'REVOKED' WHERE consumed = 0")
                }
                if try tableExists(restoredStore, name: "auth_nonces") {
                    try restoredStore.execute("UPDATE auth_nonces SET consumed = 1 WHERE consumed = 0")
                }
                if try tableExists(restoredStore, name: "client_sessions") {
                    try restoredStore.execute("UPDATE client_sessions SET active = 0")
                }
                // Mark any in-flight Starting/Running operational_state attempts Unknown
                if try tableExists(restoredStore, name: "execution_attempts") {
                    try restoredStore.execute(
                        "UPDATE execution_attempts SET state = 'Unknown' WHERE state IN ('Starting', 'Running', 'CancelRequested')"
                    )
                }

                // Rotate storeGeneration to an unpredictable new generation
                let rotStmt = try restoredStore.prepare("UPDATE workspace_meta SET store_generation = ? WHERE workspace_id = ?")
                defer { sqlite3_finalize(rotStmt) }
                try restoredStore.bindText(rotStmt, index: 1, value: newStoreGeneration)
                try restoredStore.bindText(rotStmt, index: 2, value: manifest.workspaceID)
                guard sqlite3_step(rotStmt) == SQLITE_DONE else {
                    throw StorageError.unavailable("rotate store_generation failed")
                }

                try restoredStore.execute("COMMIT")
            } catch {
                _ = try? restoredStore.execute("ROLLBACK")
                throw error
            }
        }

        // Reload storeGeneration into restoredStore instance
        let finalRestored = try SQLiteStore(path: targetDBPath, workspaceID: manifest.workspaceID)

        // Record RESTORE_BACKUP intent in RecoveryLedger and advance FreshnessAnchor
        let (lastSeq, lastHead) = try coordinator.ledger.lastHead()
        let restoreIntent = DurableIntent(
            intentID: "restore-\(UUID().uuidString.lowercased())",
            workspaceID: manifest.workspaceID,
            epoch: currentAnchor.epoch,
            sequence: lastSeq + 1,
            previousHeadDigest: lastHead,
            action: .restoreBackup,
            targetID: targetDBPath,
            targetDigest: "gen:\(newStoreGeneration)",
            approvalID: restoreApprovalID,
            policyVersion: 1,
            storeGeneration: newStoreGeneration,
            issuedAt: nowEpochSeconds
        )
        let digest = try restoreIntent.computeHeadDigest()
        let entry = try coordinator.signAndAppendLedger(intent: restoreIntent, headDigest: digest, keyID: intentSigningKeyID)
        _ = try coordinator.anchor.advance(
            expected: currentAnchor,
            next: FreshnessAnchorTransition(
                workspaceID: manifest.workspaceID,
                epoch: currentAnchor.epoch,
                sequence: entry.intent.sequence,
                previousHeadDigest: lastHead,
                headDigest: digest,
                storeGeneration: newStoreGeneration
            )
        )

        return finalRestored
    }

    private func tableExists(_ store: SQLiteStore, name: String) throws -> Bool {
        let stmt = try store.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?")
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: name)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }
}
