import Foundation
import XCTest
@testable import OchesCore

final class MemoryAndContextTests: XCTestCase {
    private func makeEvidenceRef(
        id: String = "ev-1",
        objectID: String = "evidence/file-1",
        revision: String = "1",
        digest: String = "sha256:ev1",
        scope: PermissionScope = .observationRawRead,
        generation: String = "gen-1"
    ) -> MemoryEvidenceRef {
        MemoryEvidenceRef(
            evidenceID: id,
            objectID: objectID,
            revision: RevisionRef(objectID: objectID, storeGeneration: generation, revision: revision),
            contentDigest: digest,
            requiredScope: scope,
            originUntrusted: true
        )
    }

    func testMemoryLifecycle90DayExpiryMarkdownFrontmatterAndDreamingUnsupported() throws {
        let dir = try makeTempDirectory("mem-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen-1")
        let memoryStore = try MemoryStore(store: store)
        let evRef = makeEvidenceRef()

        // 1. Rejects missing evidence and secret markers
        XCTAssertThrowsError(try memoryStore.proposeMemory(
            memoryID: "mem-empty-ev", title: "Empty", keywords: ["arch"], bodyMarkdown: "body",
            evidenceRefs: [], policyVersion: 1, accessScope: .workspaceRead, actorID: "actor", requestID: "p-empty", now: 100
        ))
        XCTAssertThrowsError(try memoryStore.proposeMemory(
            memoryID: "mem-secret", title: "Secret", keywords: ["arch"], bodyMarkdown: "token sk-ant-12345",
            evidenceRefs: [evRef], policyVersion: 1, accessScope: .workspaceRead, actorID: "actor", requestID: "p-secret", now: 100
        ))

        // 2. Propose Candidate -> Validate fails if evidence missing -> Validate succeeds -> 90-day TTL
        let proposed = try memoryStore.proposeMemory(
            memoryID: "mem-1", title: "Build Rule", keywords: ["swift", "build"], bodyMarkdown: "Always run swift test.",
            evidenceRefs: [evRef], policyVersion: 1, accessScope: .workspaceRead, actorID: "actor", requestID: "p-1", now: 1_000
        )
        XCTAssertEqual(proposed.entry.state, .candidate)

        XCTAssertThrowsError(try memoryStore.validateMemory(
            memoryID: "mem-1", expectedRevision: proposed.revision, approve: true,
            evidenceResolver: { _ in EvidenceVerificationState(exists: false, currentRevision: nil, currentDigest: nil) },
            actorID: "actor", requestID: "v-fail", now: 1_010
        ))

        let validated = try memoryStore.validateMemory(
            memoryID: "mem-1", expectedRevision: proposed.revision, approve: true,
            evidenceResolver: { ref in
                EvidenceVerificationState(exists: true, currentRevision: ref.revision, currentDigest: ref.contentDigest)
            },
            actorID: "actor", requestID: "v-pass", now: 1_010
        )
        XCTAssertEqual(validated.entry.state, .verified)
        XCTAssertEqual(validated.entry.verifiedAt, 1_010)
        XCTAssertEqual(validated.entry.expiresAt, 1_010 + 90 * 86_400)

        // Markdown + YAML frontmatter rendering (E7)
        let rendered = MemoryStore.renderMarkdownWithFrontmatter(validated.entry)
        XCTAssertTrue(rendered.hasPrefix("---\nmemory_id: \"mem-1\""))
        XCTAssertTrue(rendered.contains("state: \"Verified\""))
        XCTAssertTrue(rendered.contains("evidence_ids: [\"ev-1\"]"))
        XCTAssertTrue(rendered.contains("Always run swift test."))

        // 3. After 90 days, ContextBuilder excludes memory as staleExpired
        let builder = try ContextBuilder(store: store, memoryStore: memoryStore)
        let taskRev = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "1")
        let expiredSelection = try builder.selectContext(
            selectionID: "sel-expired", taskRevision: taskRev, keywords: ["swift"],
            callerScopes: [.workspaceRead, .observationRawRead], currentPolicyVersion: 1,
            evidenceResolver: { ref in
                EvidenceVerificationState(exists: true, currentRevision: ref.revision, currentDigest: ref.contentDigest)
            },
            actorID: "actor", requestID: "sel-exp", now: 1_010 + 90 * 86_400
        )
        XCTAssertTrue(expiredSelection.selection.selectedItems.isEmpty)
        XCTAssertEqual(expiredSelection.selection.excludedItems.first?.reason, .staleExpired)

