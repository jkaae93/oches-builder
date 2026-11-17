import Foundation
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
}
