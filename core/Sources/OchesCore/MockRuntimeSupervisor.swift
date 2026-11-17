import Foundation
import SQLite3

public struct ProcessIdentity: Sendable, Equatable, Codable {
    public let pid: Int32
    public let processStartToken: String
    public let attemptID: String

    public init(pid: Int32, processStartToken: String, attemptID: String) {
        self.pid = pid
        self.processStartToken = processStartToken
        self.attemptID = attemptID
    }
}

public enum MockSpawnBehavior: Sendable, Equatable {
    case succeedNormally
    case crashBeforeSpawnConfirmation
    case crashAfterSpawnBeforeRunningCommit
    case delaySpawnUntilCancelRace
    case emitEventsWithOutputLoss(emittedCount: Int, droppedCount: Int, truncated: Bool)
}

public struct RuntimeEventRecord: Sendable, Equatable {
    public let sequence: UInt64
    public let attemptID: String
    public let eventID: String
    public let kind: String
    public let payloadJSON: String
    public let observedAt: Int64
}

public struct RuntimeObservationPage: Sendable, Equatable {
    public let attempt: ExecutionAttemptRecord
    public let events: [RuntimeEventRecord]
    public let nextCursorSequence: UInt64
    public let outputTruncated: Bool
    public let droppedEventsCount: Int
}

public final class MockRuntimeAdapter: @unchecked Sendable {
    public struct LiveProcessState: Sendable {
        public let identity: ProcessIdentity
        public var alive: Bool
        public var terminatedByCancel: Bool
        public var exitCode: Int32?
    }

    private let lock = NSLock()
    private var nextPID: Int32 = 41000
    public private(set) var spawnCallCount: Int = 0
    private var processesByPID: [Int32: LiveProcessState] = [:]
    private var pendingBehaviorByAttempt: [String: MockSpawnBehavior] = [:]
    private var cancelWinOnRaceByAttempt: [String: Bool] = [:]

    public init() {}

    public func setBehavior(_ behavior: MockSpawnBehavior, forAttemptID attemptID: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingBehaviorByAttempt[attemptID] = behavior
    }

    /// Configures whether cancel terminates the process before normal exit wins (`true`)
    /// or normal exit completes while cancel is racing (`false`).
    public func setCancelRaceOutcome(cancelWins: Bool, forAttemptID attemptID: String) {
        lock.lock()
        defer { lock.unlock() }
        cancelWinOnRaceByAttempt[attemptID] = cancelWins
    }

    public func behavior(forAttemptID attemptID: String) -> MockSpawnBehavior {
        lock.lock()
        defer { lock.unlock() }
        return pendingBehaviorByAttempt[attemptID] ?? .succeedNormally
    }

    public func spawn(attemptID: String) -> ProcessIdentity {
        lock.lock()
        defer { lock.unlock() }
        spawnCallCount += 1
        nextPID += 1
        let identity = ProcessIdentity(
            pid: nextPID,
            processStartToken: "tok-\(attemptID)-\(UUID().uuidString.lowercased())",
            attemptID: attemptID
        )
        processesByPID[identity.pid] = LiveProcessState(
            identity: identity,
            alive: true,
            terminatedByCancel: false,
            exitCode: nil
        )
        return identity
    }

    /// Simulates OS PID reuse by replacing the process at `pid` with a different `processStartToken` / `attemptID`.
    public func simulatePIDReuse(pid: Int32, newToken: String, otherAttemptID: String) {
        lock.lock()
        defer { lock.unlock() }
        processesByPID[pid] = LiveProcessState(
            identity: ProcessIdentity(pid: pid, processStartToken: newToken, attemptID: otherAttemptID),
            alive: true,
            terminatedByCancel: false,
            exitCode: nil
        )
    }

    public func isSameLiveProcess(_ expected: ProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let live = processesByPID[expected.pid] else { return false }
        return live.alive && live.identity == expected
    }

