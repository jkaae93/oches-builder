import CryptoKit
import Foundation
import SQLite3

enum SchedulerError: Error, Equatable, Sendable {
    case attemptNotPrepared
    case retryBlocked
    case retryExhausted
    case retryBackoffActive(until: Int64)
    case invalidTaskState
    case bindingMismatch
}

struct PreparedTaskBinding: Codable, Equatable, Sendable {
    let attemptID: String
    let runtimeTaskID: String
    let taskRevision: RevisionRef
    let instanceRevision: RevisionRef
    let bindingDigest: String
    let executionRequestDigest: String
    let capabilitySnapshotID: String
    let attemptSequence: Int
}

struct EvaluatedSnapshotBinding: Codable, Equatable, Sendable {
    let evaluationID: String
    let attemptID: String
    let artifactManifestID: String
    let artifactManifestDigest: String
    let criteriaID: String
    let criteriaVersion: String
    let policyVersion: UInt64
    let verdict: EvaluationVerdict
    let evaluatedAt: Int64
}

struct SchedulerRunRepository {
    private struct Record: Codable {
        let schemaVersion: Int
        let inputPins: Data
        let planDigest: Data
        let instanceRevision: RevisionRef?
        let tasks: [SchedulingTaskSnapshot]
        let dependencies: [TaskDependency]
        let reservations: [String: String]
        let preparedAttempts: [String: PreparedTaskBinding]
        let retryCounts: [String: Int]
        let lastFailureTimestamps: [String: Int64]
        let attemptHistory: [String: [String]]
        let evaluatedSnapshots: [String: EvaluatedSnapshotBinding]

        init(
            schemaVersion: Int,
            inputPins: Data,
            planDigest: Data,
            instanceRevision: RevisionRef? = nil,
            tasks: [SchedulingTaskSnapshot],
            dependencies: [TaskDependency],
            reservations: [String: String],
            preparedAttempts: [String: PreparedTaskBinding] = [:],
            retryCounts: [String: Int] = [:],
            lastFailureTimestamps: [String: Int64] = [:],
            attemptHistory: [String: [String]] = [:],
            evaluatedSnapshots: [String: EvaluatedSnapshotBinding] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.inputPins = inputPins
            self.planDigest = planDigest
            self.instanceRevision = instanceRevision
            self.tasks = tasks
            self.dependencies = dependencies
            self.reservations = reservations
            self.preparedAttempts = preparedAttempts
            self.retryCounts = retryCounts
            self.lastFailureTimestamps = lastFailureTimestamps
            self.attemptHistory = attemptHistory
            self.evaluatedSnapshots = evaluatedSnapshots
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion, inputPins, planDigest, instanceRevision, tasks, dependencies, reservations
            case preparedAttempts, retryCounts, lastFailureTimestamps, attemptHistory, evaluatedSnapshots
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            inputPins = try c.decode(Data.self, forKey: .inputPins)
            planDigest = try c.decode(Data.self, forKey: .planDigest)
            instanceRevision = try c.decodeIfPresent(RevisionRef.self, forKey: .instanceRevision)
            tasks = try c.decode([SchedulingTaskSnapshot].self, forKey: .tasks)
            dependencies = try c.decode([TaskDependency].self, forKey: .dependencies)
            reservations = try c.decode([String: String].self, forKey: .reservations)
            preparedAttempts = try c.decodeIfPresent([String: PreparedTaskBinding].self, forKey: .preparedAttempts) ?? [:]
            retryCounts = try c.decodeIfPresent([String: Int].self, forKey: .retryCounts) ?? [:]
            lastFailureTimestamps = try c.decodeIfPresent([String: Int64].self, forKey: .lastFailureTimestamps) ?? [:]
            attemptHistory = try c.decodeIfPresent([String: [String]].self, forKey: .attemptHistory) ?? [:]
            evaluatedSnapshots = try c.decodeIfPresent([String: EvaluatedSnapshotBinding].self, forKey: .evaluatedSnapshots) ?? [:]
        }
    }

    private struct Plan: Codable {
        let inputPins: Data
        let tasks: [SchedulingTaskSnapshot]
        let dependencies: [TaskDependency]
        let instanceRevision: RevisionRef?
    }

    let store: SQLiteStore

    static func scopedRuntimeTaskID(runID: String, taskID: String) -> String {
        "arc07/run/\(runID)/task/\(taskID)"
    }

