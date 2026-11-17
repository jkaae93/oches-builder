import Foundation
import SQLite3

public final class RuntimePrepareAndStartGate: @unchecked Sendable {
    public let store: SQLiteStore
    private let evaluator = CapabilityEvaluator()

    public init(store: SQLiteStore) throws {
        self.store = store
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                task_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                state TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS execution_attempts (
                attempt_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                task_revision_json TEXT NOT NULL,
                instance_revision_json TEXT NOT NULL,
                installation_id TEXT NOT NULL,
                account_ref TEXT NOT NULL,
                binding_digest TEXT NOT NULL,
                execution_request_digest TEXT NOT NULL,
                snapshot_id TEXT NOT NULL,
                state TEXT NOT NULL,
                pid INTEGER,
                process_start_token TEXT,
                start_request_id TEXT,
                output_truncated INTEGER NOT NULL DEFAULT 0,
                dropped_events_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS runtime_events (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                attempt_id TEXT NOT NULL,
                event_id TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                observed_at INTEGER NOT NULL
            );
            """
        )
    }

    /// Reserves a `Prepared` attempt in SQLite without execution approval and spawns 0 processes.
    public func prepare(_ input: PrepareAttemptInput) throws -> ExecutionAttemptRecord {
        guard input.workspaceID == store.workspaceID else {
            throw RuntimeLifecycleError.permissionDenied("workspace mismatch")
        }
        guard input.callerScopes.contains(.runRequest) else {
            throw RuntimeLifecycleError.permissionDenied("missing run:request scope")
        }
        let gate = evaluator.evaluate(
            snapshot: input.snapshot,
            requestedScope: input.requestedScope,
            requiredCapabilities: [.providerInstall, .authOfficial, .runStart]
        )
        guard gate == .supported else {
            throw RuntimeLifecycleError.capabilityBlocked("prepare capability gate: \(gate)")
        }

        let activeOtherCount = try countActiveOrUnknownAttempts(excludingAttemptID: input.attemptID)
        let isoGate = evaluator.evaluateConcurrentAccountIsolation(
            snapshot: input.snapshot,
            requestedScope: input.requestedScope,
            otherActiveAttemptCount: activeOtherCount
        )
        guard isoGate == .supported else {
            throw RuntimeLifecycleError.capabilityBlocked("concurrent account isolation blocked")
        }

        let taskRevData = try JSONEncoder().encode(input.taskRevision)
        let instRevData = try JSONEncoder().encode(input.instanceRevision)
        let taskRevJSON = String(decoding: taskRevData, as: UTF8.self)
        let instRevJSON = String(decoding: instRevData, as: UTF8.self)

        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let tStmt = try store.prepare(
                    "INSERT OR REPLACE INTO tasks (task_id, workspace_id, revision, state) VALUES (?, ?, ?, ?)"
                )
                defer { sqlite3_finalize(tStmt) }
                try store.bindText(tStmt, index: 1, value: input.taskID)
                try store.bindText(tStmt, index: 2, value: input.workspaceID)
                sqlite3_bind_int64(tStmt, 3, Int64(input.taskRevision.revision) ?? 1)
                try store.bindText(tStmt, index: 4, value: TaskLifecycleState.prepared.rawValue)
                guard sqlite3_step(tStmt) == SQLITE_DONE else {
                    throw RuntimeLifecycleError.storageFailure("upsert task failed")
                }

                let aStmt = try store.prepare(
                    """
                    INSERT INTO execution_attempts (
                        attempt_id, workspace_id, run_id, task_id, task_revision_json, instance_revision_json,
                        installation_id, account_ref, binding_digest, execution_request_digest, snapshot_id, state
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(aStmt) }
                try store.bindText(aStmt, index: 1, value: input.attemptID)
                try store.bindText(aStmt, index: 2, value: input.workspaceID)
                try store.bindText(aStmt, index: 3, value: input.runID)
                try store.bindText(aStmt, index: 4, value: input.taskID)
                try store.bindText(aStmt, index: 5, value: taskRevJSON)
                try store.bindText(aStmt, index: 6, value: instRevJSON)
                try store.bindText(aStmt, index: 7, value: input.installationID)
                try store.bindText(aStmt, index: 8, value: input.accountRef)
                try store.bindText(aStmt, index: 9, value: input.bindingDigest)
                try store.bindText(aStmt, index: 10, value: input.executionRequestDigest)
                try store.bindText(aStmt, index: 11, value: input.snapshot.snapshotID)
                try store.bindText(aStmt, index: 12, value: ExecutionAttemptState.prepared.rawValue)
                guard sqlite3_step(aStmt) == SQLITE_DONE else {
                    throw RuntimeLifecycleError.storageFailure("insert prepared attempt failed")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }

        return try fetchAttempt(attemptID: input.attemptID)
    }

    /// Commits `Prepared -> Starting` and consumes execution (+ optional external transfer) approvals
    /// atomically in SQLite BEFORE allowing process spawn. Returns `(record, shouldSpawn: false)` if
    /// the same `requestID` already started/entered `Unknown`.
    public func commitPreSpawnStart(_ input: StartAttemptInput) throws -> (record: ExecutionAttemptRecord, shouldSpawn: Bool) {
        let gate = evaluator.evaluate(
            snapshot: input.snapshot,
            requestedScope: input.requestedScope,
            requiredCapabilities: [.providerInstall, .authOfficial, .runStart]
        )
        guard gate == .supported else {
            throw RuntimeLifecycleError.capabilityBlocked("start capability gate: \(gate)")
        }

        let activeOtherCount = try countActiveOrUnknownAttempts(excludingAttemptID: input.attemptID)
        let isoGate = evaluator.evaluateConcurrentAccountIsolation(
            snapshot: input.snapshot,
            requestedScope: input.requestedScope,
            otherActiveAttemptCount: activeOtherCount
        )
        guard isoGate == .supported else {
            throw RuntimeLifecycleError.capabilityBlocked("concurrent account isolation blocked")
        }

        let shouldSpawn: Bool = try store.withConnectionLock { db in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let attempt = try fetchAttemptInTx(attemptID: input.attemptID)
                // Idempotent duplicate requestID on Starting / Unknown / active attempt -> NO new spawn (FC-04 / X11)
                if attempt.startRequestID == input.requestID && attempt.state != .prepared {
                    _ = try? store.execute("ROLLBACK")
                    return false
                }
                guard attempt.state == .prepared else {
                    throw RuntimeLifecycleError.illegalTransition(from: attempt.state, event: .startRecorded)
                }

                // Validate & consume execution approval bound to this preparedAttemptID
                try consumeApprovalInTx(
                    db: db,
                    approvalID: input.executionApprovalID,
                    expectedKind: .execution,
                    clientID: input.clientID,
                    workspaceID: attempt.workspaceID,
                    attempt: attempt,
                    nowEpochSeconds: input.nowEpochSeconds
                )

                // If external transfer is required, validate & consume separate EXTERNAL_TRANSFER approval (FC-03)
                if input.requiresExternalTransfer {
                    guard let transferID = input.transferApprovalID else {
                        throw RuntimeLifecycleError.approvalRequired([.externalTransfer])
                    }
                    try consumeApprovalInTx(
                        db: db,
                        approvalID: transferID,
                        expectedKind: .externalTransfer,
                        clientID: input.clientID,
                        workspaceID: attempt.workspaceID,
                        attempt: attempt,
                        nowEpochSeconds: input.nowEpochSeconds
                    )
                }

                let nextAttemptState = try transitionAttemptState(from: attempt.state, event: .startRecorded)
                let updAttempt = try store.prepare(
                    "UPDATE execution_attempts SET state = ?, start_request_id = ? WHERE attempt_id = ? AND state = 'Prepared'"
                )
                defer { sqlite3_finalize(updAttempt) }
                try store.bindText(updAttempt, index: 1, value: nextAttemptState.rawValue)
                try store.bindText(updAttempt, index: 2, value: input.requestID)
                try store.bindText(updAttempt, index: 3, value: input.attemptID)
                guard sqlite3_step(updAttempt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                    throw RuntimeLifecycleError.storageFailure("failed to transition attempt to Starting")
                }

                let updTask = try store.prepare("UPDATE tasks SET state = ? WHERE task_id = ?")
                defer { sqlite3_finalize(updTask) }
                try store.bindText(updTask, index: 1, value: derivedTaskState(for: nextAttemptState).rawValue)
                try store.bindText(updTask, index: 2, value: attempt.taskID)
                guard sqlite3_step(updTask) == SQLITE_DONE else {
                    throw RuntimeLifecycleError.storageFailure("failed to update task state")
                }

                try store.execute("COMMIT")
                return true
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }

        return (try fetchAttempt(attemptID: input.attemptID), shouldSpawn)
    }

    public func fetchAttempt(attemptID: String) throws -> ExecutionAttemptRecord {
        try store.withConnectionLock { _ in
            try fetchAttemptInTx(attemptID: attemptID)
        }
    }

    public func fetchTaskState(taskID: String) throws -> TaskLifecycleState {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare("SELECT state FROM tasks WHERE task_id = ?")
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: taskID)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw RuntimeLifecycleError.invalidState("task not found")
            }
            return TaskLifecycleState(rawValue: store.columnText(stmt, index: 0)) ?? .blocked
        }
    }

    public func countActiveOrUnknownAttempts(excludingAttemptID: String) throws -> Int {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                "SELECT COUNT(*) FROM execution_attempts WHERE attempt_id != ? AND state IN ('Starting', 'Running', 'CancelRequested', 'Unknown')"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: excludingAttemptID)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func fetchAttemptInTx(attemptID: String) throws -> ExecutionAttemptRecord {
        let stmt = try store.prepare(
            """
            SELECT attempt_id, workspace_id, run_id, task_id, task_revision_json, instance_revision_json,
                   installation_id, account_ref, binding_digest, execution_request_digest, snapshot_id,
                   state, pid, process_start_token, start_request_id, output_truncated, dropped_events_count
            FROM execution_attempts WHERE attempt_id = ?
            """
        )
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: attemptID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw RuntimeLifecycleError.invalidState("attempt not found")
        }
        let taskRev = try JSONDecoder().decode(RevisionRef.self, from: Data(store.columnText(stmt, index: 4).utf8))
        let instRev = try JSONDecoder().decode(RevisionRef.self, from: Data(store.columnText(stmt, index: 5).utf8))
        let pid = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : sqlite3_column_int(stmt, 12)
        let startTok = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : store.columnText(stmt, index: 13)
        let reqID = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : store.columnText(stmt, index: 14)
        return ExecutionAttemptRecord(
            attemptID: store.columnText(stmt, index: 0),
            workspaceID: store.columnText(stmt, index: 1),
            runID: store.columnText(stmt, index: 2),
            taskID: store.columnText(stmt, index: 3),
            taskRevision: taskRev,
            instanceRevision: instRev,
            installationID: store.columnText(stmt, index: 6),
            accountRef: store.columnText(stmt, index: 7),
            bindingDigest: store.columnText(stmt, index: 8),
            executionRequestDigest: store.columnText(stmt, index: 9),
            snapshotID: store.columnText(stmt, index: 10),
            state: ExecutionAttemptState(rawValue: store.columnText(stmt, index: 11)) ?? .unknown,
            pid: pid,
            processStartToken: startTok,
            startRequestID: reqID,
            outputTruncated: sqlite3_column_int(stmt, 15) != 0,
            droppedEventsCount: Int(sqlite3_column_int(stmt, 16))
        )
    }

    private func consumeApprovalInTx(
        db: OpaquePointer,
        approvalID: String,
        expectedKind: ApprovalKind,
        clientID: String,
        workspaceID: String,
        attempt: ExecutionAttemptRecord,
        nowEpochSeconds: Int64
    ) throws {
        let stmt = try store.prepare(
            "SELECT kind, subject_client_id, workspace_id, binding_json, issued_at, expires_at, status, consumed FROM approvals WHERE approval_id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: approvalID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw RuntimeLifecycleError.approvalRequired([expectedKind])
        }
        let kindStr = store.columnText(stmt, index: 0)
        let subject = store.columnText(stmt, index: 1)
        let ws = store.columnText(stmt, index: 2)
        let bindingJSON = store.columnText(stmt, index: 3)
        let issuedAt = sqlite3_column_int64(stmt, 4)
        let expiresAt = sqlite3_column_int64(stmt, 5)
        let status = store.columnText(stmt, index: 6)
        let consumed = sqlite3_column_int(stmt, 7)

        guard kindStr == expectedKind.rawValue,
              subject == clientID,
              ws == workspaceID,
              status == ApprovalStatus.approved.rawValue,
              consumed == 0,
              issuedAt < expiresAt,
              nowEpochSeconds >= issuedAt,
              nowEpochSeconds < expiresAt else {
            throw RuntimeLifecycleError.approvalRequired([expectedKind])
        }

        guard let binding = try? JSONDecoder().decode(ApprovalBinding.self, from: Data(bindingJSON.utf8)),
              binding.isValid(for: expectedKind) else {
            throw RuntimeLifecycleError.approvalRequired([expectedKind])
        }

        if expectedKind == .execution {
            guard binding.preparedAttemptID == attempt.attemptID,
                  binding.runID == attempt.runID,
                  binding.taskRevision == attempt.taskRevision,
                  binding.executionRequestDigest == attempt.executionRequestDigest else {
                throw RuntimeLifecycleError.permissionDenied("execution approval mismatch with prepared attempt")
            }
        }

        let upd = try store.prepare("UPDATE approvals SET consumed = 1 WHERE approval_id = ? AND consumed = 0")
        defer { sqlite3_finalize(upd) }
        try store.bindText(upd, index: 1, value: approvalID)
        guard sqlite3_step(upd) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw RuntimeLifecycleError.approvalRequired([expectedKind])
        }
    }
}
