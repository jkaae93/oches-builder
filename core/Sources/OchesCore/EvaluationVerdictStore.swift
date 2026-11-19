import Foundation
import SQLite3

public enum EvaluationVerdict: String, Sendable, Equatable, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case indeterminate = "INDETERMINATE"
}

public struct EvaluationVerdictRecord: Sendable, Equatable, Codable {
    public let evaluationID: String
    public let workspaceID: String
    public let runID: String
    public let taskID: String
    public let taskRevision: RevisionRef
    public let attemptID: String
    public let artifactManifestID: String
    public let artifactManifestDigest: String
    public let criteriaID: String
    public let criteriaVersion: String
    public let evaluatorID: String
    public let evaluatorVersion: String
    public let verdict: EvaluationVerdict
    public let policyVersion: UInt64
    public let evaluatedAt: Int64
    public let stale: Bool

    public init(
        evaluationID: String,
        workspaceID: String,
        runID: String,
        taskID: String,
        taskRevision: RevisionRef,
        attemptID: String,
        artifactManifestID: String,
        artifactManifestDigest: String,
        criteriaID: String,
        criteriaVersion: String,
        evaluatorID: String,
        evaluatorVersion: String,
        verdict: EvaluationVerdict,
        policyVersion: UInt64,
        evaluatedAt: Int64,
        stale: Bool = false
    ) {
        self.evaluationID = evaluationID
        self.workspaceID = workspaceID
        self.runID = runID
        self.taskID = taskID
        self.taskRevision = taskRevision
        self.attemptID = attemptID
        self.artifactManifestID = artifactManifestID
        self.artifactManifestDigest = artifactManifestDigest
        self.criteriaID = criteriaID
        self.criteriaVersion = criteriaVersion
        self.evaluatorID = evaluatorID
        self.evaluatorVersion = evaluatorVersion
        self.verdict = verdict
        self.policyVersion = policyVersion
        self.evaluatedAt = evaluatedAt
        self.stale = stale
    }
}

struct SchedulerEvaluationCheck: Sendable, Equatable {
    let evaluationID: String
    let runID: String
    let taskID: String
    let runtimeTaskID: String
    let taskRevision: RevisionRef
    let attemptID: String
    let artifactManifestID: String
    let artifactManifestDigest: String
    let criteriaID: String
    let criteriaVersion: String
    let policyVersion: UInt64
    let expectedVerdict: EvaluationVerdict
}

public final class EvaluationVerdictStore: @unchecked Sendable {
    public let store: SQLiteStore

