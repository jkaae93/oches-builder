import Foundation
import Darwin
import XCTest
@testable import OchesCore

final class SchedulerRunRepositoryTests: XCTestCase {
    func testRuntimeReconciliationPreservesUnknownAndRequiresEvaluationAfterExit() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let repository = SchedulerRunRepository(store: store)
        let task = SchedulingTaskSnapshot(taskID: "task", workspaceID: "ws", state: .ready, attemptState: nil,
            enqueueSequence: 1, installationID: "installation", accountRef: "account", isolation: .unknown, exclusiveResourceIDs: [])
        let pins = Data(repeating: 1, count: 32)
        let created = try repository.create(runID: "run", tasks: [task], dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create", now: 100)
        let reserved = try repository.reserve(runID: "run", revision: created.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve", now: 101)
        let reservations = try JSONDecoder().decode([String: String].self, from: Data(reserved.responseJSON.utf8))
        let attemptID = try XCTUnwrap(reservations["task"])
        let gate = try RuntimePrepareAndStartGate(store: store)
        let reference = #"{"objectID":"task","storeGeneration":"gen","revision":"1"}"#
        try store.executeRawForTesting("""
            INSERT INTO execution_attempts (attempt_id, workspace_id, run_id, task_id, task_revision_json,
                instance_revision_json, installation_id, account_ref, binding_digest, execution_request_digest, snapshot_id, state)
            VALUES ('\(attemptID)', 'ws', 'run', 'task', '\(reference)', '\(reference)',
                'installation', 'account', 'fixture-binding', 'fixture-request', 'fixture-snapshot', 'Unknown')
            """)
        let unknown = try repository.observeRuntime(runID: "run", revision: reserved.revision, taskID: "task", gate: gate,
            actorID: "actor", requestID: "unknown", now: 102)
        func state() throws -> String {
            let snapshot = try store.readSnapshot(workspaceID: "ws", objectID: created.revision.objectID)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.stateJSON.utf8)) as? [String: Any])
            return try XCTUnwrap((payload["tasks"] as? [[String: Any]])?.first?["state"] as? String)
        }
        XCTAssertEqual(try state(), "Blocked")
        let noRetry = try repository.reserve(runID: "run", revision: unknown.revision, currentInputPins: pins,
            actorID: "actor", requestID: "no-retry", now: 103)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(noRetry.responseJSON.utf8)).count, 0)
        try store.executeRawForTesting("UPDATE execution_attempts SET state = 'Succeeded' WHERE attempt_id = '\(attemptID)'")
        let exited = try repository.observeRuntime(runID: "run", revision: noRetry.revision, taskID: "task", gate: gate,
            actorID: "actor", requestID: "exited", now: 104)
        XCTAssertEqual(try state(), "Evaluating")
        try store.executeRawForTesting("UPDATE execution_attempts SET task_id = 'other-task' WHERE attempt_id = '\(attemptID)'")
        XCTAssertThrowsError(try repository.observeRuntime(runID: "run", revision: exited.revision, taskID: "task", gate: gate,
            actorID: "actor", requestID: "wrong-task", now: 105))
    }

    func testIndependentProcessesCannotOverreserveWorkspace() throws {
        let pins = Data(repeating: 1, count: 32)
        if let root = ProcessInfo.processInfo.environment["OCHES_SCHEDULER_RACE_ROOT"],
           let runID = ProcessInfo.processInfo.environment["OCHES_SCHEDULER_RACE_RUN"] {
            let repository = SchedulerRunRepository(store: try SQLiteStore(path: root + "/db", workspaceID: "ws"))
            try Data().write(to: URL(fileURLWithPath: root + "/ready-" + runID))
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: root + "/start") {
                if Date() >= deadline { _exit(73) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            do {
                _ = try repository.reserve(runID: runID,
                    revision: RevisionRef(objectID: "arc07/run/" + runID, storeGeneration: "gen", revision: "1"),
                    currentInputPins: pins, actorID: "actor", requestID: "reserve-" + runID, now: 101)
                _exit(71)
            } catch StorageError.busy { _exit(72) }
            catch { _exit(74) }
        }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let repository = SchedulerRunRepository(store: store)
        var processes: [Process] = []
        defer { for process in processes where process.isRunning { process.terminate() } }
        for runID in ["one", "two"] {
            let tasks = (1...4).map { SchedulingTaskSnapshot(taskID: "task-\($0)", workspaceID: "ws", state: .ready,
                attemptState: nil, enqueueSequence: UInt64($0), installationID: "installation", accountRef: runID + "-\($0)",
                isolation: .unknown, exclusiveResourceIDs: []) }
            _ = try repository.create(runID: runID, tasks: tasks, dependencies: [], inputPins: pins,
                actorID: "actor", requestID: "create-" + runID, now: 100)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            process.arguments = ["-XCTest", "OchesCoreTests.SchedulerRunRepositoryTests/testIndependentProcessesCannotOverreserveWorkspace",
                Bundle(for: SchedulerRunRepositoryTests.self).bundlePath]
            var environment = ProcessInfo.processInfo.environment
            environment["OCHES_SCHEDULER_RACE_ROOT"] = directory.path
            environment["OCHES_SCHEDULER_RACE_RUN"] = runID
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            processes.append(process)
        }
        let deadline = Date().addingTimeInterval(10)
        while !["one", "two"].allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready-" + $0).path) }) {
            guard Date() < deadline else { return XCTFail("reservation subprocess readiness timed out") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        try Data().write(to: directory.appendingPathComponent("start"))
        for process in processes { process.waitUntilExit() }
        XCTAssertEqual(processes.map(\.terminationStatus).sorted(), [71, 72])
        var counts: [Int] = []
        for runID in ["one", "two"] {
            let snapshot = try store.readSnapshot(workspaceID: "ws", objectID: "arc07/run/" + runID)
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.stateJSON.utf8)) as? [String: Any])
            counts.append(try XCTUnwrap(record["reservations"] as? [String: String]).count)
        }
        XCTAssertEqual(counts.sorted(), [0, 4])
    }

    func testReservationReplayAndStaleConcurrentRequest() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db").path
        let repository = SchedulerRunRepository(store: try SQLiteStore(path: path, workspaceID: "ws"))
        let tasks = (1...6).map { SchedulingTaskSnapshot(taskID: "task-\($0)", workspaceID: "ws", state: .ready,
            attemptState: nil, enqueueSequence: UInt64($0), installationID: "installation", accountRef: "account-\($0)", isolation: .unknown, exclusiveResourceIDs: []) }
        let pins = Data(repeating: 1, count: 32)
        let created = try repository.create(runID: "run", tasks: tasks, dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create", now: 100)
        let first = try repository.reserve(runID: "run", revision: created.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve", now: 101)
        let reserved = try JSONDecoder().decode([String: String].self, from: Data(first.responseJSON.utf8))
        XCTAssertEqual(reserved.count, 4)
        XCTAssertEqual(Set(reserved.keys), Set(["task-1", "task-2", "task-3", "task-4"]))
        let reopened = SchedulerRunRepository(store: try SQLiteStore(path: path, workspaceID: "ws"))
        let replay = try reopened.reserve(runID: "run", revision: created.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve", now: 102)
        XCTAssertTrue(replay.idempotentReplay)
        XCTAssertEqual(replay.responseJSON, first.responseJSON)
        XCTAssertThrowsError(try reopened.reserve(runID: "run", revision: created.revision, currentInputPins: pins,
            actorID: "actor", requestID: "competing", now: 102))
        XCTAssertThrowsError(try reopened.reserve(runID: "run", revision: first.revision, currentInputPins: Data(repeating: 2, count: 32),
            actorID: "actor", requestID: "changed-plan", now: 102))
        let full = try reopened.reserve(runID: "run", revision: first.revision, currentInputPins: pins,
            actorID: "actor", requestID: "full", now: 103)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(full.responseJSON.utf8)).count, 0)
        let other = try reopened.create(runID: "other-run", tasks: [tasks[5]], dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create-other", now: 104)
        XCTAssertThrowsError(try reopened.reserve(runID: "other-run", revision: other.revision, currentInputPins: pins,
            actorID: "actor", requestID: "workspace-full", now: 105)) { XCTAssertEqual($0 as? StorageError, .busy) }
    }

    func testCrossRunAccountAndResourceConflicts() throws {
        for sharedAccount in [true, false] {
            let directory = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws")
            let repository = SchedulerRunRepository(store: store)
            let pins = Data(repeating: 1, count: 32)
            for index in 1...2 {
                let task = SchedulingTaskSnapshot(taskID: "task", workspaceID: "ws", state: .ready, attemptState: nil,
                    enqueueSequence: UInt64(index), installationID: "installation", accountRef: sharedAccount ? "shared" : "account-\(index)",
                    isolation: .unknown, exclusiveResourceIDs: sharedAccount ? [] : ["canonical-resource"])
                let runID = "run-\(index)"
                let created = try repository.create(runID: runID, tasks: [task], dependencies: [], inputPins: pins,
                    actorID: "actor", requestID: "create-\(index)", now: 100)
                if index == 1 {
                    _ = try repository.reserve(runID: runID, revision: created.revision, currentInputPins: pins, actorID: "actor", requestID: "reserve-1", now: 101)
                } else {
                    XCTAssertThrowsError(try repository.reserve(runID: runID, revision: created.revision, currentInputPins: pins,
                        actorID: "actor", requestID: "reserve-2", now: 101)) { XCTAssertEqual($0 as? StorageError, .busy) }
                    XCTAssertEqual(try store.readSnapshot(workspaceID: "ws", objectID: created.revision.objectID).revision, created.revision)
                }
            }
        }
    }

    private func makeVerifiedSnapshot(
        snapshotID: String = "snap-1",
        workspaceID: String = "ws",
        installationID: String = "installation",
        accountRef: String = "account",
        accountIsolation: CapabilityStatus = .supported
    ) -> (CapabilitySnapshot, CapabilityScope) {
        let scope = CapabilityScope(
            installationID: installationID,
            executableIdentity: "sha256:mock",
            cliVersion: "1.0.0",
            adapterVersion: "1.0.0",
            osVersionArch: "macOS-26.4-arm64",
            accountRef: accountRef,
            accountType: .apiKey,
            workspaceID: workspaceID,
            workspaceLocationAuthority: "local",
            workspaceTrust: true,
            clientID: "desktop-1",
            clientKind: "desktop",
            negotiatedProtocolMajorMinor: "1.0",
            policyVersion: 1
        )
        let entries = CapabilityID.allCases.map { cap -> CapabilityEntry in
            let status: CapabilityStatus = (cap == .authAccountIsolation) ? accountIsolation : .supported
            return CapabilityEntry(capabilityID: cap, status: status, basis: .verifiedInOches, evidenceRef: "scheduler-test", observedAt: 100)
        }
        return (CapabilitySnapshot(snapshotID: snapshotID, scope: scope, entries: entries, observedAt: 100), scope)
    }

    private func recordExecutionApproval(
        enforcer: AuthorizationEnforcer,
        approvalID: String,
        runID: String,
        binding: PreparedTaskBinding,
        workspaceID: String = "ws",
        issuedAt: Int64 = 50,
        expiresAt: Int64 = 5000
    ) throws {
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: approvalID,
            kind: .execution,
            subjectClientID: "desktop-1",
            decidedByActorID: "actor",
            workspaceID: workspaceID,
            normalizedTarget: "/tmp/ws",
            allowedScopes: [.runRequest],
            binding: ApprovalBinding(
                runID: runID,
                taskRevision: binding.taskRevision,
                preparedAttemptID: binding.attemptID,
                instanceRevision: binding.instanceRevision,
                bindingDigest: binding.bindingDigest,
                capabilitySnapshotID: binding.capabilitySnapshotID,
                executionRequestDigest: binding.executionRequestDigest
            ),
            policyVersion: 1,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            status: .approved
        ), decidedByTrustedUI: true)
    }

    private func recordTransferApproval(
        enforcer: AuthorizationEnforcer,
        approvalID: String,
        accountRef: String,
        workspaceID: String = "ws",
        storeGeneration: String = "gen",
        issuedAt: Int64 = 50,
        expiresAt: Int64 = 5000
    ) throws {
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: approvalID,
            kind: .externalTransfer,
            subjectClientID: "desktop-1",
            decidedByActorID: "actor",
            workspaceID: workspaceID,
            normalizedTarget: "/tmp/ws",
            allowedScopes: [.runRequest],
            binding: ApprovalBinding(
                providerID: "mock",
                accountRef: accountRef,
                recipientScope: "mock-remote",
                contextSelectionRevision: RevisionRef(objectID: "ctx-1", storeGeneration: storeGeneration, revision: "1"),
                inputDigest: "ctx-digest-1",
                transferPurpose: "task.run",
                dataScope: "workspace-subset"
            ),
            policyVersion: 1,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            status: .approved
        ), decidedByTrustedUI: true)
    }

    func testPartialWorkspaceCapacityAndCrossRunTaskNamespacing() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        _ = try AuthorizationEnforcer(store: store)
        let gate = try RuntimePrepareAndStartGate(store: store)
        let adapter = MockRuntimeAdapter()
        let repository = SchedulerRunRepository(store: store)
        let pins = Data(repeating: 1, count: 32)
        let (snap, scope) = makeVerifiedSnapshot(accountIsolation: .supported)

        let runATasks = (1...2).map {
            SchedulingTaskSnapshot(taskID: "task-\($0)", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: UInt64($0), installationID: "installation", accountRef: "account",
                isolation: .supported, exclusiveResourceIDs: [])
        }
        let runBTasks = (1...4).map {
            SchedulingTaskSnapshot(taskID: "task-\($0)", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: UInt64(10 + $0), installationID: "installation", accountRef: "account",
                isolation: .supported, exclusiveResourceIDs: [])
        }

        let createdA = try repository.create(runID: "run-a", tasks: runATasks, dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create-a", now: 100)
        let reservedA = try repository.reserve(runID: "run-a", revision: createdA.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-a", now: 101)
        let mapA = try JSONDecoder().decode([String: String].self, from: Data(reservedA.responseJSON.utf8))
        XCTAssertEqual(Set(mapA.keys), Set(["task-1", "task-2"]))

        let createdB = try repository.create(runID: "run-b", tasks: runBTasks, dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create-b", now: 102)
        let reservedB = try repository.reserve(runID: "run-b", revision: createdB.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-b", now: 103)
        let mapB = try JSONDecoder().decode([String: String].self, from: Data(reservedB.responseJSON.utf8))
        XCTAssertEqual(Set(mapB.keys), Set(["task-1", "task-2"]))

        let prepA = try repository.prepareAttempt(
            runID: "run-a", revision: reservedA.revision, taskID: "task-1", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
            executionRequestPayloadDigest: "payload-a-1", gate: gate, actorID: "actor", requestID: "prep-a-1", now: 104
        )
        let prepB = try repository.prepareAttempt(
            runID: "run-b", revision: reservedB.revision, taskID: "task-1", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
            executionRequestPayloadDigest: "payload-b-1", gate: gate, actorID: "actor", requestID: "prep-b-1", now: 105
        )
        XCTAssertEqual(prepA.binding.runtimeTaskID, "arc07/run/run-a/task/task-1")
        XCTAssertEqual(prepB.binding.runtimeTaskID, "arc07/run/run-b/task/task-1")
        XCTAssertNotEqual(prepA.binding.runtimeTaskID, prepB.binding.runtimeTaskID)
        XCTAssertEqual(try gate.fetchAttempt(attemptID: prepA.binding.attemptID).taskID, prepA.binding.runtimeTaskID)
        XCTAssertEqual(try gate.fetchAttempt(attemptID: prepB.binding.attemptID).taskID, prepB.binding.runtimeTaskID)
        XCTAssertEqual(try gate.fetchTaskState(taskID: prepA.binding.runtimeTaskID), .prepared)
        XCTAssertEqual(try gate.fetchTaskState(taskID: prepB.binding.runtimeTaskID), .prepared)
        XCTAssertEqual(adapter.spawnCallCount, 0)
    }

    func testFullPrepareApproveStartCancelRaceV07AndV09() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let enforcer = try AuthorizationEnforcer(store: store)
        let gate = try RuntimePrepareAndStartGate(store: store)
        let adapter = MockRuntimeAdapter()
        let manager = RuntimeSessionManager(store: store, gate: gate, adapter: adapter)
        let repository = SchedulerRunRepository(store: store)
        let pins = Data(repeating: 1, count: 32)
        let (snap, scope) = makeVerifiedSnapshot(accountIsolation: .supported)
        let instanceRev = RevisionRef(objectID: "inst-1", storeGeneration: "gen", revision: "1")

        let tasks = [
            SchedulingTaskSnapshot(taskID: "task-a", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 1, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
            SchedulingTaskSnapshot(taskID: "task-b", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 2, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
            SchedulingTaskSnapshot(taskID: "task-c", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 3, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
        ]
        let deps = [TaskDependency(predecessor: "task-a", successor: "task-c")]

        let created = try repository.create(runID: "run-main", tasks: tasks, dependencies: deps, inputPins: pins,
            instanceRevision: instanceRev, actorID: "actor", requestID: "create-main", now: 100)
        let reserved = try repository.reserve(runID: "run-main", revision: created.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-main", now: 101)

        let prepA = try repository.prepareAttempt(
            runID: "run-main", revision: reserved.revision, taskID: "task-a", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
            executionRequestPayloadDigest: "payload-a", gate: gate, actorID: "actor", requestID: "prep-a", now: 102
        )
        let prepB = try repository.prepareAttempt(
            runID: "run-main", revision: prepA.result.revision, taskID: "task-b", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
            executionRequestPayloadDigest: "payload-b", gate: gate, actorID: "actor", requestID: "prep-b", now: 103
        )
        XCTAssertEqual(adapter.spawnCallCount, 0)

        // V-09: Start without approval -> rejected, 0 spawns
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "missing", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-no-app", now: 104
        ))
        XCTAssertEqual(adapter.spawnCallCount, 0)

        // V-09: Wrong instanceRevision, changed planDigest/bindingDigest, wrong capabilitySnapshotID, expired, revoked
        let wrongInstanceBinding = PreparedTaskBinding(
            attemptID: prepA.binding.attemptID, runtimeTaskID: prepA.binding.runtimeTaskID,
            taskRevision: prepA.binding.taskRevision,
            instanceRevision: RevisionRef(objectID: "inst-1", storeGeneration: "gen", revision: "2"),
            bindingDigest: prepA.binding.bindingDigest, executionRequestDigest: prepA.binding.executionRequestDigest,
            capabilitySnapshotID: prepA.binding.capabilitySnapshotID, attemptSequence: 1
        )
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-wrong-inst", runID: "run-main", binding: wrongInstanceBinding)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-wrong-inst", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-wrong-inst", now: 105
        ))
        XCTAssertEqual(adapter.spawnCallCount, 0)

        // Different Run / modified DAG -> different planDigest & bindingDigest
        let otherCreated = try repository.create(runID: "run-changed-dag", tasks: [tasks[0]], dependencies: [], inputPins: pins,
            instanceRevision: instanceRev, actorID: "actor", requestID: "create-other", now: 105)
        let otherReserved = try repository.reserve(runID: "run-changed-dag", revision: otherCreated.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-other", now: 105)
        let otherPrep = try repository.prepareAttempt(
            runID: "run-changed-dag", revision: otherReserved.revision, taskID: "task-a", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
            executionRequestPayloadDigest: "payload-a", gate: gate, actorID: "actor", requestID: "prep-other", now: 105
        )
        XCTAssertNotEqual(otherPrep.binding.bindingDigest, prepA.binding.bindingDigest)
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-changed-dag", runID: "run-changed-dag", binding: otherPrep.binding)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-changed-dag", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-changed-dag", now: 106
        ))
        XCTAssertEqual(adapter.spawnCallCount, 0)

        let wrongBindingDigest = PreparedTaskBinding(
            attemptID: prepA.binding.attemptID, runtimeTaskID: prepA.binding.runtimeTaskID,
            taskRevision: prepA.binding.taskRevision, instanceRevision: prepA.binding.instanceRevision,
            bindingDigest: "tampered-binding-digest", executionRequestDigest: prepA.binding.executionRequestDigest,
            capabilitySnapshotID: prepA.binding.capabilitySnapshotID, attemptSequence: 1
        )
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-wrong-bind", runID: "run-main", binding: wrongBindingDigest)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-wrong-bind", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-wrong-bind", now: 107
        ))

        let wrongSnapBinding = PreparedTaskBinding(
            attemptID: prepA.binding.attemptID, runtimeTaskID: prepA.binding.runtimeTaskID,
            taskRevision: prepA.binding.taskRevision, instanceRevision: prepA.binding.instanceRevision,
            bindingDigest: prepA.binding.bindingDigest, executionRequestDigest: prepA.binding.executionRequestDigest,
            capabilitySnapshotID: "snap-other", attemptSequence: 1
        )
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-wrong-snap", runID: "run-main", binding: wrongSnapBinding)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-wrong-snap", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-wrong-snap", now: 108
        ))

        let (otherSnap, _) = makeVerifiedSnapshot(snapshotID: "snap-other", accountIsolation: .supported)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-wrong-snap", snapshot: otherSnap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-snap-mismatch", now: 108
        ))

        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-expired", runID: "run-main",
            binding: prepA.binding, issuedAt: 50, expiresAt: 100)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-expired", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-expired", now: 109
        ))

        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-revoked", runID: "run-main", binding: prepA.binding)
        try enforcer.revokeApproval(approvalID: "app-revoked", nowEpochSeconds: 109)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-revoked", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-revoked", now: 110
        ))
        XCTAssertEqual(adapter.spawnCallCount, 0)

        // Valid execution approval + transfer checks
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-a-valid", runID: "run-main", binding: prepA.binding)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-a-valid", transferApprovalID: nil,
            requiresExternalTransfer: true, snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-missing-xfer", now: 111
        ))
        try recordTransferApproval(enforcer: enforcer, approvalID: "app-xfer-wrong-acct", accountRef: "other-account")
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-a-valid", transferApprovalID: "app-xfer-wrong-acct",
            requiresExternalTransfer: true, snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-wrong-xfer-acct", now: 112
        ))
        XCTAssertEqual(adapter.spawnCallCount, 0)

        // Re-record valid execution approval since failed attempts roll back consumption; verify with valid transfer approval
        try recordTransferApproval(enforcer: enforcer, approvalID: "app-xfer-valid", accountRef: "account")

        // Task A: C-04 delayed spawn cancel race (cancelWins: true)
        adapter.setBehavior(.delaySpawnUntilCancelRace, forAttemptID: prepA.binding.attemptID)
        adapter.setCancelRaceOutcome(cancelWins: true, forAttemptID: prepA.binding.attemptID)
        let startA = try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-a-valid", transferApprovalID: "app-xfer-valid",
            requiresExternalTransfer: true, snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-a", now: 113
        )
        XCTAssertEqual(startA.attempt.state, .starting)
        XCTAssertEqual(adapter.spawnCallCount, 0)

        // Duplicate startAttempt with same requestID returns idempotentReplay with 0 duplicate spawns
        let replayStartA = try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-a", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-a-valid", transferApprovalID: "app-xfer-valid",
            requiresExternalTransfer: true, snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-a", now: 114
        )
        XCTAssertTrue(replayStartA.result.idempotentReplay)
        XCTAssertEqual(adapter.spawnCallCount, 0)

        // Stale revision on startAttempt with new requestID rejects with versionConflict without consuming approval or spawning
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-b-valid", runID: "run-main", binding: prepB.binding)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-main", revision: prepB.result.revision, taskID: "task-b", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-b-valid", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-b-stale", now: 114
        )) { XCTAssertEqual($0 as? StorageError, .versionConflict) }
        XCTAssertEqual(adapter.spawnCallCount, 0)

        // Cancel Task A while Starting -> CancelRequested (NOT Cancelled yet!) -> delayed spawn -> Cancelled -> task-c blocked
        let cancelA = try repository.cancelTask(
            runID: "run-main", revision: startA.result.revision, taskID: "task-a",
            resolveImmediatelyIfRunning: false, manager: manager, actorID: "actor", requestID: "cancel-a", now: 115
        )
        XCTAssertEqual(cancelA.attempt.state, .cancelRequested)
        let midState = try repository.readRunState(runID: "run-main")
        XCTAssertEqual(midState.tasks.first(where: { $0.taskID == "task-a" })?.state, .running)
        XCTAssertEqual(midState.tasks.first(where: { $0.taskID == "task-a" })?.attemptState, .cancelRequested)

        let delayedConfirm = try manager.confirmDelayedSpawn(attemptID: prepA.binding.attemptID, nowEpochSeconds: 116)
        XCTAssertEqual(delayedConfirm.state, .cancelled)
        let obsA = try repository.observeRuntime(
            runID: "run-main", revision: cancelA.result.revision, taskID: "task-a",
            gate: gate, actorID: "actor", requestID: "obs-a-cancel", now: 117
        )
        let afterCancelA = try repository.readRunState(runID: "run-main")
        XCTAssertEqual(afterCancelA.tasks.first(where: { $0.taskID == "task-a" })?.state, .cancelled)
        let reserveAfterCancel = try repository.reserve(
            runID: "run-main", revision: obsA.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-after-cancel", now: 118
        )
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(reserveAfterCancel.responseJSON.utf8)).count, 0)

        // Task B: V-07 cancel during Running racing normal exit (cancelWins: false) -> Evaluating, never Cancelled/Succeeded
        adapter.setBehavior(.succeedNormally, forAttemptID: prepB.binding.attemptID)
        adapter.setCancelRaceOutcome(cancelWins: false, forAttemptID: prepB.binding.attemptID)
        let startB = try repository.startAttempt(
            runID: "run-main", revision: reserveAfterCancel.revision, taskID: "task-b", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-b-valid", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-b", now: 119
        )
        XCTAssertEqual(startB.attempt.state, .running)
        let cancelRaceB = try repository.cancelTask(
            runID: "run-main", revision: startB.result.revision, taskID: "task-b",
            resolveImmediatelyIfRunning: true, manager: manager, actorID: "actor", requestID: "cancel-b", now: 120
        )
        XCTAssertEqual(cancelRaceB.attempt.state, .succeeded)
        let afterRaceB = try repository.readRunState(runID: "run-main")
        XCTAssertEqual(afterRaceB.tasks.first(where: { $0.taskID == "task-b" })?.state, .evaluating)
        XCTAssertEqual(afterRaceB.tasks.first(where: { $0.taskID == "task-b" })?.attemptState, .succeeded)
    }

    func testRestartReconciliationUnknownBlockedNoAutoRetry() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let enforcer = try AuthorizationEnforcer(store: store)
        let gate = try RuntimePrepareAndStartGate(store: store)
        let adapter = MockRuntimeAdapter()
        let manager = RuntimeSessionManager(store: store, gate: gate, adapter: adapter)
        let repository = SchedulerRunRepository(store: store)
        let pins = Data(repeating: 1, count: 32)
        let (snap, scope) = makeVerifiedSnapshot(accountIsolation: .supported)

        let task = SchedulingTaskSnapshot(taskID: "task-1", workspaceID: "ws", state: .ready, attemptState: nil,
            enqueueSequence: 1, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: [])
        let created = try repository.create(runID: "run-1", tasks: [task], dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create-1", now: 100)
        let reserved = try repository.reserve(runID: "run-1", revision: created.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-1", now: 101)
        let prep = try repository.prepareAttempt(
            runID: "run-1", revision: reserved.revision, taskID: "task-1", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
            executionRequestPayloadDigest: "payload-1", gate: gate, actorID: "actor", requestID: "prep-1", now: 102
        )
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-1", runID: "run-1", binding: prep.binding)
        let started = try repository.startAttempt(
            runID: "run-1", revision: prep.result.revision, taskID: "task-1", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-1", snapshot: snap, requestedScope: scope,
            manager: manager, actorID: "actor", requestID: "start-1", now: 103
        )
        let pid = try XCTUnwrap(started.attempt.pid)
        adapter.simulatePIDReuse(pid: pid, newToken: "reused-unrelated-token", otherAttemptID: "other-att")

        _ = try manager.reconcileOnRestart(nowEpochSeconds: 110)
        let reconciled = try repository.reconcileAfterRestart(
            runID: "run-1", revision: started.result.revision, gate: gate,
            actorID: "actor", requestID: "reconcile-1", now: 111
        )
        let state = try repository.readRunState(runID: "run-1")
        XCTAssertEqual(state.tasks.first?.state, .blocked)
        XCTAssertEqual(state.tasks.first?.attemptState, .unknown)

        let reserveBlocked = try repository.reserve(runID: "run-1", revision: reconciled.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-none", now: 112)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(reserveBlocked.responseJSON.utf8)).count, 0)

        for reason in [SchedulerRetryReason.runtimeFailure, .manualInterruptedRecovery] {
            XCTAssertThrowsError(try repository.requestRetry(
                runID: "run-1", revision: reserveBlocked.revision, taskID: "task-1", reason: reason,
                currentInputPins: pins, gate: gate, actorID: "actor", requestID: "retry-\(reason)", now: 200
            )) { XCTAssertEqual($0 as? SchedulerError, .retryBlocked) }
        }

        // Unknown attempt continues occupying 1 of 4 workspace slots
        let secondTasks = (1...4).map {
            SchedulingTaskSnapshot(taskID: "t-\($0)", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: UInt64($0), installationID: "installation", accountRef: "account-\($0)",
                isolation: .supported, exclusiveResourceIDs: [])
        }
        let created2 = try repository.create(runID: "run-2", tasks: secondTasks, dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create-2", now: 113)
        let reserved2 = try repository.reserve(runID: "run-2", revision: created2.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-2", now: 114)
        let map2 = try JSONDecoder().decode([String: String].self, from: Data(reserved2.responseJSON.utf8))
        XCTAssertEqual(Set(map2.keys), Set(["t-1", "t-2", "t-3"]))
    }

    func testDurableBoundedRetryBackoffExhaustionAndFreshApproval() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let enforcer = try AuthorizationEnforcer(store: store)
        let gate = try RuntimePrepareAndStartGate(store: store)
        let adapter = MockRuntimeAdapter()
        let manager = RuntimeSessionManager(store: store, gate: gate, adapter: adapter)
        let repository = SchedulerRunRepository(store: store)
        let pins = Data(repeating: 1, count: 32)
        let (snap, scope) = makeVerifiedSnapshot(accountIsolation: .supported)

        let task = SchedulingTaskSnapshot(taskID: "task", workspaceID: "ws", state: .ready, attemptState: nil,
            enqueueSequence: 1, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: [])
        let created = try repository.create(runID: "run-retry", tasks: [task], dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create-retry", now: 100)
        var currentRev = created.revision
        var seenAttemptIDs: [String] = []
        var firstApprovalID = ""

        let expectedDelays: [Int64] = [1, 2, 4]
        var clock: Int64 = 100
        for attemptNum in 1...4 {
            let reserved = try repository.reserve(runID: "run-retry", revision: currentRev, currentInputPins: pins,
                actorID: "actor", requestID: "reserve-\(attemptNum)", now: clock)
            let prep = try repository.prepareAttempt(
                runID: "run-retry", revision: reserved.revision, taskID: "task", currentInputPins: pins,
                callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
                executionRequestPayloadDigest: "payload-\(attemptNum)", gate: gate,
                actorID: "actor", requestID: "prep-\(attemptNum)", now: clock + 1
            )
            XCTAssertEqual(prep.binding.taskRevision.revision, String(attemptNum))
            XCTAssertFalse(seenAttemptIDs.contains(prep.binding.attemptID))
            seenAttemptIDs.append(prep.binding.attemptID)

            if attemptNum == 1 {
                firstApprovalID = "app-exec-1"
            } else {
                // Previous attempt's approval cannot start the retried attempt
                XCTAssertThrowsError(try repository.startAttempt(
                    runID: "run-retry", revision: prep.result.revision, taskID: "task", currentInputPins: pins,
                    clientID: "desktop-1", executionApprovalID: firstApprovalID, snapshot: snap, requestedScope: scope,
                    manager: manager, actorID: "actor", requestID: "start-reuse-\(attemptNum)", now: clock + 1
                ))
            }

            let approvalID = "app-exec-\(attemptNum)"
            try recordExecutionApproval(enforcer: enforcer, approvalID: approvalID, runID: "run-retry",
                binding: prep.binding, issuedAt: 50, expiresAt: 5000)
            let started = try repository.startAttempt(
                runID: "run-retry", revision: prep.result.revision, taskID: "task", currentInputPins: pins,
                clientID: "desktop-1", executionApprovalID: approvalID, snapshot: snap, requestedScope: scope,
                manager: manager, actorID: "actor", requestID: "start-\(attemptNum)", now: clock + 2
            )
            _ = try manager.failProcess(attemptID: prep.binding.attemptID, nowEpochSeconds: clock + 3)
            let failedAt = clock + 4
            let observed = try repository.observeRuntime(
                runID: "run-retry", revision: started.result.revision, taskID: "task",
                gate: gate, actorID: "actor", requestID: "obs-fail-\(attemptNum)", now: failedAt
            )
            currentRev = observed.revision

            if attemptNum <= 3 {
                let delay = expectedDelays[attemptNum - 1]
                XCTAssertThrowsError(try repository.requestRetry(
                    runID: "run-retry", revision: currentRev, taskID: "task", reason: .runtimeFailure,
                    currentInputPins: pins, gate: gate, actorID: "actor", requestID: "retry-early-\(attemptNum)",
                    now: failedAt + delay - 1
                )) { XCTAssertEqual($0 as? SchedulerError, .retryBackoffActive(until: failedAt + delay)) }

                let retried = try repository.requestRetry(
                    runID: "run-retry", revision: currentRev, taskID: "task", reason: .runtimeFailure,
                    currentInputPins: pins, gate: gate, actorID: "actor", requestID: "retry-\(attemptNum)",
                    now: failedAt + delay
                )
                currentRev = retried.revision
                let runState = try repository.readRunState(runID: "run-retry")
                XCTAssertEqual(runState.retryCounts["task"], attemptNum)
                XCTAssertEqual(runState.attemptHistory["task"], seenAttemptIDs)
                XCTAssertEqual(runState.tasks.first?.state, .ready)
                clock = failedAt + delay + 1
            } else {
                XCTAssertThrowsError(try repository.requestRetry(
                    runID: "run-retry", revision: currentRev, taskID: "task", reason: .runtimeFailure,
                    currentInputPins: pins, gate: gate, actorID: "actor", requestID: "retry-exhausted",
                    now: failedAt + 100
                )) { XCTAssertEqual($0 as? SchedulerError, .retryExhausted) }
                XCTAssertEqual(try repository.readRunState(runID: "run-retry").tasks.first?.state, .failed)
            }
        }

        // Manual Interrupted recovery: runtimeFailure blocked, explicit manualInterruptedRecovery allowed after backoff
        let (snapInt, scopeInt) = makeVerifiedSnapshot(accountRef: "account-int", accountIsolation: .supported)
        let intTask = SchedulingTaskSnapshot(taskID: "int-task", workspaceID: "ws", state: .ready, attemptState: nil,
            enqueueSequence: 1, installationID: "installation", accountRef: "account-int", isolation: .supported, exclusiveResourceIDs: [])
        let intCreated = try repository.create(runID: "run-int", tasks: [intTask], dependencies: [], inputPins: pins,
            actorID: "actor", requestID: "create-int", now: 500)
        let intRes = try repository.reserve(runID: "run-int", revision: intCreated.revision, currentInputPins: pins,
            actorID: "actor", requestID: "res-int", now: 501)
        let intPrep = try repository.prepareAttempt(
            runID: "run-int", revision: intRes.revision, taskID: "int-task", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snapInt, requestedScope: scopeInt,
            executionRequestPayloadDigest: "payload-int", gate: gate, actorID: "actor", requestID: "prep-int", now: 502
        )
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-int", runID: "run-int", binding: intPrep.binding)
        let intStart = try repository.startAttempt(
            runID: "run-int", revision: intPrep.result.revision, taskID: "int-task", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-int", snapshot: snapInt, requestedScope: scopeInt,
            manager: manager, actorID: "actor", requestID: "start-int", now: 503
        )
        _ = try manager.interruptProcess(attemptID: intPrep.binding.attemptID, nowEpochSeconds: 504)
        let intObs = try repository.observeRuntime(
            runID: "run-int", revision: intStart.result.revision, taskID: "int-task",
            gate: gate, actorID: "actor", requestID: "obs-int", now: 505
        )
        XCTAssertEqual(try repository.readRunState(runID: "run-int").tasks.first?.state, .blocked)
        XCTAssertThrowsError(try repository.requestRetry(
            runID: "run-int", revision: intObs.revision, taskID: "int-task", reason: .runtimeFailure,
            currentInputPins: pins, gate: gate, actorID: "actor", requestID: "retry-int-auto", now: 510
        )) { XCTAssertEqual($0 as? SchedulerError, .retryBlocked) }
        let intRetry = try repository.requestRetry(
            runID: "run-int", revision: intObs.revision, taskID: "int-task", reason: .manualInterruptedRecovery,
            currentInputPins: pins, gate: gate, actorID: "actor", requestID: "retry-int-manual", now: 506
        )
        let intRes2 = try repository.reserve(runID: "run-int", revision: intRetry.revision, currentInputPins: pins,
            actorID: "actor", requestID: "res-int-2", now: 507)
        let intPrep2 = try repository.prepareAttempt(
            runID: "run-int", revision: intRes2.revision, taskID: "int-task", currentInputPins: pins,
            callerScopes: [.runRequest], snapshot: snapInt, requestedScope: scopeInt,
            executionRequestPayloadDigest: "payload-int-2", gate: gate, actorID: "actor", requestID: "prep-int-2", now: 508
        )
        XCTAssertNotEqual(intPrep2.binding.attemptID, intPrep.binding.attemptID)
        XCTAssertThrowsError(try repository.startAttempt(
            runID: "run-int", revision: intPrep2.result.revision, taskID: "int-task", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-int", snapshot: snapInt, requestedScope: scopeInt,
            manager: manager, actorID: "actor", requestID: "start-int-reuse", now: 509
        ))
        try recordExecutionApproval(enforcer: enforcer, approvalID: "app-int-2", runID: "run-int", binding: intPrep2.binding)
        let intStart2 = try repository.startAttempt(
            runID: "run-int", revision: intPrep2.result.revision, taskID: "int-task", currentInputPins: pins,
            clientID: "desktop-1", executionApprovalID: "app-int-2", snapshot: snapInt, requestedScope: scopeInt,
            manager: manager, actorID: "actor", requestID: "start-int-2", now: 510
        )
        XCTAssertEqual(intStart2.attempt.state, .running)
    }

    func testAtomicVerifiedEvaluationTransitionUnlocksDependentTask() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let enforcer = try AuthorizationEnforcer(store: store)
        let gate = try RuntimePrepareAndStartGate(store: store)
        let adapter = MockRuntimeAdapter()
        let manager = RuntimeSessionManager(store: store, gate: gate, adapter: adapter)
        let evalStore = try EvaluationVerdictStore(store: store)
        let repository = SchedulerRunRepository(store: store)
        let pins = Data(repeating: 1, count: 32)
        let (snap, scope) = makeVerifiedSnapshot(accountIsolation: .supported)

        let tasks = [
            SchedulingTaskSnapshot(taskID: "first", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 1, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
            SchedulingTaskSnapshot(taskID: "task-indet", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 2, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
            SchedulingTaskSnapshot(taskID: "task-fail", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 3, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
            SchedulingTaskSnapshot(taskID: "second", workspaceID: "ws", state: .ready, attemptState: nil,
                enqueueSequence: 4, installationID: "installation", accountRef: "account", isolation: .supported, exclusiveResourceIDs: []),
        ]
        let deps = [TaskDependency(predecessor: "first", successor: "second")]
        let created = try repository.create(runID: "run-eval", tasks: tasks, dependencies: deps, inputPins: pins,
            actorID: "actor", requestID: "create-eval", now: 100)
        let reserved = try repository.reserve(runID: "run-eval", revision: created.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-eval", now: 101)
        var rev = reserved.revision

        func runToEvaluating(_ taskID: String, index: Int) throws -> PreparedTaskBinding {
            let prep = try repository.prepareAttempt(
                runID: "run-eval", revision: rev, taskID: taskID, currentInputPins: pins,
                callerScopes: [.runRequest], snapshot: snap, requestedScope: scope,
                executionRequestPayloadDigest: "payload-\(taskID)", gate: gate,
                actorID: "actor", requestID: "prep-\(taskID)", now: Int64(110 + index * 10)
            )
            try recordExecutionApproval(enforcer: enforcer, approvalID: "app-\(taskID)", runID: "run-eval", binding: prep.binding)
            let start = try repository.startAttempt(
                runID: "run-eval", revision: prep.result.revision, taskID: taskID, currentInputPins: pins,
                clientID: "desktop-1", executionApprovalID: "app-\(taskID)", snapshot: snap, requestedScope: scope,
                manager: manager, actorID: "actor", requestID: "start-\(taskID)", now: Int64(111 + index * 10)
            )
            _ = try manager.completeProcessNormally(attemptID: prep.binding.attemptID, nowEpochSeconds: Int64(112 + index * 10))
            let obs = try repository.observeRuntime(
                runID: "run-eval", revision: start.result.revision, taskID: taskID,
                gate: gate, actorID: "actor", requestID: "obs-\(taskID)", now: Int64(113 + index * 10)
            )
            rev = obs.revision
            return prep.binding
        }

        let firstBinding = try runToEvaluating("first", index: 1)
        let indetBinding = try runToEvaluating("task-indet", index: 2)
        let failBinding = try runToEvaluating("task-fail", index: 3)

        // Dependent task "second" stays blocked while "first" is only Evaluating
        let blockedReserve = try repository.reserve(runID: "run-eval", revision: rev, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-eval-wait", now: 200)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(blockedReserve.responseJSON.utf8)).count, 0)
        rev = blockedReserve.revision

        // Negative evaluation checks: wrong attempt PASS, wrong task PASS, wrong digest, wrong criteria/policy, stale
        try evalStore.record(EvaluationVerdictRecord(
            evaluationID: "eval-wrong-attempt", workspaceID: "ws", runID: "run-eval", taskID: "first",
            taskRevision: firstBinding.taskRevision, attemptID: indetBinding.attemptID,
            artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", evaluatorID: "ev-1", evaluatorVersion: "1.0",
            verdict: .pass, policyVersion: 1, evaluatedAt: 201
        ))
        XCTAssertThrowsError(try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "first", currentInputPins: pins,
            evaluationID: "eval-wrong-attempt", artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", policyVersion: 1, expectedVerdict: .pass,
            actorID: "actor", requestID: "apply-wrong-attempt", now: 202
        )) { XCTAssertEqual($0 as? StorageError, .denied) }

        try evalStore.record(EvaluationVerdictRecord(
            evaluationID: "eval-wrong-task", workspaceID: "ws", runID: "run-eval", taskID: "other-task",
            taskRevision: firstBinding.taskRevision, attemptID: firstBinding.attemptID,
            artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", evaluatorID: "ev-1", evaluatorVersion: "1.0",
            verdict: .pass, policyVersion: 1, evaluatedAt: 202
        ))
        XCTAssertThrowsError(try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "first", currentInputPins: pins,
            evaluationID: "eval-wrong-task", artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", policyVersion: 1, expectedVerdict: .pass,
            actorID: "actor", requestID: "apply-wrong-task", now: 203
        )) { XCTAssertEqual($0 as? StorageError, .denied) }

        try evalStore.record(EvaluationVerdictRecord(
            evaluationID: "eval-valid-first", workspaceID: "ws", runID: "run-eval", taskID: "first",
            taskRevision: firstBinding.taskRevision, attemptID: firstBinding.attemptID,
            artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", evaluatorID: "ev-1", evaluatorVersion: "1.0",
            verdict: .pass, policyVersion: 1, evaluatedAt: 203
        ))
        XCTAssertThrowsError(try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "first", currentInputPins: pins,
            evaluationID: "eval-valid-first", artifactManifestID: "man-1", artifactManifestDigest: "dig-mutated",
            criteriaID: "crit-1", criteriaVersion: "v1", policyVersion: 1, expectedVerdict: .pass,
            actorID: "actor", requestID: "apply-wrong-digest", now: 204
        )) { XCTAssertEqual($0 as? StorageError, .denied) }
        XCTAssertThrowsError(try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "first", currentInputPins: pins,
            evaluationID: "eval-valid-first", artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v2", policyVersion: 1, expectedVerdict: .pass,
            actorID: "actor", requestID: "apply-wrong-crit", now: 204
        )) { XCTAssertEqual($0 as? StorageError, .versionConflict) }
        XCTAssertThrowsError(try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "first", currentInputPins: pins,
            evaluationID: "eval-valid-first", artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", policyVersion: 2, expectedVerdict: .pass,
            actorID: "actor", requestID: "apply-wrong-policy", now: 204
        )) { XCTAssertEqual($0 as? StorageError, .versionConflict) }

        try evalStore.record(EvaluationVerdictRecord(
            evaluationID: "eval-stale-first", workspaceID: "ws", runID: "run-eval", taskID: "first",
            taskRevision: firstBinding.taskRevision, attemptID: firstBinding.attemptID,
            artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", evaluatorID: "ev-1", evaluatorVersion: "1.0",
            verdict: .pass, policyVersion: 1, evaluatedAt: 204
        ))
        try evalStore.markStale(evaluationID: "eval-stale-first")
        XCTAssertThrowsError(try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "first", currentInputPins: pins,
            evaluationID: "eval-stale-first", artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", policyVersion: 1, expectedVerdict: .pass,
            actorID: "actor", requestID: "apply-stale", now: 205
        )) { XCTAssertEqual($0 as? StorageError, .versionConflict) }

        // Fabricating evaluationFailure retry before FAIL evaluation is rejected
        XCTAssertThrowsError(try repository.requestRetry(
            runID: "run-eval", revision: rev, taskID: "task-fail", reason: .evaluationFailure,
            currentInputPins: pins, gate: gate, actorID: "actor", requestID: "retry-unverified-eval-fail", now: 250
        )) { XCTAssertEqual($0 as? SchedulerError, .retryBlocked) }

        // INDETERMINATE -> Blocked
        try evalStore.record(EvaluationVerdictRecord(
            evaluationID: "eval-indet", workspaceID: "ws", runID: "run-eval", taskID: "task-indet",
            taskRevision: indetBinding.taskRevision, attemptID: indetBinding.attemptID,
            artifactManifestID: "man-indet", artifactManifestDigest: "dig-indet",
            criteriaID: "crit-1", criteriaVersion: "v1", evaluatorID: "ev-1", evaluatorVersion: "1.0",
            verdict: .indeterminate, policyVersion: 1, evaluatedAt: 205
        ))
        let indetApplied = try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "task-indet", currentInputPins: pins,
            evaluationID: "eval-indet", artifactManifestID: "man-indet", artifactManifestDigest: "dig-indet",
            criteriaID: "crit-1", criteriaVersion: "v1", policyVersion: 1, expectedVerdict: .indeterminate,
            actorID: "actor", requestID: "apply-indet", now: 206
        )
        rev = indetApplied.revision
        XCTAssertEqual(try repository.readRunState(runID: "run-eval").tasks.first(where: { $0.taskID == "task-indet" })?.state, .blocked)

        // FAIL -> Failed -> evaluationFailure retry eligible after backoff
        try evalStore.record(EvaluationVerdictRecord(
            evaluationID: "eval-fail", workspaceID: "ws", runID: "run-eval", taskID: "task-fail",
            taskRevision: failBinding.taskRevision, attemptID: failBinding.attemptID,
            artifactManifestID: "man-fail", artifactManifestDigest: "dig-fail",
            criteriaID: "crit-1", criteriaVersion: "v1", evaluatorID: "ev-1", evaluatorVersion: "1.0",
            verdict: .fail, policyVersion: 1, evaluatedAt: 206
        ))
        let failApplied = try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "task-fail", currentInputPins: pins,
            evaluationID: "eval-fail", artifactManifestID: "man-fail", artifactManifestDigest: "dig-fail",
            criteriaID: "crit-1", criteriaVersion: "v1", policyVersion: 1, expectedVerdict: .fail,
            actorID: "actor", requestID: "apply-fail", now: 207
        )
        rev = failApplied.revision
        XCTAssertEqual(try repository.readRunState(runID: "run-eval").tasks.first(where: { $0.taskID == "task-fail" })?.state, .failed)
        let retriedFail = try repository.requestRetry(
            runID: "run-eval", revision: rev, taskID: "task-fail", reason: .evaluationFailure,
            currentInputPins: pins, gate: gate, actorID: "actor", requestID: "retry-eval-fail", now: 208
        )
        rev = retriedFail.revision
        XCTAssertEqual(try repository.readRunState(runID: "run-eval").tasks.first(where: { $0.taskID == "task-fail" })?.state, .ready)

        // Valid PASS for "first" -> Succeeded atomically + unlocks dependent "second"
        let passApplied = try repository.applyEvaluation(
            runID: "run-eval", revision: rev, taskID: "first", currentInputPins: pins,
            evaluationID: "eval-valid-first", artifactManifestID: "man-1", artifactManifestDigest: "dig-1",
            criteriaID: "crit-1", criteriaVersion: "v1", policyVersion: 1, expectedVerdict: .pass,
            actorID: "actor", requestID: "apply-pass-first", now: 209
        )
        let evalState = try repository.readRunState(runID: "run-eval")
        XCTAssertEqual(evalState.tasks.first(where: { $0.taskID == "first" })?.state, .succeeded)
        XCTAssertEqual(evalState.evaluatedSnapshots["first"]?.evaluationID, "eval-valid-first")
        XCTAssertEqual(evalState.evaluatedSnapshots["first"]?.verdict, .pass)

        let unlockedReserve = try repository.reserve(
            runID: "run-eval", revision: passApplied.revision, currentInputPins: pins,
            actorID: "actor", requestID: "reserve-unlocked", now: 210
        )
        let unlockedMap = try JSONDecoder().decode([String: String].self, from: Data(unlockedReserve.responseJSON.utf8))
        XCTAssertEqual(unlockedMap["task-fail"] != nil, true)
        XCTAssertEqual(unlockedMap["second"] != nil, true)
    }
}