    func create(
        runID: String,
        tasks: [SchedulingTaskSnapshot],
        dependencies: [TaskDependency],
        inputPins: Data,
        instanceRevision: RevisionRef? = nil,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> TransitionResult {
        guard inputPins.count == 32, tasks.allSatisfy({ $0.state == .ready && $0.attemptState == nil }) else {
            throw StorageError.invalidInput
        }
        _ = try FIFOSchedulingPlanner.select(workspaceID: store.workspaceID, tasks: tasks, dependencies: dependencies)
        let planData = try encode(Plan(inputPins: inputPins, tasks: tasks, dependencies: dependencies, instanceRevision: instanceRevision))
        let digest = Data(SHA256.hash(data: planData))
        let record = Record(
            schemaVersion: 1,
            inputPins: inputPins,
            planDigest: digest,
            instanceRevision: instanceRevision,
            tasks: tasks,
            dependencies: dependencies,
            reservations: [:]
        )
        return try commit(record, runID: runID, expected: nil, operation: "run.create", actorID: actorID,
            requestID: requestID, response: "{}", now: now)
    }

    func reserve(
        runID: String,
        revision: RevisionRef,
        currentInputPins: Data,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> TransitionResult {
        let (identifier, snapshot, record) = try loadRecord(runID: runID)
        guard revision.objectID.utf8.elementsEqual(identifier.utf8) else { throw StorageError.invalidInput }
        guard record.inputPins == currentInputPins else { throw StorageError.versionConflict }

        let localSelected = try FIFOSchedulingPlanner.select(
            workspaceID: store.workspaceID,
            tasks: record.tasks,
            dependencies: record.dependencies
        )
        let otherOccupied = try readOtherOccupiedTasks(excludingObjectID: identifier)
        let selectedList = try FIFOSchedulingPlanner.select(
            workspaceID: store.workspaceID,
            tasks: record.tasks,
            dependencies: record.dependencies,
            externalOccupied: otherOccupied
        )
        if !localSelected.isEmpty && selectedList.isEmpty && snapshot.revision == revision {
            throw StorageError.busy
        }

        let selected = Set(selectedList)
        var reservations = record.reservations
        var response: [String: String] = [:]
        let tasks = record.tasks.map { task -> SchedulingTaskSnapshot in
            guard selected.contains(task.taskID) else { return task }
            let attemptID = UUID().uuidString.lowercased()
            reservations[task.taskID] = attemptID
            response[task.taskID] = attemptID
            return SchedulingTaskSnapshot(
                taskID: task.taskID,
                workspaceID: task.workspaceID,
                state: .prepared,
                attemptState: .prepared,
                enqueueSequence: task.enqueueSequence,
                installationID: task.installationID,
                accountRef: task.accountRef,
                isolation: task.isolation,
                exclusiveResourceIDs: task.exclusiveResourceIDs
            )
        }
        let next = updatingRecord(record, tasks: tasks, reservations: reservations)
        return try commit(next, runID: runID, expected: revision, operation: "run.reserve", actorID: actorID,
            requestID: requestID, response: String(decoding: encode(response), as: UTF8.self), now: now)
    }

    func prepareAttempt(
        runID: String,
        revision: RevisionRef,
        taskID: String,
        currentInputPins: Data,
        callerScopes: Set<PermissionScope>,
        snapshot capabilitySnapshot: CapabilitySnapshot,
        requestedScope: CapabilityScope,
        executionRequestPayloadDigest: String,
        gate: RuntimePrepareAndStartGate,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> (result: TransitionResult, binding: PreparedTaskBinding) {
        let (identifier, snapshot, record) = try loadRecord(runID: runID)
        guard gate.store === store,
              revision.objectID.utf8.elementsEqual(identifier.utf8),
              !executionRequestPayloadDigest.isEmpty,
              !executionRequestPayloadDigest.utf8.contains(0) else {
            throw StorageError.invalidInput
        }
        guard record.inputPins == currentInputPins else { throw StorageError.versionConflict }
        guard let attemptID = record.reservations[taskID],
              let scheduled = record.tasks.first(where: { $0.taskID.utf8.elementsEqual(taskID.utf8) }) else {
            throw StorageError.notFound
        }
        guard requestedScope.workspaceID.utf8.elementsEqual(store.workspaceID.utf8),
              requestedScope.installationID.utf8.elementsEqual(scheduled.installationID.utf8),
              requestedScope.accountRef.utf8.elementsEqual(scheduled.accountRef.utf8) else {
            throw StorageError.denied
        }

        let binding: PreparedTaskBinding
        if snapshot.revision != revision,
           let existingBinding = record.preparedAttempts[taskID],
           existingBinding.attemptID.utf8.elementsEqual(attemptID.utf8) {
            binding = existingBinding
        } else {
            binding = try makePreparedBinding(
                runID: runID,
                identifier: identifier,
                storeGeneration: snapshot.revision.storeGeneration,
                record: record,
                scheduled: scheduled,
                attemptID: attemptID,
                capabilitySnapshotID: capabilitySnapshot.snapshotID,
                executionRequestPayloadDigest: executionRequestPayloadDigest
            )
        }

        if snapshot.revision == revision {
            guard scheduled.state == .prepared else { throw SchedulerError.invalidTaskState }
            if let existing = try fetchAttemptIfPresent(gate: gate, attemptID: attemptID) {
                try verifyAttemptIdentity(attempt: existing, runID: runID, taskID: taskID, scheduled: scheduled, binding: binding)
                guard existing.state == .prepared else { throw SchedulerError.bindingMismatch }
            } else {
                _ = try gate.prepare(PrepareAttemptInput(
                    attemptID: attemptID,
                    workspaceID: store.workspaceID,
                    runID: runID,
                    taskID: binding.runtimeTaskID,
                    taskRevision: binding.taskRevision,
                    instanceRevision: binding.instanceRevision,
                    installationID: scheduled.installationID,
                    accountRef: scheduled.accountRef,
                    bindingDigest: binding.bindingDigest,
                    executionRequestDigest: binding.executionRequestDigest,
                    callerScopes: callerScopes,
                    snapshot: capabilitySnapshot,
                    requestedScope: requestedScope
                ))
            }
        }

        var preparedAttempts = record.preparedAttempts
        preparedAttempts[taskID] = binding
        let next = updatingRecord(record, preparedAttempts: preparedAttempts)
        let responseJSON = String(decoding: try encode(binding), as: UTF8.self)
        let details: RawJSONValue = .object([
            ("taskID", .string(taskID)),
            ("attemptID", .string(attemptID)),
            ("bindingDigest", .string(binding.bindingDigest)),
            ("executionRequestDigest", .string(binding.executionRequestDigest)),
            ("capabilitySnapshotID", .string(binding.capabilitySnapshotID))
        ])
        let result = try commit(next, runID: runID, expected: revision, operation: "run.prepareAttempt",
            actorID: actorID, requestID: requestID, response: responseJSON, now: now, details: details)
        let returnedBinding = try JSONDecoder().decode(PreparedTaskBinding.self, from: Data(result.responseJSON.utf8))
        return (result, returnedBinding)
    }

    func startAttempt(
        runID: String,
        revision: RevisionRef,
        taskID: String,
        currentInputPins: Data,
        clientID: String,
        executionApprovalID: String,
        transferApprovalID: String? = nil,
        requiresExternalTransfer: Bool = false,
        snapshot capabilitySnapshot: CapabilitySnapshot,
        requestedScope: CapabilityScope,
        manager: RuntimeSessionManager,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> (result: TransitionResult, attempt: ExecutionAttemptRecord) {
        let (identifier, snapshot, record) = try loadRecord(runID: runID)
        guard manager.store === store,
              manager.gate.store === store,
              revision.objectID.utf8.elementsEqual(identifier.utf8) else {
            throw StorageError.invalidInput
        }
        guard record.inputPins == currentInputPins else { throw StorageError.versionConflict }
        guard let binding = record.preparedAttempts[taskID] else { throw SchedulerError.attemptNotPrepared }
        guard let scheduled = record.tasks.first(where: { $0.taskID.utf8.elementsEqual(taskID.utf8) }) else {
            throw StorageError.notFound
        }
        guard capabilitySnapshot.snapshotID.utf8.elementsEqual(binding.capabilitySnapshotID.utf8) else {
            throw RuntimeLifecycleError.permissionDenied("capability snapshot mismatch with prepared attempt")
        }

        let details: RawJSONValue = .object([
            ("taskID", .string(taskID)),
            ("attemptID", .string(binding.attemptID)),
            ("executionApprovalID", .string(executionApprovalID)),
            ("transferApprovalID", transferApprovalID.map(RawJSONValue.string) ?? .null),
            ("requiresExternalTransfer", .bool(requiresExternalTransfer)),
            ("capabilitySnapshotID", .string(capabilitySnapshot.snapshotID))
        ])

        if snapshot.revision != revision {
            let result = try commit(record, runID: runID, expected: revision, operation: "run.startAttempt",
                actorID: actorID, requestID: requestID, response: "{}", now: now, details: details)
            let attempt = try manager.gate.fetchAttempt(attemptID: binding.attemptID)
            return (result, attempt)
        }

        guard record.reservations[taskID]?.utf8.elementsEqual(binding.attemptID.utf8) == true else {
            throw SchedulerError.bindingMismatch
        }
        guard scheduled.state == .prepared else { throw SchedulerError.invalidTaskState }

        let attempt = try manager.start(StartAttemptInput(
            attemptID: binding.attemptID,
            requestID: requestID,
            actorID: actorID,
            clientID: clientID,
            executionApprovalID: executionApprovalID,
            transferApprovalID: transferApprovalID,
            requiresExternalTransfer: requiresExternalTransfer,
            snapshot: capabilitySnapshot,
            requestedScope: requestedScope,
            nowEpochSeconds: now
        ))
        try verifyAttemptIdentity(attempt: attempt, runID: runID, taskID: taskID, scheduled: scheduled, binding: binding)

        let tasks = record.tasks.map { task -> SchedulingTaskSnapshot in
            guard task.taskID.utf8.elementsEqual(taskID.utf8) else { return task }
            return updatedTask(task, state: derivedTaskState(for: attempt.state), attemptState: attempt.state)
        }
        var lastFailures = record.lastFailureTimestamps
        if attempt.state == .failed || attempt.state == .interrupted {
            lastFailures[taskID] = lastFailures[taskID] ?? now
        }
        let next = updatingRecord(record, tasks: tasks, lastFailureTimestamps: lastFailures)
        let result = try commit(next, runID: runID, expected: revision, operation: "run.startAttempt",
            actorID: actorID, requestID: requestID, response: "{}", now: now, details: details)
        return (result, attempt)
    }

    func cancelTask(
        runID: String,
        revision: RevisionRef,
        taskID: String,
        resolveImmediatelyIfRunning: Bool = true,
        manager: RuntimeSessionManager,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> (result: TransitionResult, attempt: ExecutionAttemptRecord) {
        let (identifier, snapshot, record) = try loadRecord(runID: runID)
        guard manager.store === store,
              manager.gate.store === store,
              revision.objectID.utf8.elementsEqual(identifier.utf8) else {
            throw StorageError.invalidInput
        }
        guard let attemptID = record.reservations[taskID],
              let scheduled = record.tasks.first(where: { $0.taskID.utf8.elementsEqual(taskID.utf8) }) else {
            throw StorageError.notFound
        }

        let details: RawJSONValue = .object([
            ("taskID", .string(taskID)),
            ("attemptID", .string(attemptID)),
            ("resolveImmediatelyIfRunning", .bool(resolveImmediatelyIfRunning))
        ])

        if snapshot.revision != revision {
            let result = try commit(record, runID: runID, expected: revision, operation: "run.cancelTask",
                actorID: actorID, requestID: requestID, response: "{}", now: now, details: details)
            let attempt = try manager.gate.fetchAttempt(attemptID: attemptID)
            return (result, attempt)
        }

        let currentAttempt = try manager.gate.fetchAttempt(attemptID: attemptID)
        try verifyAttemptIdentity(attempt: currentAttempt, runID: runID, taskID: taskID, scheduled: scheduled, binding: record.preparedAttempts[taskID])

        let attempt = try manager.cancel(
            attemptID: attemptID,
            resolveImmediatelyIfRunning: resolveImmediatelyIfRunning,
            nowEpochSeconds: now
        )
        try verifyAttemptIdentity(attempt: attempt, runID: runID, taskID: taskID, scheduled: scheduled, binding: record.preparedAttempts[taskID])

        let tasks = record.tasks.map { task -> SchedulingTaskSnapshot in
            guard task.taskID.utf8.elementsEqual(taskID.utf8) else { return task }
            return updatedTask(task, state: derivedTaskState(for: attempt.state), attemptState: attempt.state)
        }
        var lastFailures = record.lastFailureTimestamps
        if attempt.state == .failed || attempt.state == .interrupted {
            lastFailures[taskID] = lastFailures[taskID] ?? now
        }
        let next = updatingRecord(record, tasks: tasks, lastFailureTimestamps: lastFailures)
        let result = try commit(next, runID: runID, expected: revision, operation: "run.cancelTask",
            actorID: actorID, requestID: requestID, response: "{}", now: now, details: details)
        return (result, attempt)
    }

    func observeRuntime(
        runID: String,
        revision: RevisionRef,
        taskID: String,
        gate: RuntimePrepareAndStartGate,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> TransitionResult {
        let (identifier, _, record) = try loadRecord(runID: runID)
        guard gate.store === store, revision.objectID.utf8.elementsEqual(identifier.utf8) else {
            throw StorageError.invalidInput
        }
        guard let attemptID = record.reservations[taskID],
              let scheduled = record.tasks.first(where: { $0.taskID.utf8.elementsEqual(taskID.utf8) }) else {
            throw StorageError.notFound
        }
        let attempt = try gate.fetchAttempt(attemptID: attemptID)
        try verifyAttemptIdentity(attempt: attempt, runID: runID, taskID: taskID, scheduled: scheduled, binding: record.preparedAttempts[taskID])

        let tasks = record.tasks.map { task in
            guard task.taskID.utf8.elementsEqual(taskID.utf8) else { return task }
            return updatedTask(task, state: derivedTaskState(for: attempt.state), attemptState: attempt.state)
        }
        var lastFailures = record.lastFailureTimestamps
        if attempt.state == .failed || attempt.state == .interrupted {
            lastFailures[taskID] = lastFailures[taskID] ?? now
        }
        let next = updatingRecord(record, tasks: tasks, lastFailureTimestamps: lastFailures)
        return try commit(next, runID: runID, expected: revision, operation: "run.observeRuntime", actorID: actorID,
            requestID: requestID, response: "{}", now: now,
            details: .object([("taskID", .string(taskID)), ("attemptID", .string(attemptID)), ("state", .string(attempt.state.rawValue))]))
    }

    func reconcileAfterRestart(
        runID: String,
        revision: RevisionRef,
        gate: RuntimePrepareAndStartGate,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> TransitionResult {
        let (identifier, snapshot, record) = try loadRecord(runID: runID)
        guard gate.store === store, revision.objectID.utf8.elementsEqual(identifier.utf8) else {
            throw StorageError.invalidInput
        }

        let reservationPairs = record.reservations.sorted { $0.key < $1.key }.map {
            RawJSONValue.object([("taskID", .string($0.key)), ("attemptID", .string($0.value))])
        }
        let details: RawJSONValue = .object([("reservations", .array(reservationPairs))])

        if snapshot.revision != revision {
            return try commit(record, runID: runID, expected: revision, operation: "run.reconcileRestart",
                actorID: actorID, requestID: requestID, response: "{}", now: now, details: details)
        }

        var lastFailures = record.lastFailureTimestamps
        let tasks = try record.tasks.map { task -> SchedulingTaskSnapshot in
            guard let attemptID = record.reservations[task.taskID] else { return task }
            let binding = record.preparedAttempts[task.taskID]
            let attempt: ExecutionAttemptRecord
            if binding != nil {
                attempt = try gate.fetchAttempt(attemptID: attemptID)
            } else if let found = try fetchAttemptIfPresent(gate: gate, attemptID: attemptID) {
                attempt = found
            } else {
                return task
            }
            try verifyAttemptIdentity(attempt: attempt, runID: runID, taskID: task.taskID, scheduled: task, binding: binding)
            if attempt.state == .failed || attempt.state == .interrupted {
                lastFailures[task.taskID] = lastFailures[task.taskID] ?? now
            }
            return updatedTask(task, state: derivedTaskState(for: attempt.state), attemptState: attempt.state)
        }
        let next = updatingRecord(record, tasks: tasks, lastFailureTimestamps: lastFailures)
        return try commit(next, runID: runID, expected: revision, operation: "run.reconcileRestart",
            actorID: actorID, requestID: requestID, response: "{}", now: now, details: details)
    }

    func applyEvaluation(
        runID: String,
        revision: RevisionRef,
        taskID: String,
        currentInputPins: Data,
        evaluationID: String,
        artifactManifestID: String,
        artifactManifestDigest: String,
        criteriaID: String,
        criteriaVersion: String,
        policyVersion: UInt64,
        expectedVerdict: EvaluationVerdict,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> TransitionResult {
        let (identifier, snapshot, record) = try loadRecord(runID: runID)
        guard revision.objectID.utf8.elementsEqual(identifier.utf8),
              ![evaluationID, artifactManifestID, artifactManifestDigest, criteriaID, criteriaVersion]
                .contains(where: { $0.isEmpty || $0.utf8.contains(0) }) else {
            throw StorageError.invalidInput
        }
        guard record.inputPins == currentInputPins else { throw StorageError.versionConflict }
        guard let scheduled = record.tasks.first(where: { $0.taskID.utf8.elementsEqual(taskID.utf8) }) else {
            throw StorageError.notFound
        }
        guard let binding = record.preparedAttempts[taskID] else { throw SchedulerError.attemptNotPrepared }

        if snapshot.revision == revision {
            guard record.reservations[taskID]?.utf8.elementsEqual(binding.attemptID.utf8) == true else {
                throw SchedulerError.bindingMismatch
            }
            guard scheduled.state == .evaluating else { throw SchedulerError.invalidTaskState }
        }

        let nextTaskState: TaskLifecycleState
        switch expectedVerdict {
        case .pass: nextTaskState = .succeeded
        case .fail: nextTaskState = .failed
        case .indeterminate: nextTaskState = .blocked
        }

        let tasks = record.tasks.map { task -> SchedulingTaskSnapshot in
            guard task.taskID.utf8.elementsEqual(taskID.utf8) else { return task }
            return updatedTask(task, state: nextTaskState, attemptState: task.attemptState)
        }
        var lastFailures = record.lastFailureTimestamps
        if expectedVerdict == .fail {
            lastFailures[taskID] = now
        }
        var evaluatedSnapshots = record.evaluatedSnapshots
        evaluatedSnapshots[taskID] = EvaluatedSnapshotBinding(
            evaluationID: evaluationID,
            attemptID: binding.attemptID,
            artifactManifestID: artifactManifestID,
            artifactManifestDigest: artifactManifestDigest,
            criteriaID: criteriaID,
            criteriaVersion: criteriaVersion,
            policyVersion: policyVersion,
            verdict: expectedVerdict,
            evaluatedAt: now
        )

        let next = updatingRecord(record, tasks: tasks, lastFailureTimestamps: lastFailures, evaluatedSnapshots: evaluatedSnapshots)
        let details: RawJSONValue = .object([
            ("taskID", .string(taskID)),
            ("attemptID", .string(binding.attemptID)),
            ("evaluationID", .string(evaluationID)),
            ("artifactManifestID", .string(artifactManifestID)),
            ("artifactManifestDigest", .string(artifactManifestDigest)),
            ("criteriaID", .string(criteriaID)),
            ("criteriaVersion", .string(criteriaVersion)),
            ("policyVersion", .number(String(policyVersion))),
            ("verdict", .string(expectedVerdict.rawValue))
        ])
        let check = SchedulerEvaluationCheck(
            evaluationID: evaluationID,
            runID: runID,
            taskID: taskID,
            runtimeTaskID: binding.runtimeTaskID,
            taskRevision: binding.taskRevision,
            attemptID: binding.attemptID,
            artifactManifestID: artifactManifestID,
            artifactManifestDigest: artifactManifestDigest,
            criteriaID: criteriaID,
            criteriaVersion: criteriaVersion,
            policyVersion: policyVersion,
            expectedVerdict: expectedVerdict
        )
        let payload = try encode(next)
        let request = TransitionRequest(
            actorID: actorID,
            workspaceID: store.workspaceID,
            operation: "run.applyEvaluation",
            requestID: requestID,
            objectID: identifier,
            ownerModule: "ARC-07",
            expectedRevision: revision,
            normalizedInput: .object([
                ("planDigest", .string(next.planDigest.base64EncodedString())),
                ("inputPins", .string(next.inputPins.base64EncodedString())),
                ("details", details)
            ]),
            nextStateJSON: String(decoding: payload, as: UTF8.self),
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-07", kind: "run.applyEvaluation", payloadJSON: "{}", observedAt: now)],
            responseJSON: "{}",
            nowEpochSeconds: now
        )
        return try store.commitSchedulerEvaluation(request, check: check)
    }

    func requestRetry(
        runID: String,
        revision: RevisionRef,
        taskID: String,
        reason: SchedulerRetryReason,
        currentInputPins: Data,
        gate: RuntimePrepareAndStartGate,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> TransitionResult {
        let (identifier, snapshot, record) = try loadRecord(runID: runID)
        guard gate.store === store, revision.objectID.utf8.elementsEqual(identifier.utf8) else {
            throw StorageError.invalidInput
        }
        guard record.inputPins == currentInputPins else { throw StorageError.versionConflict }

        let reasonName: String
        switch reason {
        case .runtimeFailure: reasonName = "runtimeFailure"
        case .evaluationFailure: reasonName = "evaluationFailure"
        case .manualInterruptedRecovery: reasonName = "manualInterruptedRecovery"
        }
        let details: RawJSONValue = .object([
            ("taskID", .string(taskID)),
            ("reason", .string(reasonName))
        ])

        if snapshot.revision != revision {
            return try commit(record, runID: runID, expected: revision, operation: "run.requestRetry",
                actorID: actorID, requestID: requestID, response: "{}", now: now, details: details)
        }

        guard let attemptID = record.reservations[taskID],
              let scheduled = record.tasks.first(where: { $0.taskID.utf8.elementsEqual(taskID.utf8) }) else {
            throw StorageError.notFound
        }
        let attempt = try gate.fetchAttempt(attemptID: attemptID)
        try verifyAttemptIdentity(attempt: attempt, runID: runID, taskID: taskID, scheduled: scheduled, binding: record.preparedAttempts[taskID])

        switch reason {
        case .runtimeFailure:
            guard scheduled.state == .failed else { throw SchedulerError.retryBlocked }
        case .manualInterruptedRecovery:
            guard scheduled.state == .blocked else { throw SchedulerError.retryBlocked }
        case .evaluationFailure:
            guard scheduled.state == .failed,
                  let evalSnap = record.evaluatedSnapshots[taskID],
                  evalSnap.attemptID.utf8.elementsEqual(attemptID.utf8),
                  evalSnap.verdict == .fail,
                  let binding = record.preparedAttempts[taskID],
                  try EvaluationVerdictStore.hasValidFailureRecord(
                      store: store,
                      workspaceID: store.workspaceID,
                      runID: runID,
                      taskID: taskID,
                      attemptID: attemptID,
                      taskRevision: binding.taskRevision,
                      evaluationID: evalSnap.evaluationID
                  ) else {
                throw SchedulerError.retryBlocked
            }
        }

        guard let failedAt = record.lastFailureTimestamps[taskID] else {
            throw SchedulerError.retryBlocked
        }
        let retriesAlreadyReserved = record.retryCounts[taskID] ?? 0
        let decision = try SchedulerRetryPolicy.evaluate(
            lastAttempt: attempt.state,
            reason: reason,
            retriesAlreadyReserved: retriesAlreadyReserved,
            failedAt: failedAt,
            now: now
        )
        switch decision {
        case .blocked:
            throw SchedulerError.retryBlocked
        case .exhausted:
            throw SchedulerError.retryExhausted
        case .waitUntil(let nextTime):
            throw SchedulerError.retryBackoffActive(until: nextTime)
        case .eligible(let requiresNewAttempt, let requiresNewApproval):
            guard requiresNewAttempt && requiresNewApproval else {
                throw SchedulerError.retryBlocked
            }
        }

        var retryCounts = record.retryCounts
        retryCounts[taskID] = retriesAlreadyReserved + 1
        var attemptHistory = record.attemptHistory
        attemptHistory[taskID, default: []].append(attemptID)
        var reservations = record.reservations
        reservations.removeValue(forKey: taskID)
        var preparedAttempts = record.preparedAttempts
        preparedAttempts.removeValue(forKey: taskID)
        var lastFailures = record.lastFailureTimestamps
        lastFailures.removeValue(forKey: taskID)
        let tasks = record.tasks.map { task -> SchedulingTaskSnapshot in
            guard task.taskID.utf8.elementsEqual(taskID.utf8) else { return task }
            return updatedTask(task, state: .ready, attemptState: nil)
        }
        let next = updatingRecord(
            record,
            tasks: tasks,
            reservations: reservations,
            preparedAttempts: preparedAttempts,
            retryCounts: retryCounts,
            lastFailureTimestamps: lastFailures,
            attemptHistory: attemptHistory
        )
        return try commit(next, runID: runID, expected: revision, operation: "run.requestRetry",
            actorID: actorID, requestID: requestID, response: "{}", now: now, details: details)
    }

    func readRunState(runID: String) throws -> (
        revision: RevisionRef,
        tasks: [SchedulingTaskSnapshot],
        reservations: [String: String],
        preparedAttempts: [String: PreparedTaskBinding],
        retryCounts: [String: Int],
        attemptHistory: [String: [String]],
        evaluatedSnapshots: [String: EvaluatedSnapshotBinding]
    ) {
        let (_, snapshot, record) = try loadRecord(runID: runID)
        return (
            snapshot.revision,
            record.tasks,
            record.reservations,
            record.preparedAttempts,
            record.retryCounts,
            record.attemptHistory,
            record.evaluatedSnapshots
        )
    }

    private func loadRecord(runID: String) throws -> (identifier: String, snapshot: StateSnapshot, record: Record) {
        let identifier = try objectID(runID)
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: identifier)
        guard snapshot.ownerModule == "ARC-07" else { throw StorageError.corrupt("invalid run owner") }
        let record = try JSONDecoder().decode(Record.self, from: Data(snapshot.stateJSON.utf8))
        guard record.schemaVersion == 1, record.planDigest.count == 32 else {
            throw StorageError.corrupt("invalid run payload")
        }
        return (identifier, snapshot, record)
    }

    private func readOtherOccupiedTasks(excludingObjectID: String) throws -> [SchedulingTaskSnapshot] {
        try store.withConnectionLock { _ in
            let decoder = JSONDecoder()
            let statement = try store.prepare(
                "SELECT state_json FROM operational_state WHERE workspace_id = ? AND owner_module = 'ARC-07' AND substr(object_id, 1, 10) = 'arc07/run/' AND object_id != ?"
            )
            defer { sqlite3_finalize(statement) }
            try store.bindText(statement, index: 1, value: store.workspaceID)
            try store.bindText(statement, index: 2, value: excludingObjectID)
            var occupied: [SchedulingTaskSnapshot] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw store.mapSQLiteError(result) }
                let other = try decoder.decode(Record.self, from: Data(store.columnText(statement, index: 0).utf8))
                guard other.schemaVersion == 1 else { throw StorageError.corrupt("unsupported run schema") }
                for task in other.tasks where task.state == .prepared || task.state == .running || task.attemptState?.isActiveOrUncertain == true {
                    guard task.workspaceID.utf8.elementsEqual(store.workspaceID.utf8) else {
                        throw StorageError.corrupt("run workspace mismatch")
                    }
                    occupied.append(task)
                }
            }
            return occupied
        }
    }

    private func makePreparedBinding(
        runID: String,
        identifier: String,
        storeGeneration: String,
        record: Record,
        scheduled: SchedulingTaskSnapshot,
        attemptID: String,
        capabilitySnapshotID: String,
        executionRequestPayloadDigest: String
    ) throws -> PreparedTaskBinding {
        let runtimeTaskID = Self.scopedRuntimeTaskID(runID: runID, taskID: scheduled.taskID)
        let attemptSequence = (record.retryCounts[scheduled.taskID] ?? 0) + 1
        let taskRevision = RevisionRef(
            objectID: runtimeTaskID,
            storeGeneration: storeGeneration,
            revision: String(attemptSequence)
        )
        let instanceRevision = record.instanceRevision ?? RevisionRef(
            objectID: identifier,
            storeGeneration: storeGeneration,
            revision: "1"
        )
        let bindingDigestData = try canonicalSHA256(.object([
            ("domain", .string("oches.scheduler.attempt-binding.v1")),
            ("workspaceID", .string(store.workspaceID)),
            ("runID", .string(runID)),
            ("taskID", .string(scheduled.taskID)),
            ("runtimeTaskID", .string(runtimeTaskID)),
            ("planDigest", .string(record.planDigest.base64EncodedString())),
            ("inputPins", .string(record.inputPins.base64EncodedString())),
            ("instanceObject", .string(instanceRevision.objectID)),
            ("instanceGeneration", .string(instanceRevision.storeGeneration)),
            ("instanceRevision", .string(instanceRevision.revision)),
            ("installationID", .string(scheduled.installationID)),
            ("accountRef", .string(scheduled.accountRef)),
            ("attemptSequence", .number(String(attemptSequence)))
        ]))
        let bindingDigest = bindingDigestData.map { String(format: "%02x", $0) }.joined()
        let reqDigestData = try canonicalSHA256(.object([
            ("domain", .string("oches.scheduler.exec-request.v1")),
            ("bindingDigest", .string(bindingDigest)),
            ("payloadDigest", .string(executionRequestPayloadDigest))
        ]))
        let executionRequestDigest = reqDigestData.map { String(format: "%02x", $0) }.joined()
        return PreparedTaskBinding(
            attemptID: attemptID,
            runtimeTaskID: runtimeTaskID,
            taskRevision: taskRevision,
            instanceRevision: instanceRevision,
            bindingDigest: bindingDigest,
            executionRequestDigest: executionRequestDigest,
            capabilitySnapshotID: capabilitySnapshotID,
            attemptSequence: attemptSequence
        )
    }

    private func fetchAttemptIfPresent(gate: RuntimePrepareAndStartGate, attemptID: String) throws -> ExecutionAttemptRecord? {
        do {
            return try gate.fetchAttempt(attemptID: attemptID)
        } catch RuntimeLifecycleError.invalidState(let msg) where msg == "attempt not found" {
            return nil
        }
    }

    private func verifyAttemptIdentity(
        attempt: ExecutionAttemptRecord,
        runID: String,
        taskID: String,
        scheduled: SchedulingTaskSnapshot,
        binding: PreparedTaskBinding?
    ) throws {
        guard attempt.workspaceID.utf8.elementsEqual(store.workspaceID.utf8),
              attempt.runID.utf8.elementsEqual(runID.utf8),
              attempt.installationID.utf8.elementsEqual(scheduled.installationID.utf8),
              attempt.accountRef.utf8.elementsEqual(scheduled.accountRef.utf8) else {
            throw StorageError.denied
        }
        if let binding {
            guard attempt.attemptID.utf8.elementsEqual(binding.attemptID.utf8),
                  attempt.taskID.utf8.elementsEqual(binding.runtimeTaskID.utf8),
                  attempt.taskRevision == binding.taskRevision,
                  attempt.instanceRevision == binding.instanceRevision,
                  attempt.bindingDigest.utf8.elementsEqual(binding.bindingDigest.utf8),
                  attempt.executionRequestDigest.utf8.elementsEqual(binding.executionRequestDigest.utf8),
                  attempt.snapshotID.utf8.elementsEqual(binding.capabilitySnapshotID.utf8) else {
                throw StorageError.denied
            }
        } else {
            guard attempt.taskID.utf8.elementsEqual(taskID.utf8) else {
                throw StorageError.denied
            }
        }
    }

    private func updatedTask(
        _ task: SchedulingTaskSnapshot,
        state: TaskLifecycleState,
        attemptState: ExecutionAttemptState?
    ) -> SchedulingTaskSnapshot {
        SchedulingTaskSnapshot(
            taskID: task.taskID,
            workspaceID: task.workspaceID,
            state: state,
            attemptState: attemptState,
            enqueueSequence: task.enqueueSequence,
            installationID: task.installationID,
            accountRef: task.accountRef,
            isolation: task.isolation,
            exclusiveResourceIDs: task.exclusiveResourceIDs
        )
    }

    private func updatingRecord(
        _ record: Record,
        tasks: [SchedulingTaskSnapshot]? = nil,
        reservations: [String: String]? = nil,
        preparedAttempts: [String: PreparedTaskBinding]? = nil,
        retryCounts: [String: Int]? = nil,
        lastFailureTimestamps: [String: Int64]? = nil,
        attemptHistory: [String: [String]]? = nil,
        evaluatedSnapshots: [String: EvaluatedSnapshotBinding]? = nil
    ) -> Record {
        Record(
            schemaVersion: record.schemaVersion,
            inputPins: record.inputPins,
            planDigest: record.planDigest,
            instanceRevision: record.instanceRevision,
            tasks: tasks ?? record.tasks,
            dependencies: record.dependencies,
            reservations: reservations ?? record.reservations,
            preparedAttempts: preparedAttempts ?? record.preparedAttempts,
            retryCounts: retryCounts ?? record.retryCounts,
            lastFailureTimestamps: lastFailureTimestamps ?? record.lastFailureTimestamps,
            attemptHistory: attemptHistory ?? record.attemptHistory,
            evaluatedSnapshots: evaluatedSnapshots ?? record.evaluatedSnapshots
        )
    }

    private func commit(
        _ record: Record,
        runID: String,
        expected: RevisionRef?,
        operation: String,
        actorID: String,
        requestID: String,
        response: String,
        now: Int64,
        details: RawJSONValue = .object([])
    ) throws -> TransitionResult {
        let payload = try encode(record)
        let request = TransitionRequest(
            actorID: actorID,
            workspaceID: store.workspaceID,
            operation: operation,
            requestID: requestID,
            objectID: try objectID(runID),
            ownerModule: "ARC-07",
            expectedRevision: expected,
            normalizedInput: .object([
                ("planDigest", .string(record.planDigest.base64EncodedString())),
                ("inputPins", .string(record.inputPins.base64EncodedString())),
                ("details", details)
            ]),
            nextStateJSON: String(decoding: payload, as: UTF8.self),
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-07", kind: operation, payloadJSON: "{}", observedAt: now)],
            responseJSON: response,
            nowEpochSeconds: now
        )
        return try operation == "run.reserve" ? store.commitSchedulerReservation(request) : store.commitTransition(request)
    }

    static func validateWorkspaceReservation(_ request: TransitionRequest, store: SQLiteStore) throws {
        let decoder = JSONDecoder()
        let proposed = try decoder.decode(Record.self, from: Data(request.nextStateJSON.utf8))
        guard proposed.schemaVersion == 1 else { throw StorageError.corrupt("unsupported run schema") }
        func occupied(_ tasks: [SchedulingTaskSnapshot]) -> [SchedulingTaskSnapshot] {
            tasks.filter { $0.state == .prepared || $0.state == .running || $0.attemptState?.isActiveOrUncertain == true }
        }
        var tasks = occupied(proposed.tasks)
        let statement = try store.prepare("SELECT state_json FROM operational_state WHERE workspace_id = ? AND owner_module = 'ARC-07' AND substr(object_id, 1, 10) = 'arc07/run/' AND object_id != ?")
        defer { sqlite3_finalize(statement) }
        try store.bindText(statement, index: 1, value: request.workspaceID)
        try store.bindText(statement, index: 2, value: request.objectID)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw StorageError.unavailable("cannot inspect workspace reservations") }
            let other = try decoder.decode(Record.self, from: Data(store.columnText(statement, index: 0).utf8))
            guard other.schemaVersion == 1 else { throw StorageError.corrupt("unsupported run schema") }
            tasks.append(contentsOf: occupied(other.tasks))
            guard tasks.count <= 4 else { throw StorageError.busy }
        }
        guard tasks.count <= 4 else { throw StorageError.busy }
        struct Account: Hashable { let installation: Data; let account: Data }
        var accounts: [Account: Bool] = [:]
        var resources = Set<Data>()
        for task in tasks {
            guard task.workspaceID.utf8.elementsEqual(request.workspaceID.utf8) else { throw StorageError.corrupt("run workspace mismatch") }
            let key = Account(installation: Data(task.installationID.utf8), account: Data(task.accountRef.utf8))
            if let isolated = accounts[key], !isolated || task.isolation != .supported { throw StorageError.busy }
            accounts[key] = (accounts[key] ?? true) && task.isolation == .supported
            let required = Set(task.exclusiveResourceIDs.map { Data($0.utf8) })
            guard resources.isDisjoint(with: required) else { throw StorageError.busy }
            resources.formUnion(required)
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func objectID(_ value: String) throws -> String {
        guard value.utf8.count <= 128, value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil
        else { throw StorageError.invalidInput }
        return "arc07/run/" + value
    }
}
