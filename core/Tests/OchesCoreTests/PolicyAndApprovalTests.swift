import Foundation
import XCTest
@testable import OchesCore

final class PolicyAndApprovalTests: XCTestCase {
    func testApprovalBindingsEnforceKindSpecificMandatoryFields() {
        let rev = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "1")

        // Execution approval missing preparedAttemptID -> invalid
        let missingAttempt = ApprovalBinding(
            runID: "run-1",
            taskRevision: rev,
            preparedAttemptID: nil,
            instanceRevision: rev,
            bindingDigest: "sha256:bind",
            capabilitySnapshotID: "snap-1",
            executionRequestDigest: "sha256:req"
        )
        XCTAssertFalse(missingAttempt.isValid(for: .execution))

        // Valid execution binding
        let validExec = ApprovalBinding(
            runID: "run-1",
            taskRevision: rev,
            preparedAttemptID: "att-1",
            instanceRevision: rev,
            bindingDigest: "sha256:bind",
            capabilitySnapshotID: "snap-1",
            executionRequestDigest: "sha256:req"
        )
        XCTAssertTrue(validExec.isValid(for: .execution))
        XCTAssertFalse(validExec.isValid(for: .externalTransfer))

        // Valid external transfer binding
        let validTransfer = ApprovalBinding(
            providerID: "claude",
            accountRef: "acct-ref-1",
            recipientScope: "anthropic-messages",
            contextSelectionRevision: rev,
            inputDigest: "sha256:ctx",
            transferPurpose: "task.run",
            dataScope: "workspace-subset"
        )
        XCTAssertTrue(validTransfer.isValid(for: .externalTransfer))

