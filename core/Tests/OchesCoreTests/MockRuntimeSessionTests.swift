import Foundation
import XCTest
@testable import OchesCore

final class MockRuntimeSessionTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDirectory("runtime-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func makeVerifiedSnapshot(accountIsolation: CapabilityStatus = .supported) -> (CapabilitySnapshot, CapabilityScope) {
        let scope = CapabilityScope(
            installationID: "inst-mock",
            executableIdentity: "sha256:mock",
            cliVersion: "1.0.0",
            adapterVersion: "1.0.0",
            osVersionArch: "macOS-26.4-arm64",
            accountRef: "acct-mock",
            accountType: .apiKey,
            workspaceID: "ws-1",
            workspaceLocationAuthority: "local",
            workspaceTrust: true,
            clientID: "desktop-1",
            clientKind: "desktop",
            negotiatedProtocolMajorMinor: "1.0",
            policyVersion: 1
        )
        let entries = CapabilityID.allCases.map { cap -> CapabilityEntry in
            let status: CapabilityStatus = (cap == .authAccountIsolation) ? accountIsolation : .supported
            return CapabilityEntry(capabilityID: cap, status: status, basis: .verifiedInOches, evidenceRef: "mock-test", observedAt: 1000)
        }
        return (CapabilitySnapshot(snapshotID: "snap-1", scope: scope, entries: entries, observedAt: 1000), scope)
    }

    func testLifecycleStateMachineAndTerminalImmutability() throws {
        // Valid cancel race then normal exit succeeds
        var s: ExecutionAttemptState = .prepared
        s = try transitionAttemptState(from: s, event: .startRecorded)
        s = try transitionAttemptState(from: s, event: .spawnConfirmed)
        s = try transitionAttemptState(from: s, event: .cancelRequested)
        s = try transitionAttemptState(from: s, event: .normalExitConfirmed)
        XCTAssertEqual(s, .succeeded)
        XCTAssertEqual(derivedTaskState(for: s), .evaluating)

        // Cancel before spawn
        XCTAssertEqual(try transitionAttemptState(from: .prepared, event: .cancelBeforeSpawn), .cancelled)

        // Starting -> CancelRequested -> spawn_confirmed stays CancelRequested
        var s2 = try transitionAttemptState(from: .prepared, event: .startRecorded)
        s2 = try transitionAttemptState(from: s2, event: .cancelRequested)
        s2 = try transitionAttemptState(from: s2, event: .spawnConfirmed)
        XCTAssertEqual(s2, .cancelRequested)

        // Unknown blocks retry, startRecorded, successAssumed; only resolves on confirmed process observation
        var unk = try transitionAttemptState(from: .prepared, event: .startRecorded)
        unk = try transitionAttemptState(from: unk, event: .spawnOutcomeUnknown)
        XCTAssertEqual(unk, .unknown)
        XCTAssertEqual(derivedTaskState(for: unk), .blocked)
        XCTAssertThrowsError(try transitionAttemptState(from: unk, event: .retry))
        XCTAssertThrowsError(try transitionAttemptState(from: unk, event: .startRecorded))
        XCTAssertThrowsError(try transitionAttemptState(from: unk, event: .successAssumed))
        XCTAssertEqual(try transitionAttemptState(from: unk, event: .liveProcessIdentityConfirmed), .running)

        // app_exit never transitions active/unknown attempts to terminal
        for state in [ExecutionAttemptState.starting, .running, .cancelRequested, .unknown] {
            XCTAssertThrowsError(try transitionAttemptState(from: state, event: .appExit))
        }

        // All terminal states are strictly immutable
        for term in [ExecutionAttemptState.succeeded, .failed, .cancelled, .interrupted] {
            for ev in RuntimeObservationEvent.allCases {
                XCTAssertThrowsError(try transitionAttemptState(from: term, event: ev))
            }
        }
    }

    func testPrepareReservationAndStartPreSpawnApprovalTransferAndStorageGates() throws {
        let dbPath = tempDir.appendingPathComponent("runtime.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let enforcer = try AuthorizationEnforcer(store: store)
        let gate = try RuntimePrepareAndStartGate(store: store)
        let (snap, scope) = makeVerifiedSnapshot()
        let rev = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "1")

        // Prepare reserves attempt without execution approval
        let prepared = try gate.prepare(PrepareAttemptInput(
            attemptID: "att-1",
            workspaceID: "ws-1",
            runID: "run-1",
            taskID: "task-1",
            taskRevision: rev,
            instanceRevision: rev,
            installationID: "inst-mock",
            accountRef: "acct-mock",
            bindingDigest: "bind-1",
            executionRequestDigest: "req-digest-1",
            callerScopes: [.runRequest],
            snapshot: snap,
            requestedScope: scope
        ))
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertNil(prepared.pid)
        XCTAssertEqual(try gate.fetchTaskState(taskID: "task-1"), .prepared)

        // Start without valid execution approval blocked
        XCTAssertThrowsError(try gate.commitPreSpawnStart(StartAttemptInput(
            attemptID: "att-1",
            requestID: "req-start-1",
            actorID: "user-1",
            clientID: "desktop-1",
            executionApprovalID: "missing-app",
            snapshot: snap,
            requestedScope: scope,
            nowEpochSeconds: 1000
        ))) { error in
            XCTAssertEqual(error as? RuntimeLifecycleError, .approvalRequired([.execution]))
        }

        // Record execution approval bound to att-1
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: "app-exec-1",
            kind: .execution,
            subjectClientID: "desktop-1",
            decidedByActorID: "user-1",
            workspaceID: "ws-1",
            normalizedTarget: "/tmp/ws",
            allowedScopes: [.runRequest],
            binding: ApprovalBinding(
                runID: "run-1",
                taskRevision: rev,
                preparedAttemptID: "att-1",
                instanceRevision: rev,
                bindingDigest: "bind-1",
                capabilitySnapshotID: "snap-1",
                executionRequestDigest: "req-digest-1"
            ),
            policyVersion: 1,
            issuedAt: 900,
            expiresAt: 2000,
            status: .approved
        ), decidedByTrustedUI: true)

        // Missing external transfer approval when transfer required -> blocked (FC-03)
        XCTAssertThrowsError(try gate.commitPreSpawnStart(StartAttemptInput(
            attemptID: "att-1",
            requestID: "req-start-xfer",
            actorID: "user-1",
            clientID: "desktop-1",
            executionApprovalID: "app-exec-1",
            transferApprovalID: nil,
            requiresExternalTransfer: true,
            snapshot: snap,
            requestedScope: scope,
            nowEpochSeconds: 1000
        ))) { error in
            XCTAssertEqual(error as? RuntimeLifecycleError, .approvalRequired([.externalTransfer]))
        }

        // Valid start transitions Prepared -> Starting and returns shouldSpawn = true
        let started = try gate.commitPreSpawnStart(StartAttemptInput(
            attemptID: "att-1",
            requestID: "req-start-1",
            actorID: "user-1",
            clientID: "desktop-1",
            executionApprovalID: "app-exec-1",
            snapshot: snap,
            requestedScope: scope,
            nowEpochSeconds: 1000
        ))
        XCTAssertTrue(started.shouldSpawn)
        XCTAssertEqual(started.record.state, .starting)
        XCTAssertEqual(try gate.fetchTaskState(taskID: "task-1"), .running)

        // Duplicate start retry with same requestID returns shouldSpawn = false (0 duplicate spawns)
        let dupRetry = try gate.commitPreSpawnStart(StartAttemptInput(
            attemptID: "att-1",
            requestID: "req-start-1",
            actorID: "user-1",
            clientID: "desktop-1",
            executionApprovalID: "app-exec-1",
            snapshot: snap,
            requestedScope: scope,
            nowEpochSeconds: 1001
        ))
        XCTAssertFalse(dupRetry.shouldSpawn)

        // Storage degraded blocks prepare/start (no spawns on storage error)
        store.setHealthStateForTesting(.degraded(reason: "disk full"))
        XCTAssertThrowsError(try gate.prepare(PrepareAttemptInput(
            attemptID: "att-2",
            workspaceID: "ws-1",
            runID: "run-1",
            taskID: "task-2",
            taskRevision: rev,
            instanceRevision: rev,
            installationID: "inst-mock",
            accountRef: "acct-mock",
            bindingDigest: "bind-2",
            executionRequestDigest: "req-digest-2",
            callerScopes: [.runRequest],
            snapshot: snap,
            requestedScope: scope
        )))
    }
}
