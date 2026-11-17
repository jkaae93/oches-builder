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

    private func recordExecutionApproval(
        enforcer: AuthorizationEnforcer,
        approvalID: String,
        attemptID: String,
        runID: String,
        rev: RevisionRef,
        requestDigest: String
    ) throws {
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: approvalID,
            kind: .execution,
            subjectClientID: "desktop-1",
            decidedByActorID: "user-1",
            workspaceID: "ws-1",
            normalizedTarget: "/tmp/ws",
            allowedScopes: [.runRequest],
            binding: ApprovalBinding(
                runID: runID,
                taskRevision: rev,
                preparedAttemptID: attemptID,
                instanceRevision: rev,
                bindingDigest: "bind-1",
                capabilitySnapshotID: "snap-1",
                executionRequestDigest: requestDigest
            ),
            policyVersion: 1,
            issuedAt: 900,
            expiresAt: 5000,
            status: .approved
        ), decidedByTrustedUI: true)
    }

    func testMockSupervisorCrashPIDReuseCancelRacesOutputLossAndResume() throws {
        let dbPath = tempDir.appendingPathComponent("supervisor.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let enforcer = try AuthorizationEnforcer(store: store)
        let gate = try RuntimePrepareAndStartGate(store: store)
        let adapter = MockRuntimeAdapter()
        let manager = RuntimeSessionManager(store: store, gate: gate, adapter: adapter)
        let (snap, scope) = makeVerifiedSnapshot(accountIsolation: .supported)
        let rev = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "1")

        // 1. Crash before spawn confirmation -> attempt Unknown, task Blocked, duplicate retry spawns 0
        adapter.setBehavior(.crashBeforeSpawnConfirmation, forAttemptID: "att-crash-1")
        _ = try manager.prepare(PrepareAttemptInput(
            attemptID: "att-crash-1", workspaceID: "ws-1", runID: "run-1", taskID: "task-crash-1",
            taskRevision: rev, instanceRevision: rev, installationID: "inst-mock", accountRef: "acct-mock",
            bindingDigest: "bind-1", executionRequestDigest: "dig-1", callerScopes: [.runRequest],
            snapshot: snap, requestedScope: scope
        ))
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-c1", attemptID: "att-crash-1", runID: "run-1", rev: rev, requestDigest: "dig-1")
        let crash1 = try manager.start(StartAttemptInput(
            attemptID: "att-crash-1", requestID: "req-c1", actorID: "user-1", clientID: "desktop-1",
            executionApprovalID: "app-c1", snapshot: snap, requestedScope: scope, nowEpochSeconds: 1000
        ))
        XCTAssertEqual(crash1.state, .unknown)
        XCTAssertEqual(try manager.inspect(attemptID: "att-crash-1").taskState, .blocked)
        let spawnsBeforeRetry = adapter.spawnCallCount
        let retryCrash = try manager.start(StartAttemptInput(
            attemptID: "att-crash-1", requestID: "req-c1", actorID: "user-1", clientID: "desktop-1",
            executionApprovalID: "app-c1", snapshot: snap, requestedScope: scope, nowEpochSeconds: 1001
        ))
        XCTAssertEqual(retryCrash.state, .unknown)
        XCTAssertEqual(adapter.spawnCallCount, spawnsBeforeRetry)

        // Resume from Unknown is strictly rejected (0 auto-restarts)
        XCTAssertThrowsError(try manager.prepareResume(
            previousAttemptID: "att-crash-1",
            newPrepareInput: PrepareAttemptInput(
                attemptID: "att-resume-bad", workspaceID: "ws-1", runID: "run-1", taskID: "task-crash-1",
                taskRevision: rev, instanceRevision: rev, installationID: "inst-mock", accountRef: "acct-mock",
                bindingDigest: "bind-1", executionRequestDigest: "dig-1", callerScopes: [.runRequest],
                snapshot: snap, requestedScope: scope
            )
        )) { error in
            guard case .resumeUnsupported = error as? RuntimeLifecycleError else {
                return XCTFail("Expected resumeUnsupported from Unknown state, got \(error)")
            }
        }

        // 2. PID reuse during Running -> reconcileOnRestart marks attempt Unknown & task Blocked
        adapter.setBehavior(.succeedNormally, forAttemptID: "att-pid-reuse")
        _ = try manager.prepare(PrepareAttemptInput(
            attemptID: "att-pid-reuse", workspaceID: "ws-1", runID: "run-1", taskID: "task-pid-reuse",
            taskRevision: rev, instanceRevision: rev, installationID: "inst-mock", accountRef: "acct-mock",
            bindingDigest: "bind-1", executionRequestDigest: "dig-pid", callerScopes: [.runRequest],
            snapshot: snap, requestedScope: scope
        ))
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-pid", attemptID: "att-pid-reuse", runID: "run-1", rev: rev, requestDigest: "dig-pid")
        let running = try manager.start(StartAttemptInput(
            attemptID: "att-pid-reuse", requestID: "req-pid", actorID: "user-1", clientID: "desktop-1",
            executionApprovalID: "app-pid", snapshot: snap, requestedScope: scope, nowEpochSeconds: 1010
        ))
        XCTAssertEqual(running.state, .running)
        let reusedPID = try XCTUnwrap(running.pid)
        adapter.simulatePIDReuse(pid: reusedPID, newToken: "unrelated-process-token", otherAttemptID: "other-app")

        _ = try manager.reconcileOnRestart(nowEpochSeconds: 1020)
        let inspectedAfterReuse = try manager.inspect(attemptID: "att-pid-reuse")
        XCTAssertEqual(inspectedAfterReuse.attempt.state, .unknown)
        XCTAssertEqual(inspectedAfterReuse.taskState, .blocked)

        // 3. C04: Cancel during Starting before spawn confirmation -> CancelRequested -> spawn_confirmed -> Cancelled
        adapter.setBehavior(.delaySpawnUntilCancelRace, forAttemptID: "att-start-cancel")
        adapter.setCancelRaceOutcome(cancelWins: true, forAttemptID: "att-start-cancel")
        _ = try manager.prepare(PrepareAttemptInput(
            attemptID: "att-start-cancel", workspaceID: "ws-1", runID: "run-1", taskID: "task-start-cancel",
            taskRevision: rev, instanceRevision: rev, installationID: "inst-mock", accountRef: "acct-mock",
            bindingDigest: "bind-1", executionRequestDigest: "dig-sc", callerScopes: [.runRequest],
            snapshot: snap, requestedScope: scope
        ))
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-sc", attemptID: "att-start-cancel", runID: "run-1", rev: rev, requestDigest: "dig-sc")
        let starting = try manager.start(StartAttemptInput(
            attemptID: "att-start-cancel", requestID: "req-sc", actorID: "user-1", clientID: "desktop-1",
            executionApprovalID: "app-sc", snapshot: snap, requestedScope: scope, nowEpochSeconds: 1030
        ))
        XCTAssertEqual(starting.state, .starting)
        let cancelPending = try manager.cancel(attemptID: "att-start-cancel", resolveImmediatelyIfRunning: false, nowEpochSeconds: 1031)
        XCTAssertEqual(cancelPending.state, .cancelRequested)
        let cancelledAfterSpawn = try manager.confirmDelayedSpawn(attemptID: "att-start-cancel", nowEpochSeconds: 1032)
        XCTAssertEqual(cancelledAfterSpawn.state, .cancelled)
        XCTAssertEqual(try manager.inspect(attemptID: "att-start-cancel").taskState, .cancelled)

        // 4. V-07 / X12: Cancel during Running racing with normal exit -> Succeeded (Task Evaluating)
        adapter.setBehavior(.succeedNormally, forAttemptID: "att-race-exit")
        adapter.setCancelRaceOutcome(cancelWins: false, forAttemptID: "att-race-exit")
        _ = try manager.prepare(PrepareAttemptInput(
            attemptID: "att-race-exit", workspaceID: "ws-1", runID: "run-1", taskID: "task-race-exit",
            taskRevision: rev, instanceRevision: rev, installationID: "inst-mock", accountRef: "acct-mock",
            bindingDigest: "bind-1", executionRequestDigest: "dig-race", callerScopes: [.runRequest],
            snapshot: snap, requestedScope: scope
        ))
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-race", attemptID: "att-race-exit", runID: "run-1", rev: rev, requestDigest: "dig-race")
        _ = try manager.start(StartAttemptInput(
            attemptID: "att-race-exit", requestID: "req-race", actorID: "user-1", clientID: "desktop-1",
            executionApprovalID: "app-race", snapshot: snap, requestedScope: scope, nowEpochSeconds: 1040
        ))
        let raceWin = try manager.cancel(attemptID: "att-race-exit", resolveImmediatelyIfRunning: true, nowEpochSeconds: 1041)
        XCTAssertEqual(raceWin.state, .succeeded)
        XCTAssertEqual(try manager.inspect(attemptID: "att-race-exit").taskState, .evaluating)

        // 5. Output loss / truncation explicitly reported in observe without fabricating missing events
        adapter.setBehavior(.emitEventsWithOutputLoss(emittedCount: 2, droppedCount: 3, truncated: true), forAttemptID: "att-loss")
        _ = try manager.prepare(PrepareAttemptInput(
            attemptID: "att-loss", workspaceID: "ws-1", runID: "run-1", taskID: "task-loss",
            taskRevision: rev, instanceRevision: rev, installationID: "inst-mock", accountRef: "acct-mock",
            bindingDigest: "bind-1", executionRequestDigest: "dig-loss", callerScopes: [.runRequest],
            snapshot: snap, requestedScope: scope
        ))
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-loss", attemptID: "att-loss", runID: "run-1", rev: rev, requestDigest: "dig-loss")
        _ = try manager.start(StartAttemptInput(
            attemptID: "att-loss", requestID: "req-loss", actorID: "user-1", clientID: "desktop-1",
            executionApprovalID: "app-loss", snapshot: snap, requestedScope: scope, nowEpochSeconds: 1050
        ))
        _ = try manager.completeProcessNormally(attemptID: "att-loss", nowEpochSeconds: 1055)
        let obs = try manager.observe(attemptID: "att-loss")
        XCTAssertTrue(obs.outputTruncated)
        XCTAssertEqual(obs.droppedEventsCount, 3)
        XCTAssertEqual(obs.events.filter { $0.kind == "output.chunk" }.count, 2)

        // 6. CV09: Resume from confirmed terminal state reserves a new Prepared attempt requiring fresh approval
        let resumedPrepared = try manager.prepareResume(
            previousAttemptID: "att-loss",
            newPrepareInput: PrepareAttemptInput(
                attemptID: "att-resumed-2", workspaceID: "ws-1", runID: "run-1", taskID: "task-loss",
                taskRevision: rev, instanceRevision: rev, installationID: "inst-mock", accountRef: "acct-mock",
                bindingDigest: "bind-1", executionRequestDigest: "dig-resumed-2", callerScopes: [.runRequest],
                snapshot: snap, requestedScope: scope
            )
        )
        XCTAssertEqual(resumedPrepared.state, .prepared)
    }
}