    public func signalTermination(expected: ProcessIdentity) -> RuntimeObservationEvent {
        lock.lock()
        defer { lock.unlock() }
        guard var live = processesByPID[expected.pid], live.identity == expected else {
            return .outcomeUnknown
        }
        let cancelWins = cancelWinOnRaceByAttempt[expected.attemptID] ?? true
        live.alive = false
        if cancelWins {
            live.terminatedByCancel = true
            live.exitCode = -15
            processesByPID[expected.pid] = live
            return .cancelExitConfirmed
        } else {
            live.terminatedByCancel = false
            live.exitCode = 0
            processesByPID[expected.pid] = live
            return .normalExitConfirmed
        }
    }

    public func completeNormally(expected: ProcessIdentity) -> RuntimeObservationEvent {
        lock.lock()
        defer { lock.unlock() }
        guard var live = processesByPID[expected.pid], live.identity == expected else {
            return .outcomeUnknown
        }
        live.alive = false
        live.terminatedByCancel = false
        live.exitCode = 0
        processesByPID[expected.pid] = live
        return .normalExitConfirmed
    }
}

public final class RuntimeSessionManager: @unchecked Sendable {
    public let store: SQLiteStore
    public let gate: RuntimePrepareAndStartGate
    public let adapter: MockRuntimeAdapter
    private let evaluator = CapabilityEvaluator()
    private let lock = NSLock()

    public init(store: SQLiteStore, gate: RuntimePrepareAndStartGate, adapter: MockRuntimeAdapter) {
        self.store = store
        self.gate = gate
        self.adapter = adapter
    }

    public func prepare(_ input: PrepareAttemptInput) throws -> ExecutionAttemptRecord {
        try gate.prepare(input)
    }

    public func start(_ input: StartAttemptInput) throws -> ExecutionAttemptRecord {
        let (_, shouldSpawn) = try gate.commitPreSpawnStart(input)
        guard shouldSpawn else {
            return try gate.fetchAttempt(attemptID: input.attemptID)
        }

        let behavior = adapter.behavior(forAttemptID: input.attemptID)
        switch behavior {
        case .crashBeforeSpawnConfirmation:
            try applyObservedTransition(
                attemptID: input.attemptID,
                event: .spawnOutcomeUnknown,
                pid: nil,
                token: nil,
                nowEpochSeconds: input.nowEpochSeconds
            )
            return try gate.fetchAttempt(attemptID: input.attemptID)

        case .delaySpawnUntilCancelRace:
            // Remain in Starting until cancel or subsequent spawn confirmation arrives
            return try gate.fetchAttempt(attemptID: input.attemptID)

        case .crashAfterSpawnBeforeRunningCommit:
            _ = adapter.spawn(attemptID: input.attemptID)
            try applyObservedTransition(
                attemptID: input.attemptID,
                event: .spawnOutcomeUnknown,
                pid: nil,
                token: nil,
                nowEpochSeconds: input.nowEpochSeconds
            )
            return try gate.fetchAttempt(attemptID: input.attemptID)

        case .emitEventsWithOutputLoss(let emitted, let dropped, let truncated):
            let identity = adapter.spawn(attemptID: input.attemptID)
            try applyObservedTransition(
                attemptID: input.attemptID,
                event: .spawnConfirmed,
                pid: identity.pid,
                token: identity.processStartToken,
                nowEpochSeconds: input.nowEpochSeconds
            )
            try recordEmittedEvents(
                attemptID: input.attemptID,
                emittedCount: emitted,
                droppedCount: dropped,
                truncated: truncated,
                nowEpochSeconds: input.nowEpochSeconds
            )
            return try gate.fetchAttempt(attemptID: input.attemptID)

        case .succeedNormally:
            let identity = adapter.spawn(attemptID: input.attemptID)
            try applyObservedTransition(
                attemptID: input.attemptID,
                event: .spawnConfirmed,
                pid: identity.pid,
                token: identity.processStartToken,
                nowEpochSeconds: input.nowEpochSeconds
            )
            return try gate.fetchAttempt(attemptID: input.attemptID)
        }
    }