    public init(store: SQLiteStore) throws {
        self.store = store
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS evaluation_records (
                evaluation_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                run_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                task_revision_json TEXT NOT NULL,
                attempt_id TEXT NOT NULL,
                artifact_manifest_id TEXT NOT NULL,
                artifact_manifest_digest TEXT NOT NULL,
                criteria_id TEXT NOT NULL,
                criteria_version TEXT NOT NULL,
                evaluator_id TEXT NOT NULL,
                evaluator_version TEXT NOT NULL,
                verdict TEXT NOT NULL,
                policy_version INTEGER NOT NULL,
                evaluated_at INTEGER NOT NULL,
                stale INTEGER NOT NULL DEFAULT 0
            );
            """
        )
    }

    public func record(_ record: EvaluationVerdictRecord) throws {
        guard record.workspaceID.utf8.elementsEqual(store.workspaceID.utf8) else {
            throw StorageError.denied
        }
        let nonEmptyFields = [
            record.evaluationID,
            record.workspaceID,
            record.runID,
            record.taskID,
            record.taskRevision.objectID,
            record.taskRevision.storeGeneration,
            record.taskRevision.revision,
            record.attemptID,
            record.artifactManifestID,
            record.artifactManifestDigest,
            record.criteriaID,
            record.criteriaVersion,
            record.evaluatorID,
            record.evaluatorVersion,
        ]
        guard nonEmptyFields.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }),
              record.evaluatedAt >= 0 else {
            throw StorageError.invalidInput
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let taskRevisionJSON = String(decoding: try encoder.encode(record.taskRevision), as: UTF8.self)

        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT INTO evaluation_records (
                        evaluation_id, workspace_id, run_id, task_id, task_revision_json,
                        attempt_id, artifact_manifest_id, artifact_manifest_digest,
                        criteria_id, criteria_version, evaluator_id, evaluator_version,
                        verdict, policy_version, evaluated_at, stale
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: record.evaluationID)
                try store.bindText(stmt, index: 2, value: record.workspaceID)
                try store.bindText(stmt, index: 3, value: record.runID)
                try store.bindText(stmt, index: 4, value: record.taskID)
                try store.bindText(stmt, index: 5, value: taskRevisionJSON)
                try store.bindText(stmt, index: 6, value: record.attemptID)
                try store.bindText(stmt, index: 7, value: record.artifactManifestID)
                try store.bindText(stmt, index: 8, value: record.artifactManifestDigest)
                try store.bindText(stmt, index: 9, value: record.criteriaID)
                try store.bindText(stmt, index: 10, value: record.criteriaVersion)
                try store.bindText(stmt, index: 11, value: record.evaluatorID)
                try store.bindText(stmt, index: 12, value: record.evaluatorVersion)
                try store.bindText(stmt, index: 13, value: record.verdict.rawValue)
                sqlite3_bind_int64(stmt, 14, Int64(bitPattern: record.policyVersion))
                sqlite3_bind_int64(stmt, 15, record.evaluatedAt)
                sqlite3_bind_int(stmt, 16, record.stale ? 1 : 0)
                let rc = sqlite3_step(stmt)
                if (rc & 0xff) == SQLITE_CONSTRAINT {
                    throw StorageError.versionConflict
                }
                guard rc == SQLITE_DONE else {
                    throw store.mapSQLiteError(rc)
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func markStale(evaluationID: String) throws {
        guard !evaluationID.isEmpty, !evaluationID.utf8.contains(0) else {
            throw StorageError.invalidInput
        }
        try store.withConnectionLock { db in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    "UPDATE evaluation_records SET stale = 1 WHERE evaluation_id = ? AND workspace_id = ?"
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: evaluationID)
                try store.bindText(stmt, index: 2, value: store.workspaceID)
                let rc = sqlite3_step(stmt)
                guard rc == SQLITE_DONE else {
                    throw store.mapSQLiteError(rc)
                }
                guard sqlite3_changes(db) == 1 else {
                    throw StorageError.notFound
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func fetch(evaluationID: String) throws -> EvaluationVerdictRecord {
        guard !evaluationID.isEmpty, !evaluationID.utf8.contains(0) else {
            throw StorageError.invalidInput
        }
        return try store.withConnectionLock { _ in
            try Self.fetchInLock(evaluationID: evaluationID, workspaceID: store.workspaceID, store: store)
        }
    }

    private static func tableExists(_ name: String, store: SQLiteStore) throws -> Bool {
        let stmt = try store.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: name)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw store.mapSQLiteError(rc)
    }

    private static func fetchAnyWorkspaceInLock(evaluationID: String, store: SQLiteStore) throws -> EvaluationVerdictRecord {
        guard try tableExists("evaluation_records", store: store) else {
            throw StorageError.notFound
        }
        let stmt = try store.prepare(
            """
            SELECT evaluation_id, workspace_id, run_id, task_id, task_revision_json,
                   attempt_id, artifact_manifest_id, artifact_manifest_digest,
                   criteria_id, criteria_version, evaluator_id, evaluator_version,
                   verdict, policy_version, evaluated_at, stale
            FROM evaluation_records WHERE evaluation_id = ?
            """
        )
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: evaluationID)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { throw StorageError.notFound }
        guard rc == SQLITE_ROW else { throw store.mapSQLiteError(rc) }
        let taskRevision = try JSONDecoder().decode(RevisionRef.self, from: Data(store.columnText(stmt, index: 4).utf8))
        guard let verdict = EvaluationVerdict(rawValue: store.columnText(stmt, index: 12)) else {
            throw StorageError.corrupt("invalid evaluation verdict")
        }
        return EvaluationVerdictRecord(
            evaluationID: store.columnText(stmt, index: 0),
            workspaceID: store.columnText(stmt, index: 1),
            runID: store.columnText(stmt, index: 2),
            taskID: store.columnText(stmt, index: 3),
            taskRevision: taskRevision,
            attemptID: store.columnText(stmt, index: 5),
            artifactManifestID: store.columnText(stmt, index: 6),
            artifactManifestDigest: store.columnText(stmt, index: 7),
            criteriaID: store.columnText(stmt, index: 8),
            criteriaVersion: store.columnText(stmt, index: 9),
            evaluatorID: store.columnText(stmt, index: 10),
            evaluatorVersion: store.columnText(stmt, index: 11),
            verdict: verdict,
            policyVersion: UInt64(bitPattern: sqlite3_column_int64(stmt, 13)),
            evaluatedAt: sqlite3_column_int64(stmt, 14),
            stale: sqlite3_column_int(stmt, 15) != 0
        )
    }

    private static func fetchInLock(evaluationID: String, workspaceID: String, store: SQLiteStore) throws -> EvaluationVerdictRecord {
        let record = try fetchAnyWorkspaceInLock(evaluationID: evaluationID, store: store)
        guard record.workspaceID.utf8.elementsEqual(workspaceID.utf8) else {
            throw StorageError.notFound
        }
        return record
    }

    static func validateInTx(_ request: TransitionRequest, check: SchedulerEvaluationCheck, store: SQLiteStore) throws {
        let record = try fetchAnyWorkspaceInLock(evaluationID: check.evaluationID, store: store)
        guard record.workspaceID.utf8.elementsEqual(request.workspaceID.utf8),
              record.runID.utf8.elementsEqual(check.runID.utf8),
              record.taskID.utf8.elementsEqual(check.taskID.utf8),
              record.attemptID.utf8.elementsEqual(check.attemptID.utf8),
              record.artifactManifestID.utf8.elementsEqual(check.artifactManifestID.utf8),
              record.artifactManifestDigest.utf8.elementsEqual(check.artifactManifestDigest.utf8),
              record.verdict == check.expectedVerdict else {
            throw StorageError.denied
        }
        guard record.taskRevision == check.taskRevision,
              record.criteriaID.utf8.elementsEqual(check.criteriaID.utf8),
              record.criteriaVersion.utf8.elementsEqual(check.criteriaVersion.utf8),
              record.policyVersion == check.policyVersion,
              !record.stale else {
            throw StorageError.versionConflict
        }

        guard try tableExists("execution_attempts", store: store) else {
            throw StorageError.notFound
        }
        let attStmt = try store.prepare(
            "SELECT workspace_id, run_id, task_id, task_revision_json, state FROM execution_attempts WHERE attempt_id = ?"
        )
        defer { sqlite3_finalize(attStmt) }
        try store.bindText(attStmt, index: 1, value: check.attemptID)
        let rc = sqlite3_step(attStmt)
        if rc == SQLITE_DONE { throw StorageError.notFound }
        guard rc == SQLITE_ROW else { throw store.mapSQLiteError(rc) }
        let attWorkspace = store.columnText(attStmt, index: 0)
        let attRun = store.columnText(attStmt, index: 1)
        let attTask = store.columnText(attStmt, index: 2)
        let attRevision = try JSONDecoder().decode(RevisionRef.self, from: Data(store.columnText(attStmt, index: 3).utf8))
        let attState = store.columnText(attStmt, index: 4)
        guard attWorkspace.utf8.elementsEqual(request.workspaceID.utf8),
              attRun.utf8.elementsEqual(check.runID.utf8),
              attTask.utf8.elementsEqual(check.runtimeTaskID.utf8),
              attRevision == check.taskRevision,
              attState == ExecutionAttemptState.succeeded.rawValue else {
            throw StorageError.denied
        }
    }

    static func hasValidFailureRecord(
        store: SQLiteStore,
        workspaceID: String,
        runID: String,
        taskID: String,
        attemptID: String,
        taskRevision: RevisionRef,
        evaluationID: String
    ) throws -> Bool {
        try store.withConnectionLock { _ in
            guard try tableExists("evaluation_records", store: store) else {
                return false
            }
            guard let record = try? fetchAnyWorkspaceInLock(evaluationID: evaluationID, store: store) else {
                return false
            }
            return record.workspaceID.utf8.elementsEqual(workspaceID.utf8)
                && record.runID.utf8.elementsEqual(runID.utf8)
                && record.taskID.utf8.elementsEqual(taskID.utf8)
                && record.attemptID.utf8.elementsEqual(attemptID.utf8)
                && record.taskRevision == taskRevision
                && record.verdict == .fail
                && !record.stale
        }
    }
}
