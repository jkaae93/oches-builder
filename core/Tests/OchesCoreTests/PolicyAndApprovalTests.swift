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
}