    /// Confirms delayed spawn during `Starting` or `CancelRequested` (`C04`).
    /// If already `CancelRequested`, terminates the newly observed process -> `Cancelled`.
    public func confirmDelayedSpawn(attemptID: String, nowEpochSeconds: Int64) throws -> ExecutionAttemptRecord {
        let current = try gate.fetchAttempt(attemptID: attemptID)
        let identity = adapter.spawn(attemptID: attemptID)
        try applyObservedTransition(
            attemptID: attemptID,
            event: .spawnConfirmed,
            pid: identity.pid,
            token: identity.processStartToken,
            nowEpochSeconds: nowEpochSeconds
        )
        if current.state == .cancelRequested {
            let termEvent = adapter.signalTermination(expected: identity)
            try applyObservedTransition(
                attemptID: attemptID,
                event: termEvent,
                pid: identity.pid,
                token: identity.processStartToken,
                nowEpochSeconds: nowEpochSeconds + 1
            )
        }
        return try gate.fetchAttempt(attemptID: attemptID)
    }

    /// Requests cancellation; marks `CancelRequested` (or `Cancelled` if `Prepared`), never claiming
    /// `Cancelled` prior to actual process termination confirmation.
    public func cancel(attemptID: String, resolveImmediatelyIfRunning: Bool = true, nowEpochSeconds: Int64) throws -> ExecutionAttemptRecord {
        let current = try gate.fetchAttempt(attemptID: attemptID)
        if current.state == .prepared {
            try applyObservedTransition(
                attemptID: attemptID,
                event: .cancelBeforeSpawn,
                pid: nil,
                token: nil,
                nowEpochSeconds: nowEpochSeconds
            )
            return try gate.fetchAttempt(attemptID: attemptID)
        }

        try applyObservedTransition(
            attemptID: attemptID,
            event: .cancelRequested,
            pid: current.pid,
            token: current.processStartToken,
            nowEpochSeconds: nowEpochSeconds
        )

        if resolveImmediatelyIfRunning,
           current.state == .running,
           let pid = current.pid,
           let token = current.processStartToken {
            let termEvent = adapter.signalTermination(
                expected: ProcessIdentity(pid: pid, processStartToken: token, attemptID: attemptID)
            )
            try applyObservedTransition(
                attemptID: attemptID,
                event: termEvent,
                pid: pid,
                token: token,
                nowEpochSeconds: nowEpochSeconds + 1
            )
        }

        return try gate.fetchAttempt(attemptID: attemptID)
    }

    public func completeProcessNormally(attemptID: String, nowEpochSeconds: Int64) throws -> ExecutionAttemptRecord {
        let current = try gate.fetchAttempt(attemptID: attemptID)
        guard let pid = current.pid, let token = current.processStartToken else {
            throw RuntimeLifecycleError.invalidState("no confirmed process identity")
        }
        let ev = adapter.completeNormally(expected: ProcessIdentity(pid: pid, processStartToken: token, attemptID: attemptID))
        try applyObservedTransition(attemptID: attemptID, event: ev, pid: pid, token: token, nowEpochSeconds: nowEpochSeconds)
        return try gate.fetchAttempt(attemptID: attemptID)
    }

    public func inspect(attemptID: String) throws -> (attempt: ExecutionAttemptRecord, taskState: TaskLifecycleState) {
        let attempt = try gate.fetchAttempt(attemptID: attemptID)
        let taskState = try gate.fetchTaskState(taskID: attempt.taskID)
        return (attempt, taskState)
    }

