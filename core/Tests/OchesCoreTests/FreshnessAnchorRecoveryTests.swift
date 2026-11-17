import Foundation
import SQLite3
import XCTest
@testable import OchesCore

final class FreshnessAnchorRecoveryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDirectory("recovery-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testHappyPathCASConflictSingleStepRecoveryAndQuarantineTriggers() throws {
        let dbPath = tempDir.appendingPathComponent("core.db").path
        let ledgerDir = tempDir.appendingPathComponent("external-ledger", isDirectory: true)
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let keyStore = ScopedProtectedKeyStore()
        let ik = try keyStore.generateSigningKey(keyID: "ik-1")
        let anchor = LocalSealedFreshnessAnchor(workspaceID: "ws-1", epoch: 1, storeGeneration: "gen-1")
        let ledger = try RecoveryLedger(ledgerDirectoryURL: ledgerDir, workspaceID: "ws-1")
        let coord = try RecoveryCoordinator(store: store, anchor: anchor, ledger: ledger, keyStore: keyStore)
        coord.registerIntentSigningKey(keyID: "ik-1", publicKeyBytes: ik.publicKeyBytes, active: true)

        // 1. Happy path
        try coord.issueTrustedUIApproval(approvalID: "app-1", action: .deleteArtifact, targetDigest: "sha256:aaa")
        let prep1 = try coord.commitIntentInDB(
            intentID: "int-1",
            approvalID: "app-1",
            action: .deleteArtifact,
            targetID: "art-1",
            targetDigest: "sha256:aaa",
            nowEpochSeconds: 1000
        )
        let entry1 = try coord.signAndAppendLedger(intent: prep1.intent, headDigest: prep1.headDigest, keyID: "ik-1")
        let advanced1 = try coord.advanceAnchorAndComplete(entry1)
        XCTAssertEqual(advanced1.sequence, 1)
        XCTAssertEqual(coord.reconcileOnRestart(), .active)

        // Direct stale CAS advance conflicts
        XCTAssertThrowsError(try anchor.advance(
            expected: FreshnessAnchorState(workspaceID: "ws-1", epoch: 1, sequence: 0, headDigest: "GENESIS", storeGeneration: "gen-1"),
            next: FreshnessAnchorTransition(workspaceID: "ws-1", epoch: 1, sequence: 1, previousHeadDigest: "GENESIS", headDigest: "fork", storeGeneration: "gen-1")
        )) { error in
            XCTAssertEqual(error as? StorageError, .versionConflict)
        }

        // 2. Single-step crash recovery (ledger appended before crash prior to anchor advance)
        try coord.issueTrustedUIApproval(approvalID: "app-2", action: .revokeClient, targetDigest: "sha256:bbb")
        let prep2 = try coord.commitIntentInDB(
            intentID: "int-2",
            approvalID: "app-2",
            action: .revokeClient,
            targetID: "client-1",
            targetDigest: "sha256:bbb",
            nowEpochSeconds: 1005
        )
        _ = try coord.signAndAppendLedger(intent: prep2.intent, headDigest: prep2.headDigest, keyID: "ik-1")
        XCTAssertEqual(coord.reconcileOnRestart(), .recoveredActive)
        XCTAssertEqual(try anchor.read().sequence, 2)

        // 3. Unsigned DB row (INTENT_COMMITTED without ledger entry) enters RECOVERY_QUARANTINED
        try coord.issueTrustedUIApproval(approvalID: "app-3", action: .deleteState, targetDigest: "sha256:ccc")
        _ = try coord.commitIntentInDB(
            intentID: "int-3",
            approvalID: "app-3",
            action: .deleteState,
            targetID: "state-1",
            targetDigest: "sha256:ccc",
            nowEpochSeconds: 1010
        )
        if case .quarantined = coord.reconcileOnRestart() {} else {
            XCTFail("Expected quarantined on unsigned INTENT_COMMITTED row")
        }
        // Operations blocked while quarantined
        XCTAssertThrowsError(try coord.ensureActiveForOperation())

        // Untrusted UI cannot release quarantine
        XCTAssertThrowsError(try coord.releaseQuarantineWithTrustedUI(trustedDesktopConfirmed: false, newStoreGeneration: "gen-2"))
        // Trusted Desktop UI releases quarantine advancing epoch
        let cleanLedgerEntries = try ledger.readAll()
        try store.executeRawForTesting("DELETE FROM durable_intents WHERE intent_id = 'int-3'")
        let resetAnchor = try coord.releaseQuarantineWithTrustedUI(trustedDesktopConfirmed: true, newStoreGeneration: "gen-2")
        XCTAssertEqual(resetAnchor.epoch, 2)
        XCTAssertEqual(cleanLedgerEntries.count, 2)

        // 4. Rollback: anchor sequence > ledger sequence -> quarantined
        let truncated = Array(cleanLedgerEntries.prefix(1))
        try ledger.replaceEntriesForTesting(truncated)
        if case .quarantined = coord.reconcileOnRestart() {} else {
            XCTFail("Expected quarantined when anchor leads ledger")
        }

        // 5. Fork: same sequence, different digest -> quarantined
        var forked = cleanLedgerEntries
        forked[1] = SignedLedgerEntry(
            intent: forked[1].intent,
            headDigest: "forked-digest",
            keyID: forked[1].keyID,
            signatureBase64: forked[1].signatureBase64
        )
        try ledger.replaceEntriesForTesting(forked)
        if case .quarantined = coord.reconcileOnRestart() {} else {
            XCTFail("Expected quarantined on forked digest")
        }

        // 6. Revoked key -> quarantined
        try ledger.replaceEntriesForTesting(cleanLedgerEntries)
        coord.revokeIntentSigningKey(keyID: "ik-1")
        if case .quarantined = coord.reconcileOnRestart() {} else {
            XCTFail("Expected quarantined when intentSigningKey is revoked")
        }

        // 7. Missing/unavailable anchor -> quarantined
        coord.registerIntentSigningKey(keyID: "ik-1", publicKeyBytes: ik.publicKeyBytes, active: true)
        anchor.available = false
        if case .quarantined = coord.reconcileOnRestart() {} else {
            XCTFail("Expected quarantined when FreshnessAnchor is unavailable")
        }
    }

    func testGapGreaterThanOneEntersQuarantine() throws {
        let dbPath = tempDir.appendingPathComponent("gap.db").path
        let ledgerDir = tempDir.appendingPathComponent("gap-ledger", isDirectory: true)
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let keyStore = ScopedProtectedKeyStore()
        let ik = try keyStore.generateSigningKey(keyID: "ik-1")
        let anchor = LocalSealedFreshnessAnchor(workspaceID: "ws-1", epoch: 1, storeGeneration: "gen-1")
        let ledger = try RecoveryLedger(ledgerDirectoryURL: ledgerDir, workspaceID: "ws-1")
        let coord = try RecoveryCoordinator(store: store, anchor: anchor, ledger: ledger, keyStore: keyStore)
        coord.registerIntentSigningKey(keyID: "ik-1", publicKeyBytes: ik.publicKeyBytes, active: true)

        for i in 1...2 {
            try coord.issueTrustedUIApproval(approvalID: "app-\(i)", action: .deleteArtifact, targetDigest: "sha256:\(i)")
            let p = try coord.commitIntentInDB(
                intentID: "int-\(i)",
                approvalID: "app-\(i)",
                action: .deleteArtifact,
                targetID: "art-\(i)",
                targetDigest: "sha256:\(i)",
                nowEpochSeconds: Int64(1000 + i)
            )
            _ = try coord.signAndAppendLedger(intent: p.intent, headDigest: p.headDigest, keyID: "ik-1")
        }

        // Anchor still at 0 while ledger at 2 -> gap > 1 -> quarantined
        if case .quarantined = coord.reconcileOnRestart() {} else {
            XCTFail("Expected quarantined when ledger - anchor > 1")
        }
    }

    func testOnlineBackupRestoreReplaysDeletionsRevocationsAndRotatesGeneration() throws {
        let dbPath = tempDir.appendingPathComponent("live.db").path
        let backupPath = tempDir.appendingPathComponent("backup.db").path
        let restoredPath = tempDir.appendingPathComponent("restored.db").path
        let ledgerDir = tempDir.appendingPathComponent("backup-ledger", isDirectory: true)
        let blobFile = tempDir.appendingPathComponent("blob-1.bin")
        try Data("immutable-artifact-content".utf8).write(to: blobFile)

        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let keyStore = ScopedProtectedKeyStore()
        let ik = try keyStore.generateSigningKey(keyID: "ik-1")
        let registry = try ClientIdentityAndKeyRegistry(store: store, keyStore: keyStore)
        let enforcer = try AuthorizationEnforcer(store: store)
        let anchor = LocalSealedFreshnessAnchor(workspaceID: "ws-1", epoch: 1, storeGeneration: "gen-1")
        let ledger = try RecoveryLedger(ledgerDirectoryURL: ledgerDir, workspaceID: "ws-1")
        let coord = try RecoveryCoordinator(store: store, anchor: anchor, ledger: ledger, keyStore: keyStore)
        coord.registerIntentSigningKey(keyID: "ik-1", publicKeyBytes: ik.publicKeyBytes, active: true)
        let delLifecycle = try DeletionRequestLifecycle(store: store)
        let backupMgr = BackupAndRecoveryManager()

        // Seed state, event, client, and unused approval before backup
        let initRes = try store.commitTransition(TransitionRequest(
            actorID: "user-1",
            workspaceID: "ws-1",
            operation: "doc.create",
            requestID: "req-1",
            objectID: "secret-doc-1",
            ownerModule: "ARC-08",
            expectedRevision: nil,
            normalizedInput: .object([("k", .string("v"))]),
            nextStateJSON: "{\"secret\":\"keep-before-delete\"}",
            events: [NewEventRecord(eventID: "evt-1", sourceID: "core", kind: "doc.created", payloadJSON: "{}", observedAt: 1000)],
            responseJSON: "{}",
            nowEpochSeconds: 1000
        ))
        try registry.registerClient(RegisteredClientRecord(
            clientID: "client-to-revoke",
            signingKeyID: "ck-1",
            signingPublicKeyBase64: "cHVi",
            noiseKeyID: "nk-1",
            noisePublicKeyBase64: "bm9pc2U=",
            trustLevel: .userEnrolledKey,
            teamID: "",
            signingIdentifier: "ext.id",
            allowedWorkspaces: ["ws-1"],
            allowedScopes: ["workspace:read"],
            status: .active,
            policyVersion: 1,
            createdAt: 1000,
            expiresAt: 5000,
            revokedAt: nil
        ))
        let rev0 = initRes.revision
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: "unused-backup-approval",
            kind: .execution,
            subjectClientID: "client-to-revoke",
            decidedByActorID: "user-1",
            workspaceID: "ws-1",
            normalizedTarget: "/tmp/ws",
            allowedScopes: [.runRequest],
            binding: ApprovalBinding(
                runID: "r1",
                taskRevision: rev0,
                preparedAttemptID: "a1",
                instanceRevision: rev0,
                bindingDigest: "b1",
                capabilitySnapshotID: "c1",
                executionRequestDigest: "d1"
            ),
            policyVersion: 1,
            issuedAt: 1000,
            expiresAt: 5000,
            status: .approved
        ), decidedByTrustedUI: true)

        // Take consistent online backup with blob digest
        let manifest = try backupMgr.createOnlineBackup(
            sourceStore: store,
            backupDBPath: backupPath,
            anchor: anchor,
            blobs: [("blob-1", blobFile)]
        )
        XCTAssertEqual(manifest.storeGeneration, "gen-1")
        XCTAssertEqual(manifest.sequence, 0)

        // Incomplete deletion never reports COMPLETE and blocks target reads
        _ = try delLifecycle.beginDeletion(requestID: "del-partial", targetID: "secret-doc-1")
        XCTAssertTrue(try delLifecycle.isTargetBlockedForReads(targetID: "secret-doc-1"))
        let failedDel = try delLifecycle.executeDeletion(
            requestID: "del-partial",
            targetID: "secret-doc-1",
            derivedIndexDeleteSucceeds: false,
            backupsDeleteSucceeds: true
        )
        XCTAssertEqual(failedDel.status, .failed)
        XCTAssertTrue(try delLifecycle.isTargetBlockedForReads(targetID: "secret-doc-1"))

        // Commit post-backup deletion & client revocation intents to RecoveryLedger + FreshnessAnchor
        try coord.issueTrustedUIApproval(approvalID: "app-del", action: .deleteState, targetDigest: "sha256:doc1")
        let pDel = try coord.commitIntentInDB(
            intentID: "int-del",
            approvalID: "app-del",
            action: .deleteState,
            targetID: "secret-doc-1",
            targetDigest: "sha256:doc1",
            nowEpochSeconds: 1100
        )
        let eDel = try coord.signAndAppendLedger(intent: pDel.intent, headDigest: pDel.headDigest, keyID: "ik-1")
        _ = try coord.advanceAnchorAndComplete(eDel)

        try coord.issueTrustedUIApproval(approvalID: "app-rev", action: .revokeClient, targetDigest: "sha256:client1")
        let pRev = try coord.commitIntentInDB(
            intentID: "int-rev",
            approvalID: "app-rev",
            action: .revokeClient,
            targetID: "client-to-revoke",
            targetDigest: "sha256:client1",
            nowEpochSeconds: 1101
        )
        let eRev = try coord.signAndAppendLedger(intent: pRev.intent, headDigest: pRev.headDigest, keyID: "ik-1")
        _ = try coord.advanceAnchorAndComplete(eRev)

        // Corrupted/tampered blob fails restore
        let badBlob = tempDir.appendingPathComponent("bad-blob.bin")
        try Data("tampered".utf8).write(to: badBlob)
        XCTAssertThrowsError(try backupMgr.restoreWorkspaceFromBackup(
            backupDBPath: backupPath,
            targetDBPath: restoredPath,
            manifest: manifest,
            coordinator: coord,
            blobFilesByID: ["blob-1": badBlob],
            newStoreGeneration: "gen-2",
            restoreApprovalID: "app-restore",
            intentSigningKeyID: "ik-1",
            nowEpochSeconds: 1200
        )) { error in
            guard case .corrupt = error as? StorageError else {
                return XCTFail("Expected corrupt error on tampered blob, got \(error)")
            }
        }

        // Valid restore replays deletion & revocation, invalidates unused backup approvals,
        // rotates storeGeneration, and rejects old-generation cursors/revisions with STALE_GENERATION
        let restoredStore = try backupMgr.restoreWorkspaceFromBackup(
            backupDBPath: backupPath,
            targetDBPath: restoredPath,
            manifest: manifest,
            coordinator: coord,
            blobFilesByID: ["blob-1": blobFile],
            newStoreGeneration: "gen-2",
            restoreApprovalID: "app-restore",
            intentSigningKeyID: "ik-1",
            nowEpochSeconds: 1201
        )
        XCTAssertEqual(restoredStore.storeGeneration, "gen-2")

        // Deleted state is NOT resurrected
        XCTAssertThrowsError(try restoredStore.readSnapshot(workspaceID: "ws-1", objectID: "secret-doc-1")) { error in
            XCTAssertEqual(error as? StorageError, .notFound)
        }

        // Client revocation was replayed
        let restoredRegistry = try ClientIdentityAndKeyRegistry(store: restoredStore, keyStore: keyStore)
        let revokedClient = try restoredRegistry.fetchClient(clientID: "client-to-revoke")
        XCTAssertEqual(revokedClient.status, .revoked)

        // Old-generation cursor is rejected with STALE_GENERATION
        let oldCursor = EventCursor(workspaceID: "ws-1", storeGeneration: "gen-1", sequence: 0)
        XCTAssertThrowsError(try restoredStore.listEvents(workspaceID: "ws-1", after: oldCursor)) { error in
            XCTAssertEqual(error as? StorageError, .staleGeneration)
            XCTAssertEqual((error as? StorageError)?.safeWireError.detail, "STALE_GENERATION")
        }

        // Old-generation expectedRevision is rejected with STALE_GENERATION
        XCTAssertThrowsError(try restoredStore.commitTransition(TransitionRequest(
            actorID: "user-1",
            workspaceID: "ws-1",
            operation: "doc.update",
            requestID: "req-stale",
            objectID: "secret-doc-1",
            ownerModule: "ARC-08",
            expectedRevision: initRes.revision,
            normalizedInput: .object([]),
            nextStateJSON: "{}",
            events: [],
            responseJSON: "{}",
            nowEpochSeconds: 1205
        ))) { error in
            XCTAssertEqual(error as? StorageError, .staleGeneration)
        }

        // Unused approval from backup was invalidated (REVOKED)
        let approvalStatus = try restoredStore.withConnectionLock { _ -> String in
            let stmt = try restoredStore.prepare("SELECT status FROM approvals WHERE approval_id = 'unused-backup-approval'")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return "" }
            return restoredStore.columnText(stmt, index: 0)
        }
        XCTAssertEqual(approvalStatus, ApprovalStatus.revoked.rawValue)
    }
}
