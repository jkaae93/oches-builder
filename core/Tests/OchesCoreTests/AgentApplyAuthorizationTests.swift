import Foundation
import XCTest
@testable import OchesCore

final class AgentApplyAuthorizationTests: XCTestCase {
    func testApplyMismatchAndAuditFailureRollBackApprovalAndNonce() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("config")
        try Data("original".utf8).write(to: target)
        let path = target.resolvingSymlinksInPath().standardizedFileURL.path
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let registry = try ClientIdentityAndKeyRegistry(store: store, keyStore: ScopedProtectedKeyStore())
        try registry.registerClient(RegisteredClientRecord(clientID: "desktop", signingKeyID: "key", signingPublicKeyBase64: "cHVi",
            noiseKeyID: "noise", noisePublicKeyBase64: "bm9pc2U=", trustLevel: .platformBound,
            teamID: "TEAM123456", signingIdentifier: "com.oches.desktop", allowedWorkspaces: ["ws"],
            allowedScopes: [PermissionScope.workspaceWrite.rawValue], status: .active, policyVersion: 1,
            createdAt: 100, expiresAt: 5000, revokedAt: nil))
        let enforcer = try AuthorizationEnforcer(store: store)
        let definition = RevisionRef(objectID: "arc04/definition/agent/1", storeGeneration: "gen", revision: "1")
        func binding(_ digest: String) -> ApprovalBinding {
            ApprovalBinding(planID: "plan", planDigest: digest, targetFileVersions: [path: "original-hash"],
                agentDefinitionRevision: definition, adapterVersion: "1")
        }
        let approved = binding("approved-digest")
        try enforcer.recordApproval(ApprovalRecord(approvalID: "approval", kind: .configExportApply,
            subjectClientID: "desktop", decidedByActorID: "user", workspaceID: "ws", normalizedTarget: path,
            allowedScopes: [.workspaceWrite], binding: approved, policyVersion: 1, issuedAt: 100,
            expiresAt: 1000, status: .approved), decidedByTrustedUI: true)
        try enforcer.issueNonce(nonceID: "nonce", clientID: "desktop", keyID: "key", workspaceID: "ws", purpose: "apply", expiresAt: 1000)
        func input(_ expected: ApprovalBinding?, auditFailure: Bool = false, nonce: String = "nonce") -> AuthorizedExecutionInput {
            AuthorizedExecutionInput(actorID: "user", clientID: "desktop", keyID: "key", nonceID: nonce,
                workspaceID: "ws", workspaceRootPath: directory.path, candidateTargetPath: target.path,
                requiredScope: .workspaceWrite, operation: "config.apply", requestID: "request", objectID: "apply-state",
                expectedRevision: nil, preparedAttemptID: nil, requestDigest: "approved-digest",
                applyApprovalID: "approval", expectedApplyBinding: expected, normalizedInput: .object([]),
                nextStateJSON: "{\"state\":\"Applying\"}", responseJSON: "{}", nowEpochSeconds: 200,
                injectAuditFailure: auditFailure)
        }
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(input(nil)))
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(input(binding("changed-digest"))))
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(input(approved, auditFailure: true)))
        XCTAssertThrowsError(try store.readSnapshot(workspaceID: "ws", objectID: "apply-state"))
        let result = try enforcer.authorizeAndCommitExecution(input(approved))
        XCTAssertFalse(result.idempotentReplay)
        XCTAssertEqual(result.revision.revision, "1")
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(input(approved)))
        try enforcer.issueNonce(nonceID: "retry", clientID: "desktop", keyID: "key", workspaceID: "ws", purpose: "apply", expiresAt: 1000)
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(input(binding("changed-digest"), nonce: "retry")))
        XCTAssertTrue(try enforcer.authorizeAndCommitExecution(input(approved, nonce: "retry")).idempotentReplay)
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))

        let definitionData = Data(#"{"schemaVersion":{"major":1,"minor":0},"definitionId":"agent","revision":1,"role":"review","instructions":"inspect","inputs":[],"outputs":[],"tools":[],"permissions":[],"resourceLimits":{"maxDurationSeconds":60,"maxAttempts":1}}"#.utf8)
        let validated = try AgentDefinitionValidator.validate(definitionData)
        let exportBinding = AgentExportBinding(definitionRevision: definition, definitionDigest: validated.digest,
            adapterVersion: "1", providerVersion: "1", capabilitySnapshotID: "cap", capabilityVersion: "1",
            targetPath: directory.appendingPathComponent("new-config").resolvingSymlinksInPath().path, targetDigest: nil)
        let fields = ["schemaVersion", "definitionId", "revision", "role", "instructions", "inputs", "outputs", "tools", "permissions", "resourceLimits"]
        let mappings = fields.map { AgentFieldMapping(field: $0, quality: .exact, targetField: $0,
            officialEvidence: "fixture-doc", experimentEvidence: "fixture-test") }
        let plan = try AgentExportPlan.build(definition: validated, binding: exportBinding, mappings: mappings)
        let rootIdentity = try AnalyzerSafeRoot(rootPath: directory.path).rootIdentity()
        let writeRoot = try AgentConfigWriteRoot(rootPath: directory.path, expectedIdentity: rootIdentity)
        let document = try AgentExportDocument.prepare(plan: plan, previousContent: nil,
            proposedContent: Data("configuration".utf8), rootIdentity: rootIdentity, rootSessionID: writeRoot.sessionID)
        let wrongRoot = AnalyzerSafeRoot.RootIdentity(device: rootIdentity.device, inode: rootIdentity.inode + 1)
        let otherDocument = try AgentExportDocument.prepare(plan: plan, previousContent: nil,
            proposedContent: document.proposedContent, rootIdentity: wrongRoot, rootSessionID: writeRoot.sessionID)
        XCTAssertNotEqual(document.approvalDigest, otherDocument.approvalDigest)
        XCTAssertEqual(writeRoot.write(document: otherDocument), .conflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportBinding.targetPath))
        let reopenedRoot = try AgentConfigWriteRoot(rootPath: directory.path, expectedIdentity: rootIdentity)
        XCTAssertNotEqual(writeRoot.sessionID, reopenedRoot.sessionID)
        XCTAssertEqual(reopenedRoot.write(document: document), .conflict)
        let reopenedDocument = try AgentExportDocument.prepare(plan: plan, previousContent: nil,
            proposedContent: document.proposedContent, rootIdentity: rootIdentity, rootSessionID: reopenedRoot.sessionID)
        XCTAssertNotEqual(document.approvalDigest, reopenedDocument.approvalDigest)
        try enforcer.recordApproval(ApprovalRecord(approvalID: "journal-approval", kind: .configExportApply,
            subjectClientID: "desktop", decidedByActorID: "user", workspaceID: "ws", normalizedTarget: exportBinding.targetPath,
            allowedScopes: [.workspaceWrite], binding: try document.approvalRequestBinding(planID: "journal-plan"),
            policyVersion: 1, issuedAt: 100, expiresAt: 1000, status: .approved), decidedByTrustedUI: true)
        try enforcer.issueNonce(nonceID: "journal-nonce", clientID: "desktop", keyID: "key", workspaceID: "ws", purpose: "apply", expiresAt: 1000)
        let journal = AgentApplyJournal(store: store)
        func record(_ auditFailure: Bool) throws -> TransitionResult {
            try journal.recordAuthorizedIntent(document: document, planID: "journal-plan", approvalID: "journal-approval",
                actorID: "user", clientID: "desktop", keyID: "key", nonceID: "journal-nonce",
                rootPath: directory.path, requestID: "journal-request", now: 200, injectAuditFailure: auditFailure)
        }
        XCTAssertThrowsError(try record(true))
        var writes = 0
        func apply(_ nonce: String) throws -> AgentApplyJournalState {
            try journal.apply(document: document, currentBinding: exportBinding, planID: "journal-plan",
                approvalID: "journal-approval", actorID: "user", clientID: "desktop", keyID: "key",
                nonceID: nonce, rootPath: directory.path, requestID: "journal-request", now: 200, writer: {
                    writes += 1
                    return writeRoot.write(document: document)
                })
        }
        XCTAssertEqual(try apply("journal-nonce"), .applied)
        XCTAssertEqual(writes, 1)
        try enforcer.issueNonce(nonceID: "journal-retry", clientID: "desktop", keyID: "key", workspaceID: "ws", purpose: "apply", expiresAt: 1000)
        XCTAssertEqual(try apply("journal-retry"), .applied)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: exportBinding.targetPath)), document.proposedContent)
        let moved = URL(fileURLWithPath: directory.path + "-moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: directory, to: moved)
        XCTAssertEqual(writeRoot.write(document: document), .conflict)
        try FileManager.default.moveItem(at: moved, to: directory)
    }
}