    public func observe(attemptID: String, afterSequence: UInt64 = 0) throws -> RuntimeObservationPage {
        let attempt = try gate.fetchAttempt(attemptID: attemptID)
        let events = try store.withConnectionLock { _ -> [RuntimeEventRecord] in
            let stmt = try store.prepare(
                "SELECT seq, attempt_id, event_id, kind, payload_json, observed_at FROM runtime_events WHERE attempt_id = ? AND seq > ? ORDER BY seq ASC"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: attemptID)
            sqlite3_bind_int64(stmt, 2, Int64(bitPattern: afterSequence))
            var out: [RuntimeEventRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(RuntimeEventRecord(
                    sequence: UInt64(bitPattern: sqlite3_column_int64(stmt, 0)),
                    attemptID: store.columnText(stmt, index: 1),
                    eventID: store.columnText(stmt, index: 2),
                    kind: store.columnText(stmt, index: 3),
                    payloadJSON: store.columnText(stmt, index: 4),
                    observedAt: sqlite3_column_int64(stmt, 5)
                ))
            }
            return out
        }
        let nextSeq = events.last?.sequence ?? afterSequence
        return RuntimeObservationPage(
            attempt: attempt,
            events: events,
            nextCursorSequence: nextSeq,
            outputTruncated: attempt.outputTruncated,
            droppedEventsCount: attempt.droppedEventsCount
        )
    }

    /// Reconciles active/uncertain attempts on restart. Rejects PID reuse (different `processStartToken`)
    /// and transitions unconfirmed attempts to `Unknown` (`Task Blocked`) with 0 automatic restarts (`V-06`).
    public func reconcileOnRestart(nowEpochSeconds: Int64) throws -> [ExecutionAttemptRecord] {
        let candidateIDs = try store.withConnectionLock { _ -> [String] in
            let stmt = try store.prepare(
                "SELECT attempt_id FROM execution_attempts WHERE state IN ('Starting', 'Running', 'CancelRequested', 'Unknown')"
            )
            defer { sqlite3_finalize(stmt) }
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(store.columnText(stmt, index: 0))
            }
            return ids
        }