        // 4. Dreaming v1 unsupported (E9)
        XCTAssertThrowsError(try memoryStore.requestDreaming(actorID: "actor")) { error in
            XCTAssertEqual(error as? MemoryError, .dreamingUnsupportedV1)
        }
    }

    func testContextSelectionBudgetTimeoutAndPostSelectionRevocationV08() throws {
        let dir = try makeTempDirectory("ctx-sel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen-1")
        let enforcer = try AuthorizationEnforcer(store: store)
        let memoryStore = try MemoryStore(store: store)
        let builder = try ContextBuilder(store: store, memoryStore: memoryStore)

        let ev1 = makeEvidenceRef(id: "ev-1", objectID: "evidence/doc-1", digest: "dig-1", scope: .observationRawRead)
        let ev2 = makeEvidenceRef(id: "ev-2", objectID: "evidence/doc-2", digest: "dig-2", scope: .observationRawRead)

        let p1 = try memoryStore.proposeMemory(
            memoryID: "mem-a", title: "Alpha", keywords: ["design"], bodyMarkdown: String(repeating: "A", count: 120),
            evidenceRefs: [ev1], policyVersion: 1, accessScope: .workspaceRead, actorID: "actor", requestID: "pa", now: 100
        )
        let p2 = try memoryStore.proposeMemory(
            memoryID: "mem-b", title: "Beta", keywords: ["design"], bodyMarkdown: String(repeating: "B", count: 120),
            evidenceRefs: [ev2], policyVersion: 1, accessScope: .workspaceRead, actorID: "actor", requestID: "pb", now: 101
        )
        _ = try memoryStore.validateMemory(
            memoryID: "mem-a", expectedRevision: p1.revision, approve: true,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "va", now: 102
        )
        let v2 = try memoryStore.validateMemory(
            memoryID: "mem-b", expectedRevision: p2.revision, approve: true,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "vb", now: 103
        )
        let oneItemBytes = Data(MemoryStore.renderMarkdownWithFrontmatter(v2.entry).utf8).count
        let taskRev = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "1")

        // 1. Enforce 64 KiB cap (rejects > 65_536) and budgetExceeded exclusion
        XCTAssertThrowsError(try builder.selectContext(
            selectionID: "sel-over", taskRevision: taskRev, keywords: ["design"],
            callerScopes: [.workspaceRead, .observationRawRead], currentPolicyVersion: 1,
            budgetBytes: ContextBuilder.maxContextBudgetBytes + 1,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "sel-over", now: 104
        )) { XCTAssertEqual($0 as? MemoryError, .budgetInvalid) }

        let tightSelection = try builder.selectContext(
            selectionID: "sel-tight", taskRevision: taskRev, keywords: ["design"],
            callerScopes: [.workspaceRead, .observationRawRead], currentPolicyVersion: 1,
            budgetBytes: oneItemBytes + 10,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "sel-tight", now: 105
        )
        XCTAssertFalse(tightSelection.selection.transferExecuted)
        XCTAssertEqual(tightSelection.selection.selectedItems.map(\.memoryID), ["mem-a"])
        XCTAssertEqual(tightSelection.selection.excludedItems.first?.memoryID, "mem-b")
        XCTAssertEqual(tightSelection.selection.excludedItems.first?.reason, .budgetExceeded)

        // 2. Timeout partial marker (E8)
        let timeoutSel = try builder.selectContext(
            selectionID: "sel-timeout", taskRevision: taskRev, keywords: ["design"],
            callerScopes: [.workspaceRead, .observationRawRead], currentPolicyVersion: 1,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "sel-timeout", now: 106, injectTimeoutAfterCount: 1
        )
        XCTAssertTrue(timeoutSel.selection.partial)
        XCTAssertEqual(timeoutSel.selection.excludedItems.first?.reason, .timeoutPartial)

        // 3. V-08 / C-06: Post-selection revocation / evidence mutation / policy bump blocks transfer even with valid EXTERNAL_TRANSFER approval
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: "app-xfer-1", kind: .externalTransfer, subjectClientID: "desktop-1",
            decidedByActorID: "actor", workspaceID: "ws", normalizedTarget: "/ws",
            allowedScopes: [.contextSubmit],
            binding: ApprovalBinding(
                providerID: "claude", accountRef: "acct-1", recipientScope: "anthropic-messages",
                contextSelectionRevision: tightSelection.revision,
                inputDigest: tightSelection.selection.transferPreviewDigest,
                transferPurpose: "task.run", dataScope: "verified-memory-subset"
            ),
            policyVersion: 1, issuedAt: 100, expiresAt: 5000, status: .approved
        ), decidedByTrustedUI: true)

        // Missing approval -> approvalRequired
        XCTAssertThrowsError(try builder.revalidateAndAuthorizeTransfer(
            selectionID: "sel-tight", selectionRevision: tightSelection.revision,
            clientID: "desktop-1", callerScopes: [.workspaceRead, .observationRawRead],
            currentPolicyVersion: 1, providerID: "claude", accountRef: "acct-1",
            recipientScope: "anthropic-messages", transferPurpose: "task.run",
            dataScope: "verified-memory-subset", transferApprovalID: nil,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            now: 110
        )) { XCTAssertEqual($0 as? MemoryError, .approvalRequired([.externalTransfer])) }

        // Revoked evidence scope after selection -> selectionStale (0 injected!)
        XCTAssertThrowsError(try builder.revalidateAndAuthorizeTransfer(
            selectionID: "sel-tight", selectionRevision: tightSelection.revision,
            clientID: "desktop-1", callerScopes: [.workspaceRead],
            currentPolicyVersion: 1, providerID: "claude", accountRef: "acct-1",
            recipientScope: "anthropic-messages", transferPurpose: "task.run",
            dataScope: "verified-memory-subset", transferApprovalID: "app-xfer-1",
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            now: 110
        )) { error in
            guard case .selectionStale = error as? MemoryError else { return XCTFail("Expected selectionStale, got \(error)") }
        }

        // Mutated evidence digest after selection -> selectionStale
        XCTAssertThrowsError(try builder.revalidateAndAuthorizeTransfer(
            selectionID: "sel-tight", selectionRevision: tightSelection.revision,
            clientID: "desktop-1", callerScopes: [.workspaceRead, .observationRawRead],
            currentPolicyVersion: 1, providerID: "claude", accountRef: "acct-1",
            recipientScope: "anthropic-messages", transferPurpose: "task.run",
            dataScope: "verified-memory-subset", transferApprovalID: "app-xfer-1",
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: "mutated-digest") },
            now: 110
        ))

        // Valid revalidation + valid EXTERNAL_TRANSFER approval succeeds once & consumes approval
        let auth = try builder.revalidateAndAuthorizeTransfer(
            selectionID: "sel-tight", selectionRevision: tightSelection.revision,
            clientID: "desktop-1", callerScopes: [.workspaceRead, .observationRawRead],
            currentPolicyVersion: 1, providerID: "claude", accountRef: "acct-1",
            recipientScope: "anthropic-messages", transferPurpose: "task.run",
            dataScope: "verified-memory-subset", transferApprovalID: "app-xfer-1",
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            now: 110
        )
        XCTAssertEqual(auth.approvedItemCount, 1)
        XCTAssertEqual(auth.consumedApprovalID, "app-xfer-1")

        // Consumed approval cannot be reused
        XCTAssertThrowsError(try builder.revalidateAndAuthorizeTransfer(
            selectionID: "sel-tight", selectionRevision: tightSelection.revision,
            clientID: "desktop-1", callerScopes: [.workspaceRead, .observationRawRead],
            currentPolicyVersion: 1, providerID: "claude", accountRef: "acct-1",
            recipientScope: "anthropic-messages", transferPurpose: "task.run",
            dataScope: "verified-memory-subset", transferApprovalID: "app-xfer-1",
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            now: 111
        )) { XCTAssertEqual($0 as? MemoryError, .approvalRequired([.externalTransfer])) }
    }

    func testDeletionPropagationIndexRebuildAndBackupRestoreReplayV16() throws {
        let dir = try makeTempDirectory("mem-v16-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("core.db").path
        let backupPath = dir.appendingPathComponent("backup.db").path
        let restoredPath = dir.appendingPathComponent("restored.db").path
        let ledgerDir = dir.appendingPathComponent("ledger", isDirectory: true)

        let store = try SQLiteStore(path: dbPath, workspaceID: "ws", initialStoreGeneration: "gen-1")
        let keyStore = ScopedProtectedKeyStore()
        let ik = try keyStore.generateSigningKey(keyID: "ik-1")
        let anchor = LocalSealedFreshnessAnchor(workspaceID: "ws", epoch: 1, storeGeneration: "gen-1")
        let ledger = try RecoveryLedger(ledgerDirectoryURL: ledgerDir, workspaceID: "ws")
        let coordinator = try RecoveryCoordinator(store: store, anchor: anchor, ledger: ledger, keyStore: keyStore)
        coordinator.registerIntentSigningKey(keyID: "ik-1", publicKeyBytes: ik.publicKeyBytes, active: true)

        let memoryStore = try MemoryStore(store: store)
        let deletionLifecycle = try DeletionRequestLifecycle(store: store)
        let backupManager = BackupAndRecoveryManager()

        let evKeep = makeEvidenceRef(id: "ev-keep", objectID: "evidence/keep")
        let evDel = makeEvidenceRef(id: "ev-del", objectID: "evidence/delete-me")

        let propKeep = try memoryStore.proposeMemory(
            memoryID: "mem-keep", title: "Keep Memory", keywords: ["shared"], bodyMarkdown: "Kept knowledge.",
            evidenceRefs: [evKeep], policyVersion: 1, accessScope: .workspaceRead, actorID: "actor", requestID: "p-keep", now: 100
        )
        let propDel = try memoryStore.proposeMemory(
            memoryID: "mem-delete", title: "Delete Memory", keywords: ["shared"], bodyMarkdown: "Sensitive knowledge.",
            evidenceRefs: [evDel], policyVersion: 1, accessScope: .workspaceRead, actorID: "actor", requestID: "p-del", now: 101
        )
        _ = try memoryStore.validateMemory(
            memoryID: "mem-keep", expectedRevision: propKeep.revision, approve: true,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "v-keep", now: 102
        )
        _ = try memoryStore.validateMemory(
            memoryID: "mem-delete", expectedRevision: propDel.revision, approve: true,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "v-del", now: 103
        )

        let builderBefore = try ContextBuilder(store: store, memoryStore: memoryStore)
        let taskRev = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "1")
        let preBackupSel = try builderBefore.selectContext(
            selectionID: "sel-pre", taskRevision: taskRev, keywords: ["shared"],
            callerScopes: [.workspaceRead, .observationRawRead], currentPolicyVersion: 1,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "sel-pre", now: 104
        )
        XCTAssertEqual(Set(preBackupSel.selection.selectedItems.map(\.memoryID)), Set(["mem-keep", "mem-delete"]))

        // Take online backup BEFORE deletion
        let manifest = try backupManager.createOnlineBackup(sourceStore: store, backupDBPath: backupPath, anchor: anchor)

        // Delete evidence `evidence/delete-me` and record durable deletion intent in RecoveryLedger
        try coordinator.issueTrustedUIApproval(approvalID: "app-del", action: .deleteState, targetDigest: "sha256:ev-del")
        let prepDel = try coordinator.commitIntentInDB(
            intentID: "int-del-1", approvalID: "app-del", action: .deleteState,
            targetID: "evidence/delete-me", targetDigest: "sha256:ev-del", nowEpochSeconds: 200
        )
        let entryDel = try coordinator.signAndAppendLedger(intent: prepDel.intent, headDigest: prepDel.headDigest, keyID: "ik-1")
        _ = try coordinator.advanceAnchorAndComplete(entryDel)

        _ = try deletionLifecycle.beginDeletion(requestID: "del-req-1", targetID: "evidence/delete-me")
        let delRecord = try deletionLifecycle.executeDeletion(requestID: "del-req-1", targetID: "evidence/delete-me")
        XCTAssertEqual(delRecord.status, .complete)

        // Derived index no longer lists mem-delete; rebuildDerivedIndex does NOT resurrect mem-delete
        XCTAssertEqual(try memoryStore.searchDerivedIndex(keywords: ["shared"]), ["mem-keep"])
        try store.executeRawForTesting("DELETE FROM memory_search_index")
        let rebuiltCount = try memoryStore.rebuildDerivedIndex()
        XCTAssertEqual(rebuiltCount, 1)
        XCTAssertEqual(try memoryStore.searchDerivedIndex(keywords: ["shared"]), ["mem-keep"])

        // Context selection after deletion exposes 0 deleted records
        let postDelSel = try builderBefore.selectContext(
            selectionID: "sel-post-del", taskRevision: taskRev, keywords: [],
            callerScopes: [.workspaceRead, .observationRawRead], currentPolicyVersion: 1,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "sel-post-del", now: 205
        )
        XCTAssertEqual(postDelSel.selection.selectedItems.map(\.memoryID), ["mem-keep"])
        XCTAssertEqual(postDelSel.selection.excludedItems.first?.memoryID, "mem-delete")
        XCTAssertEqual(postDelSel.selection.excludedItems.first?.reason, .evidenceDeleted)

        // Restore from pre-deletion backup -> deletion replay purges deleted evidence/index and rotates storeGeneration (V-16)
        try coordinator.issueTrustedUIApproval(approvalID: "app-restore", action: .restoreBackup, targetDigest: "gen:gen-restored-2")
        let restoredStore = try backupManager.restoreWorkspaceFromBackup(
            backupDBPath: backupPath,
            targetDBPath: restoredPath,
            manifest: manifest,
            coordinator: coordinator,
            newStoreGeneration: "gen-restored-2",
            restoreApprovalID: "app-restore",
            intentSigningKeyID: "ik-1",
            nowEpochSeconds: 300
        )
        let restoredMemStore = try MemoryStore(store: restoredStore)
        let restoredBuilder = try ContextBuilder(store: restoredStore, memoryStore: restoredMemStore)

        XCTAssertEqual(try restoredMemStore.searchDerivedIndex(keywords: ["shared"]), ["mem-keep"])
        XCTAssertEqual(try restoredMemStore.rebuildDerivedIndex(), 1)
        XCTAssertEqual(try restoredMemStore.searchDerivedIndex(keywords: ["shared"]), ["mem-keep"])

        let postRestoreSel = try restoredBuilder.selectContext(
            selectionID: "sel-post-restore", taskRevision: RevisionRef(objectID: "task-1", storeGeneration: "gen-restored-2", revision: "1"),
            keywords: [], callerScopes: [.workspaceRead, .observationRawRead], currentPolicyVersion: 1,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            actorID: "actor", requestID: "sel-post-restore", now: 305
        )
        XCTAssertEqual(postRestoreSel.selection.selectedItems.map(\.memoryID), ["mem-keep"])

        // Pre-backup selection revision from old storeGeneration fails as stale on restored store
        XCTAssertThrowsError(try restoredBuilder.revalidateAndAuthorizeTransfer(
            selectionID: "sel-pre", selectionRevision: preBackupSel.revision,
            clientID: "desktop-1", callerScopes: [.workspaceRead, .observationRawRead],
            currentPolicyVersion: 1, providerID: "claude", accountRef: "acct-1",
            recipientScope: "anthropic-messages", transferPurpose: "task.run",
            dataScope: "verified-memory-subset", transferApprovalID: nil,
            evidenceResolver: { EvidenceVerificationState(exists: true, currentRevision: $0.revision, currentDigest: $0.contentDigest) },
            now: 306
        )) { error in
            guard case .selectionStale = error as? MemoryError else { return XCTFail("Expected selectionStale on old storeGeneration, got \(error)") }
        }
    }
}