        // Reversed timestamps invalid
        let reversedTimes = ApprovalRecord(
            approvalID: "app-1",
            kind: .execution,
            subjectClientID: "desktop-1",
            decidedByActorID: "user-1",
            workspaceID: "ws-1",
            normalizedTarget: "/tmp/ws",
            allowedScopes: [.runRequest],
            binding: validExec,
            policyVersion: 1,
            issuedAt: 2000,
            expiresAt: 1000,
            status: .approved
        )
        XCTAssertFalse(reversedTimes.isStructurallyValid())
    }

    func testPolicyEngineScopeSeparationUnknownFailClosedAndApprovalDecideRestriction() {
        let engine = PolicyEngine()

        // FC-09: diagnostics:read and workspace:read do not grant observation:raw:read
        let diagRequest = PolicyEvaluationRequest(
            trustLevel: .platformBound,
            clientScopes: [.workspaceRead, .diagnosticsRead, .runObserve],
            workspaceScopes: [.workspaceRead, .diagnosticsRead, .runObserve, .observationRawRead],
            requiredScope: .observationRawRead,
            enforcementVerified: true,
            isTrustedDesktopUISession: true
        )
        XCTAssertEqual(diagRequest.requiredScope, .observationRawRead)
        if case .deny = engine.evaluate(diagRequest) {} else {
            XCTFail("Expected deny when observation:raw:read is absent")
        }

        // Unknown enforcement boundary never becomes allow even with trusted Desktop UI
        let unknownBoundary = PolicyEvaluationRequest(
            trustLevel: .platformBound,
            clientScopes: [.runRequest],
            workspaceScopes: [.runRequest],
            requiredScope: .runRequest,
            enforcementVerified: nil,
            isTrustedDesktopUISession: true
        )
        if case .unknown = engine.evaluate(unknownBoundary) {} else {
            XCTFail("Expected unknown when enforcement boundary is nil")
        }

        // Unverified enforcement boundary denied
        let unverifiedBoundary = PolicyEvaluationRequest(
            trustLevel: .platformBound,
            clientScopes: [.runRequest],
            workspaceScopes: [.runRequest],
            requiredScope: .runRequest,
            enforcementVerified: false,
            isTrustedDesktopUISession: true
        )
        if case .deny = engine.evaluate(unverifiedBoundary) {} else {
            XCTFail("Expected deny when enforcementVerified is false")
        }

        // approval:decide denied for USER_ENROLLED_KEY extension even if scope claimed
        let extDecide = PolicyEvaluationRequest(
            trustLevel: .userEnrolledKey,
            clientScopes: [.approvalDecide],
            workspaceScopes: [.approvalDecide],
            requiredScope: .approvalDecide,
            enforcementVerified: true,
            isTrustedDesktopUISession: false
        )
        if case .deny = engine.evaluate(extDecide) {} else {
            XCTFail("Expected deny for USER_ENROLLED_KEY attempting approval:decide")
        }

        // Untrusted content origin denied
        let contentOrigin = PolicyEvaluationRequest(
            trustLevel: .platformBound,
            clientScopes: [.runRequest],
            workspaceScopes: [.runRequest],
            requiredScope: .runRequest,
            enforcementVerified: true,
            isUntrustedContentOrigin: true,
            isTrustedDesktopUISession: true
        )
        if case .deny = engine.evaluate(contentOrigin) {} else {
            XCTFail("Expected deny for untrusted content origin")
        }

        // Valid Desktop trusted UI approval:decide allowed
        let desktopDecide = PolicyEvaluationRequest(
            trustLevel: .platformBound,
            clientScopes: [.approvalDecide],
            workspaceScopes: [.approvalDecide],
            requiredScope: .approvalDecide,
            enforcementVerified: true,
            isTrustedDesktopUISession: true
        )
        XCTAssertEqual(engine.evaluate(desktopDecide), .allow)
    }

    func testAuthorizationEnforcerRevalidatesPathsRevocationAttemptReuseTransferApprovalAuditAndTOCTOU() throws {
        let tempDir = try makeTempDirectory("authz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wsRoot = tempDir.appendingPathComponent("workspace", isDirectory: true)
        let outsideDir = tempDir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let targetFile = wsRoot.appendingPathComponent("file.txt")
        let otherFile = wsRoot.appendingPathComponent("other.txt")
        let outsideFile = outsideDir.appendingPathComponent("secret.txt")
        try "hello".write(to: targetFile, atomically: true, encoding: .utf8)
        try "other".write(to: otherFile, atomically: true, encoding: .utf8)
        try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        let canonicalTarget = targetFile.resolvingSymlinksInPath().standardizedFileURL.path
        let dbPath = tempDir.appendingPathComponent("authz.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let keyStore = ScopedProtectedKeyStore()
        let registry = try ClientIdentityAndKeyRegistry(store: store, keyStore: keyStore)
        let enforcer = try AuthorizationEnforcer(store: store)

        try registry.registerClient(RegisteredClientRecord(
            clientID: "desktop-1",
            signingKeyID: "k1",
            signingPublicKeyBase64: "cHVi",
            noiseKeyID: "n1",
            noisePublicKeyBase64: "bm9pc2U=",
            trustLevel: .platformBound,
            teamID: "TEAM123456",
            signingIdentifier: "com.oches.desktop",
            allowedWorkspaces: ["ws-1"],
            allowedScopes: [PermissionScope.workspaceRead.rawValue, PermissionScope.runRequest.rawValue, PermissionScope.approvalDecide.rawValue],
            status: .active,
            policyVersion: 1,
            createdAt: 1000,
            expiresAt: 5000,
            revokedAt: nil
        ))

        let rev0 = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "1")
        try store.executeRawForTesting(
            "INSERT INTO operational_state (object_id, workspace_id, owner_module, revision, state_json, updated_at) VALUES ('task-1', 'ws-1', 'ARC-07', 1, '{\"state\":\"Prepared\"}', 1000)"
        )

        let execBinding = ApprovalBinding(
            runID: "run-1",
            taskRevision: rev0,
            preparedAttemptID: "att-1",
            instanceRevision: rev0,
            bindingDigest: "bind-1",
            capabilitySnapshotID: "cap-1",
            executionRequestDigest: "req-digest-1"
        )
        let execApproval = ApprovalRecord(
            approvalID: "app-exec-1",
            kind: .execution,
            subjectClientID: "desktop-1",
            decidedByActorID: "user-1",
            workspaceID: "ws-1",
            normalizedTarget: canonicalTarget,
            allowedScopes: [.runRequest],
            binding: execBinding,
            policyVersion: 1,
            issuedAt: 1000,
            expiresAt: 2000,
            status: .approved
        )
        try enforcer.recordApproval(execApproval, decidedByTrustedUI: true)

        // Untrusted UI cannot issue approval
        XCTAssertThrowsError(try enforcer.recordApproval(execApproval, decidedByTrustedUI: false)) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .denied)
        }

        // 1. Symlink escape outside workspace rejected
        let symlinkEscape = wsRoot.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: symlinkEscape, withDestinationURL: outsideFile)
        try enforcer.issueNonce(nonceID: "n-esc", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 2000)
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(AuthorizedExecutionInput(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            nonceID: "n-esc",
            workspaceID: "ws-1",
            workspaceRootPath: wsRoot.path,
            candidateTargetPath: symlinkEscape.path,
            requiredScope: .runRequest,
            operation: "run.start",
            requestID: "req-esc",
            objectID: "task-1",
            expectedRevision: rev0,
            preparedAttemptID: "att-1",
            requestDigest: "req-digest-1",
            executionApprovalID: "app-exec-1",
            normalizedInput: .object([("op", .string("esc"))]),
            nextStateJSON: "{\"state\":\"Running\"}",
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: 1100
        ))) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .denied)
        }

        // 2. Post-approval path change rejected with CONFLICT
        try enforcer.issueNonce(nonceID: "n-path", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 2000)
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(AuthorizedExecutionInput(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            nonceID: "n-path",
            workspaceID: "ws-1",
            workspaceRootPath: wsRoot.path,
            candidateTargetPath: otherFile.path,
            requiredScope: .runRequest,
            operation: "run.start",
            requestID: "req-path",
            objectID: "task-1",
            expectedRevision: rev0,
            preparedAttemptID: "att-1",
            requestDigest: "req-digest-1",
            executionApprovalID: "app-exec-1",
            normalizedInput: .object([("op", .string("path"))]),
            nextStateJSON: "{\"state\":\"Running\"}",
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: 1100
        ))) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .conflict)
        }

        // 3. Reusing execution approval for a different attemptId rejected
        try enforcer.issueNonce(nonceID: "n-att2", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 2000)
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(AuthorizedExecutionInput(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            nonceID: "n-att2",
            workspaceID: "ws-1",
            workspaceRootPath: wsRoot.path,
            candidateTargetPath: targetFile.path,
            requiredScope: .runRequest,
            operation: "run.start",
            requestID: "req-att2",
            objectID: "task-1",
            expectedRevision: rev0,
            preparedAttemptID: "att-2",
            requestDigest: "req-digest-1",
            executionApprovalID: "app-exec-1",
            normalizedInput: .object([("op", .string("att2"))]),
            nextStateJSON: "{\"state\":\"Running\"}",
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: 1100
        ))) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .denied)
        }

        // 4. Missing externalTransfer approval when transfer is required -> APPROVAL_REQUIRED (FC-03)
        try enforcer.issueNonce(nonceID: "n-xfer", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 2000)
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(AuthorizedExecutionInput(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            nonceID: "n-xfer",
            workspaceID: "ws-1",
            workspaceRootPath: wsRoot.path,
            candidateTargetPath: targetFile.path,
            requiredScope: .runRequest,
            operation: "run.start",
            requestID: "req-xfer",
            objectID: "task-1",
            expectedRevision: rev0,
            preparedAttemptID: "att-1",
            requestDigest: "req-digest-1",
            executionApprovalID: "app-exec-1",
            transferApprovalID: nil,
            requiresExternalTransfer: true,
            normalizedInput: .object([("op", .string("xfer"))]),
            nextStateJSON: "{\"state\":\"Running\"}",
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: 1100
        ))) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .approvalRequired)
        }

        // 5. Expired approval rejected
        try enforcer.issueNonce(nonceID: "n-exp", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 3000)
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(AuthorizedExecutionInput(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            nonceID: "n-exp",
            workspaceID: "ws-1",
            workspaceRootPath: wsRoot.path,
            candidateTargetPath: targetFile.path,
            requiredScope: .runRequest,
            operation: "run.start",
            requestID: "req-exp",
            objectID: "task-1",
            expectedRevision: rev0,
            preparedAttemptID: "att-1",
            requestDigest: "req-digest-1",
            executionApprovalID: "app-exec-1",
            normalizedInput: .object([("op", .string("exp"))]),
            nextStateJSON: "{\"state\":\"Running\"}",
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: 2500
        ))) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .denied)
        }

        // 6. Audit write failure rolls back entire tx (state & approval remain unconsumed)
        try enforcer.issueNonce(nonceID: "n-audit-fail", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 2000)
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(AuthorizedExecutionInput(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            nonceID: "n-audit-fail",
            workspaceID: "ws-1",
            workspaceRootPath: wsRoot.path,
            candidateTargetPath: targetFile.path,
            requiredScope: .runRequest,
            operation: "run.start",
            requestID: "req-audit-fail",
            objectID: "task-1",
            expectedRevision: rev0,
            preparedAttemptID: "att-1",
            requestDigest: "req-digest-1",
            executionApprovalID: "app-exec-1",
            normalizedInput: .object([("op", .string("ok"))]),
            nextStateJSON: "{\"state\":\"Running\"}",
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: 1100,
            injectAuditFailure: true
        ))) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .unavailable)
        }
        XCTAssertEqual(try store.readSnapshot(workspaceID: "ws-1", objectID: "task-1").revision.revision, "1")

        // 7. Concurrent TOCTOU race with same single-use approval -> exactly one succeeds
        let transferBinding = ApprovalBinding(
            providerID: "claude",
            accountRef: "acct-1",
            recipientScope: "anthropic",
            contextSelectionRevision: rev0,
            inputDigest: "ctx-1",
            transferPurpose: "run",
            dataScope: "subset"
        )
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: "app-xfer-1",
            kind: .externalTransfer,
            subjectClientID: "desktop-1",
            decidedByActorID: "user-1",
            workspaceID: "ws-1",
            normalizedTarget: canonicalTarget,
            allowedScopes: [.runRequest],
            binding: transferBinding,
            policyVersion: 1,
            issuedAt: 1000,
            expiresAt: 2000,
            status: .approved
        ), decidedByTrustedUI: true)

        try enforcer.issueNonce(nonceID: "n-race-0", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 2000)
        try enforcer.issueNonce(nonceID: "n-race-1", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 2000)

        final class LockedBox<T>: @unchecked Sendable {
            private let lock = NSLock()
            var value: T
            init(_ value: T) { self.value = value }
            func withLock(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
        }
        let raceBox = LockedBox<[String]>([])
        let raceGroup = DispatchGroup()
        for idx in 0..<2 {
            raceGroup.enter()
            DispatchQueue.global().async {
                defer { raceGroup.leave() }
                do {
                    let s = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
                    let enf = try AuthorizationEnforcer(store: s)
                    let res = try enf.authorizeAndCommitExecution(AuthorizedExecutionInput(
                        actorID: "user-1",
                        clientID: "desktop-1",
                        keyID: "k1",
                        nonceID: "n-race-\(idx)",
                        workspaceID: "ws-1",
                        workspaceRootPath: wsRoot.path,
                        candidateTargetPath: targetFile.path,
                        requiredScope: .runRequest,
                        operation: "run.start",
                        requestID: "req-race-\(idx)",
                        objectID: "task-1",
                        expectedRevision: rev0,
                        preparedAttemptID: "att-1",
                        requestDigest: "req-digest-1",
                        executionApprovalID: "app-exec-1",
                        transferApprovalID: "app-xfer-1",
                        requiresExternalTransfer: true,
                        normalizedInput: .object([("race", .number(String(idx)))]),
                        nextStateJSON: "{\"state\":\"Running\"}",
                        responseJSON: "{\"started\":true}",
                        nowEpochSeconds: 1100
                    ))
                    raceBox.withLock { $0.append("OK:\(res.revision.revision)") }
                } catch {
                    raceBox.withLock { $0.append("ERR") }
                }
            }
        }
        raceGroup.wait()
        XCTAssertEqual(raceBox.value.filter { $0 == "OK:2" }.count, 1)
        XCTAssertEqual(raceBox.value.filter { $0 == "ERR" }.count, 1)

        // 8. Lost-response retry with fresh nonce vs replayed nonce
        let winningReqID = try XCTUnwrap(
            try enforcer.listAuditLogs(workspaceID: "ws-1").first(where: { $0.decision == "ALLOW" })?.requestID
        )
        try enforcer.issueNonce(nonceID: "n-retry-1", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "retry", expiresAt: 2000)
        let retried = try enforcer.retryRetrieveResultWithFreshNonce(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            freshNonceID: "n-retry-1",
            workspaceID: "ws-1",
            operation: "run.start",
            requestID: winningReqID,
            nowEpochSeconds: 1200
        )
        XCTAssertTrue(retried.idempotentReplay)
        XCTAssertEqual(retried.responseJSON, "{\"started\":true}")

        // Replaying the same fresh nonce fails
        XCTAssertThrowsError(try enforcer.retryRetrieveResultWithFreshNonce(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            freshNonceID: "n-retry-1",
            workspaceID: "ws-1",
            operation: "run.start",
            requestID: winningReqID,
            nowEpochSeconds: 1201
        )) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .denied)
        }

        // 9. Approval revocation blocks new execution
        let rev2 = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "2")
        let revokable = ApprovalRecord(
            approvalID: "app-revoke-1",
            kind: .execution,
            subjectClientID: "desktop-1",
            decidedByActorID: "user-1",
            workspaceID: "ws-1",
            normalizedTarget: canonicalTarget,
            allowedScopes: [.runRequest],
            binding: execBinding,
            policyVersion: 1,
            issuedAt: 1000,
            expiresAt: 2000,
            status: .approved
        )
        try enforcer.recordApproval(revokable, decidedByTrustedUI: true)
        try enforcer.revokeApproval(approvalID: "app-revoke-1", nowEpochSeconds: 1250)
        try enforcer.issueNonce(nonceID: "n-revoked", clientID: "desktop-1", keyID: "k1", workspaceID: "ws-1", purpose: "exec", expiresAt: 2000)
        XCTAssertThrowsError(try enforcer.authorizeAndCommitExecution(AuthorizedExecutionInput(
            actorID: "user-1",
            clientID: "desktop-1",
            keyID: "k1",
            nonceID: "n-revoked",
            workspaceID: "ws-1",
            workspaceRootPath: wsRoot.path,
            candidateTargetPath: targetFile.path,
            requiredScope: .runRequest,
            operation: "run.start",
            requestID: "req-revoked",
            objectID: "task-1",
            expectedRevision: rev2,
            preparedAttemptID: "att-1",
            requestDigest: "req-digest-1",
            executionApprovalID: "app-revoke-1",
            normalizedInput: .object([("op", .string("revoked"))]),
            nextStateJSON: "{\"state\":\"Running\"}",
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: 1260
        ))) { error in
            XCTAssertEqual((error as? AuthorizationError)?.safeWireError.code, .denied)
        }
    }
}