        var reconciled: [ExecutionAttemptRecord] = []
        for id in candidateIDs {
            let attempt = try gate.fetchAttempt(attemptID: id)
            if let pid = attempt.pid, let token = attempt.processStartToken {
                let expected = ProcessIdentity(pid: pid, processStartToken: token, attemptID: attempt.attemptID)
                if adapter.isSameLiveProcess(expected) {
                    if attempt.state == .unknown {
                        try applyObservedTransition(
                            attemptID: id,
                            event: .liveProcessIdentityConfirmed,
                            pid: pid,
                            token: token,
                            nowEpochSeconds: nowEpochSeconds
                        )
                    }
                    reconciled.append(try gate.fetchAttempt(attemptID: id))
                    continue
                }
            }
            if attempt.state != .unknown {
                let event: RuntimeObservationEvent = attempt.state == .starting ? .spawnOutcomeUnknown : .outcomeUnknown
                try applyObservedTransition(attemptID: id, event: event, pid: nil, token: nil, nowEpochSeconds: nowEpochSeconds)
            }
            reconciled.append(try gate.fetchAttempt(attemptID: id))
        }
        return reconciled
    }

    /// Resumes only from a confirmed terminal attempt (never from `Unknown` or active states)
    /// when `run.resume == .supported`, creating a newly prepared attempt (`attemptID`) that must still
    /// obtain fresh execution approval before `start` (`CV09`).
    public func prepareResume(
        previousAttemptID: String,
        newPrepareInput: PrepareAttemptInput
    ) throws -> ExecutionAttemptRecord {
        let prev = try gate.fetchAttempt(attemptID: previousAttemptID)
        guard prev.state.isTerminal else {
            throw RuntimeLifecycleError.resumeUnsupported("previous attempt \(previousAttemptID) is not in a confirmed terminal state (\(prev.state.rawValue))")
        }
        let resumeGate = evaluator.evaluate(
            snapshot: newPrepareInput.snapshot,
            requestedScope: newPrepareInput.requestedScope,
            requiredCapabilities: [.providerInstall, .authOfficial, .runStart, .runResume]
        )
        guard resumeGate == .supported else {
            throw RuntimeLifecycleError.resumeUnsupported("run.resume capability not supported: \(resumeGate)")
        }
        return try gate.prepare(newPrepareInput)
    }

    // MARK: - Private SQLite transitions

    private func applyObservedTransition(
        attemptID: String,
        event: RuntimeObservationEvent,
        pid: Int32?,
        token: String?,
        nowEpochSeconds: Int64
    ) throws {
        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let current = try gate.fetchAttemptInTx(attemptID: attemptID)
                let nextState = try transitionAttemptState(from: current.state, event: event)
                let upd = try store.prepare(
                    "UPDATE execution_attempts SET state = ?, pid = COALESCE(?, pid), process_start_token = COALESCE(?, process_start_token) WHERE attempt_id = ?"
                )
                defer { sqlite3_finalize(upd) }
                try store.bindText(upd, index: 1, value: nextState.rawValue)
                if let pid {
                    sqlite3_bind_int(upd, 2, pid)
                } else {
                    sqlite3_bind_null(upd, 2)
                }
                if let token {
                    try store.bindText(upd, index: 3, value: token)
                } else {
                    sqlite3_bind_null(upd, 3)
                }
                try store.bindText(upd, index: 4, value: attemptID)
                guard sqlite3_step(upd) == SQLITE_DONE else {
                    throw RuntimeLifecycleError.storageFailure("update attempt failed")
                }

                let updTask = try store.prepare("UPDATE tasks SET state = ? WHERE task_id = ?")
                defer { sqlite3_finalize(updTask) }
                try store.bindText(updTask, index: 1, value: derivedTaskState(for: nextState).rawValue)
                try store.bindText(updTask, index: 2, value: current.taskID)
                guard sqlite3_step(updTask) == SQLITE_DONE else {
                    throw RuntimeLifecycleError.storageFailure("update task failed")
                }

                let ev = try store.prepare(
                    "INSERT INTO runtime_events (attempt_id, event_id, kind, payload_json, observed_at) VALUES (?, ?, ?, '{}', ?)"
                )
                defer { sqlite3_finalize(ev) }
                try store.bindText(ev, index: 1, value: attemptID)
                try store.bindText(ev, index: 2, value: "rt-evt-\(UUID().uuidString.lowercased())")
                try store.bindText(ev, index: 3, value: event.rawValue)
                sqlite3_bind_int64(ev, 4, nowEpochSeconds)
                guard sqlite3_step(ev) == SQLITE_DONE else {
                    throw RuntimeLifecycleError.storageFailure("insert runtime_event failed")
                }

                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    private func recordEmittedEvents(
        attemptID: String,
        emittedCount: Int,
        droppedCount: Int,
        truncated: Bool,
        nowEpochSeconds: Int64
    ) throws {
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                for i in 0..<emittedCount {
                    let stmt = try store.prepare(
                        "INSERT INTO runtime_events (attempt_id, event_id, kind, payload_json, observed_at) VALUES (?, ?, 'output.chunk', ?, ?)"
                    )
                    defer { sqlite3_finalize(stmt) }
                    try store.bindText(stmt, index: 1, value: attemptID)
                    try store.bindText(stmt, index: 2, value: "chunk-\(attemptID)-\(i)")
                    try store.bindText(stmt, index: 3, value: "{\"chunk\":\(i)}")
                    sqlite3_bind_int64(stmt, 4, nowEpochSeconds + Int64(i))
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw RuntimeLifecycleError.storageFailure("insert chunk event failed")
                    }
                }

                let upd = try store.prepare(
                    "UPDATE execution_attempts SET output_truncated = ?, dropped_events_count = ? WHERE attempt_id = ?"
                )
                defer { sqlite3_finalize(upd) }
                sqlite3_bind_int(upd, 1, truncated ? 1 : 0)
                sqlite3_bind_int(upd, 2, Int32(droppedCount))
                try store.bindText(upd, index: 3, value: attemptID)
                guard sqlite3_step(upd) == SQLITE_DONE else {
                    throw RuntimeLifecycleError.storageFailure("update loss markers failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }
}
