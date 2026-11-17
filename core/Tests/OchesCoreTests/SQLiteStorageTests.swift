import Foundation
import SQLite3
import XCTest
@testable import OchesCore

final class SQLiteStorageTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDirectory("sqlite-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testPragmasEnforceWALFullAndForeignKeys() throws {
        let dbPath = tempDir.appendingPathComponent("core.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let pragmas = try store.readPragmaState()
        XCTAssertEqual(pragmas.journalMode, "wal")
        XCTAssertEqual(pragmas.synchronous, 2)
        XCTAssertEqual(pragmas.foreignKeys, 1)
        XCTAssertEqual(try store.verifyIntegrity(), .available)
    }

    func testInMemoryDatabaseFailsClosedWhenWALCannotBeEnforced() {
        XCTAssertThrowsError(try SQLiteStore(path: ":memory:", workspaceID: "ws-1")) { error in
            XCTAssertEqual((error as? StorageError)?.safeWireError.code, .unavailable)
        }
    }

    func testForwardOnlyMigrationRejectsNewerSchemaVersionWithoutDowngrade() throws {
        let dbPath = tempDir.appendingPathComponent("future.db").path
        do {
            let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
            try store.executeRawForTesting("UPDATE workspace_meta SET schema_version = 999 WHERE workspace_id = 'ws-1'")
        }
        XCTAssertThrowsError(try SQLiteStore(path: dbPath, workspaceID: "ws-1")) { error in
            guard case .invalidMigration = error as? StorageError else {
                return XCTFail("Expected invalidMigration, got \(error)")
            }
        }
        // Verify schema_version was not downgraded on disk
        var rawDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &rawDB), SQLITE_OK)
        defer { sqlite3_close(rawDB) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(rawDB, "SELECT schema_version FROM workspace_meta WHERE workspace_id='ws-1'", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 999)
    }

    func testIntegrityCheckDoesNotReplaceForeignKeyCheck() throws {
        let dbPath = tempDir.appendingPathComponent("fk.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        try store.executeRawForTesting("PRAGMA foreign_keys = OFF")
        try store.executeRawForTesting(
            "INSERT INTO operational_state(object_id, workspace_id, owner_module, revision, state_json, updated_at) VALUES ('obj-1', 'missing-ws', 'ARC-06', 1, '{}', 100)"
        )
        try store.executeRawForTesting("PRAGMA foreign_keys = ON")

        let health = try store.verifyIntegrity()
        guard case .recoveryRequired = health else {
            return XCTFail("Expected recoveryRequired, got \(health)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
        XCTAssertThrowsError(try store.readSnapshot(workspaceID: "ws-1", objectID: "obj-1")) { error in
            guard case .corrupt = error as? StorageError else {
                return XCTFail("Expected corrupt error while recoveryRequired, got \(error)")
            }
        }
    }

    func testConsistentSnapshotAndCursorReplayDuringConcurrentWrite() throws {
        let dbPath = tempDir.appendingPathComponent("snapshot.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let writer = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")

        try store.executeRawForTesting(
            "INSERT INTO operational_state(object_id, workspace_id, owner_module, revision, state_json, updated_at) VALUES ('task-1', 'ws-1', 'ARC-07', 0, '{\"status\":\"ready\"}', 100)"
        )

        let snapshot = try store.readSnapshot(workspaceID: "ws-1", objectID: "task-1") {
            // Concurrent writer commits a newer state and event while reader holds snapshot tx
            try! writer.executeRawForTesting("BEGIN IMMEDIATE")
            try! writer.executeRawForTesting("UPDATE operational_state SET revision = 1, state_json = '{\"status\":\"running\"}' WHERE object_id = 'task-1'")
            try! writer.executeRawForTesting("INSERT INTO event_log(event_id, workspace_id, store_generation, object_id, source_id, kind, payload_json, observed_at) VALUES ('evt-1', 'ws-1', 'gen-1', 'task-1', 'mock', 'state.changed', '{}', 101)")
            try! writer.executeRawForTesting("COMMIT")
        }

        XCTAssertEqual(snapshot.revision, RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "0"))
        XCTAssertEqual(snapshot.stateJSON, "{\"status\":\"ready\"}")
        XCTAssertEqual(snapshot.eventCursor, EventCursor(workspaceID: "ws-1", storeGeneration: "gen-1", sequence: 0))

        let replay = try store.listEvents(workspaceID: "ws-1", after: snapshot.eventCursor)
        XCTAssertEqual(replay.events.count, 1)
        XCTAssertEqual(replay.events[0].eventID, "evt-1")
        XCTAssertEqual(replay.nextCursor.sequence, 1)

        // Wrong workspace cursor denied
        XCTAssertThrowsError(try store.listEvents(workspaceID: "ws-2", after: snapshot.eventCursor)) { error in
            XCTAssertEqual(error as? StorageError, .denied)
        }

        // Wrong storeGeneration rejected as STALE_GENERATION
        let staleCursor = EventCursor(workspaceID: "ws-1", storeGeneration: "gen-old", sequence: 0)
        XCTAssertThrowsError(try store.listEvents(workspaceID: "ws-1", after: staleCursor)) { error in
            XCTAssertEqual(error as? StorageError, .staleGeneration)
            XCTAssertEqual((error as? StorageError)?.safeWireError.detail, "STALE_GENERATION")
        }

        // Retained sequence moved past cursor -> CURSOR_EXPIRED
        try store.executeRawForTesting("UPDATE event_retention_meta SET min_retained_seq = 1 WHERE workspace_id = 'ws-1'")
        XCTAssertThrowsError(try store.listEvents(workspaceID: "ws-1", after: snapshot.eventCursor)) { error in
            XCTAssertEqual(error as? StorageError, .cursorExpired)
            XCTAssertEqual((error as? StorageError)?.safeWireError.code, .cursorExpired)
        }
    }

    func testCommitTransitionIdempotencyConflictsAnd30DayExpiration() throws {
        let dbPath = tempDir.appendingPathComponent("idempotency.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let t0: Int64 = 1_700_000_000

        let req1 = TransitionRequest(
            actorID: "actor-a",
            workspaceID: "ws-1",
            operation: "task.transition",
            requestID: "req-1",
            objectID: "task-1",
            ownerModule: "ARC-07",
            expectedRevision: nil,
            normalizedInput: .object([("state", .string("ready"))]),
            nextStateJSON: "{\"status\":\"ready\"}",
            events: [NewEventRecord(eventID: "evt-1", sourceID: "core", kind: "task.created", payloadJSON: "{}", observedAt: t0)],
            responseJSON: "{\"ok\":{\"status\":\"ready\"}}",
            nowEpochSeconds: t0
        )

        let res1 = try store.commitTransition(req1)
        XCTAssertFalse(res1.idempotentReplay)
        XCTAssertEqual(res1.revision.revision, "1")
        XCTAssertEqual(res1.eventCursor.sequence, 1)

        // Exact replay returns original result without extra writes
        let replay = try store.commitTransition(req1)
        XCTAssertTrue(replay.idempotentReplay)
        XCTAssertEqual(replay.revision, res1.revision)
        XCTAssertEqual(replay.eventCursor, res1.eventCursor)
        XCTAssertEqual(replay.responseJSON, res1.responseJSON)

        // Same requestId with different input payload -> CONFLICT
        let mismatchPayload = TransitionRequest(
            actorID: "actor-a",
            workspaceID: "ws-1",
            operation: "task.transition",
            requestID: "req-1",
            objectID: "task-1",
            ownerModule: "ARC-07",
            expectedRevision: nil,
            normalizedInput: .object([("state", .string("other"))]),
            nextStateJSON: "{\"status\":\"other\"}",
            events: [],
            responseJSON: "{}",
            nowEpochSeconds: t0 + 5
        )
        XCTAssertThrowsError(try store.commitTransition(mismatchPayload)) { error in
            XCTAssertEqual(error as? StorageError, .idempotencyConflict)
            XCTAssertEqual((error as? StorageError)?.safeWireError.code, .conflict)
        }

        // Same requestId with different expectedRevision -> CONFLICT
        let mismatchRev = TransitionRequest(
            actorID: "actor-a",
            workspaceID: "ws-1",
            operation: "task.transition",
            requestID: "req-1",
            objectID: "task-1",
            ownerModule: "ARC-07",
            expectedRevision: res1.revision,
            normalizedInput: .object([("state", .string("ready"))]),
            nextStateJSON: "{\"status\":\"ready\"}",
            events: [],
            responseJSON: "{}",
            nowEpochSeconds: t0 + 5
        )
        XCTAssertThrowsError(try store.commitTransition(mismatchRev)) { error in
            XCTAssertEqual(error as? StorageError, .idempotencyConflict)
        }

        // Different actorId uses separate scope
        let otherActorReq = TransitionRequest(
            actorID: "actor-b",
            workspaceID: "ws-1",
            operation: "task.transition",
            requestID: "req-1",
            objectID: "task-2",
            ownerModule: "ARC-07",
            expectedRevision: nil,
            normalizedInput: .object([("state", .string("ready"))]),
            nextStateJSON: "{\"status\":\"ready\"}",
            events: [],
            responseJSON: "{\"ok\":true}",
            nowEpochSeconds: t0 + 10
        )
        let otherActorRes = try store.commitTransition(otherActorReq)
        XCTAssertFalse(otherActorRes.idempotentReplay)

        // Advance past 30-day retention -> sweep creates tombstone, retry returns IDEMPOTENCY_EXPIRED
        let after30Days = t0 + TransitionRequest.defaultRetentionSeconds + 10
        let swept = try store.sweepExpiredIdempotencyRecords(nowEpochSeconds: after30Days)
        XCTAssertEqual(swept, 2)

        let expiredReq = TransitionRequest(
            actorID: "actor-a",
            workspaceID: "ws-1",
            operation: "task.transition",
            requestID: "req-1",
            objectID: "task-1",
            ownerModule: "ARC-07",
            expectedRevision: nil,
            normalizedInput: .object([("state", .string("ready"))]),
            nextStateJSON: "{\"status\":\"ready\"}",
            events: [],
            responseJSON: "{}",
            nowEpochSeconds: after30Days
        )
        XCTAssertThrowsError(try store.commitTransition(expiredReq)) { error in
            XCTAssertEqual(error as? StorageError, .idempotencyExpired)
            XCTAssertEqual((error as? StorageError)?.safeWireError.code, .idempotencyExpired)
        }

        // Verify state remained unchanged at revision 1 with 1 event
        let finalSnapshot = try store.readSnapshot(workspaceID: "ws-1", objectID: "task-1")
        XCTAssertEqual(finalSnapshot.revision.revision, "1")
        let events = try store.listEvents(
            workspaceID: "ws-1",
            after: EventCursor(workspaceID: "ws-1", storeGeneration: "gen-1", sequence: 0)
        )
        XCTAssertEqual(events.events.count, 1)
    }

    func testDiskFullRollsBackAndTransitionsToDegraded() throws {
        let dbPath = tempDir.appendingPathComponent("diskfull.db").path
        let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let t0: Int64 = 1_700_000_000

        let initial = try store.commitTransition(TransitionRequest(
            actorID: "actor-a",
            workspaceID: "ws-1",
            operation: "task.init",
            requestID: "req-init",
            objectID: "task-1",
            ownerModule: "ARC-07",
            expectedRevision: nil,
            normalizedInput: .object([]),
            nextStateJSON: "{\"status\":\"before\"}",
            events: [],
            responseJSON: "{}",
            nowEpochSeconds: t0
        ))

        try store.executeRawForTesting("PRAGMA wal_checkpoint(TRUNCATE)")
        let pageCount = try store.withConnectionLock { db -> Int32 in
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "PRAGMA page_count", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            sqlite3_step(stmt)
            return sqlite3_column_int(stmt, 0)
        }
        try store.executeRawForTesting("PRAGMA max_page_count = \(pageCount + 1)")

        let bigState = String(repeating: "x", count: 512 * 1024)
        let bigReq = TransitionRequest(
            actorID: "actor-a",
            workspaceID: "ws-1",
            operation: "task.big",
            requestID: "req-big",
            objectID: "task-1",
            ownerModule: "ARC-07",
            expectedRevision: initial.revision,
            normalizedInput: .object([("k", .string("big"))]),
            nextStateJSON: bigState,
            events: [NewEventRecord(eventID: "evt-big", sourceID: "core", kind: "task.big", payloadJSON: "{}", observedAt: t0 + 1)],
            responseJSON: "{}",
            nowEpochSeconds: t0 + 1
        )
        XCTAssertThrowsError(try store.commitTransition(bigReq)) { error in
            XCTAssertEqual(error as? StorageError, .diskFull)
        }
        guard case .degraded = store.healthState else {
            return XCTFail("Expected degraded healthState after disk full, got \(store.healthState)")
        }

        // Verify original state was untouched and no partial event was written
        let snap = try store.readSnapshot(workspaceID: "ws-1", objectID: "task-1")
        XCTAssertEqual(snap.stateJSON, "{\"status\":\"before\"}")
        XCTAssertEqual(snap.revision.revision, "1")
        let evs = try store.listEvents(workspaceID: "ws-1", after: EventCursor(workspaceID: "ws-1", storeGeneration: "gen-1", sequence: 0))
        XCTAssertEqual(evs.events.count, 0)
    }

    func testConcurrentWritersAndDuplicateRequests() throws {
        let dbPath = tempDir.appendingPathComponent("concurrent.db").path
        let setup = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let t0: Int64 = 1_700_000_000
        let base = try setup.commitTransition(TransitionRequest(
            actorID: "actor-a",
            workspaceID: "ws-1",
            operation: "task.init",
            requestID: "req-init",
            objectID: "task-1",
            ownerModule: "ARC-07",
            expectedRevision: nil,
            normalizedInput: .object([]),
            nextStateJSON: "{\"status\":\"ready\"}",
            events: [],
            responseJSON: "{}",
            nowEpochSeconds: t0
        ))

        // Competing writers on same expectedRevision with different requestIds
        final class LockedBox<T>: @unchecked Sendable {
            private let lock = NSLock()
            var value: T
            init(_ value: T) { self.value = value }
            func withLock(_ body: (inout T) -> Void) {
                lock.lock()
                defer { lock.unlock() }
                body(&value)
            }
        }

        let group = DispatchGroup()
        let resultsBox = LockedBox<[String]>([])
        for idx in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let s = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
                    let res = try s.commitTransition(TransitionRequest(
                        actorID: "actor-a",
                        workspaceID: "ws-1",
                        operation: "task.run",
                        requestID: "req-compete-\(idx)",
                        objectID: "task-1",
                        ownerModule: "ARC-07",
                        expectedRevision: base.revision,
                        normalizedInput: .object([("writer", .number(String(idx)))]),
                        nextStateJSON: "{\"status\":\"running-\(idx)\"}",
                        events: [NewEventRecord(eventID: "evt-compete-\(idx)", sourceID: "core", kind: "run", payloadJSON: "{}", observedAt: t0 + 1)],
                        responseJSON: "{\"ok\":true}",
                        nowEpochSeconds: t0 + 1
                    ))
                    resultsBox.withLock { $0.append("OK:\(res.revision.revision)") }
                } catch StorageError.versionConflict {
                    resultsBox.withLock { $0.append("CONFLICT") }
                } catch {
                    resultsBox.withLock { $0.append("ERR:\(error)") }
                }
            }
        }
        group.wait()
        XCTAssertEqual(Set(resultsBox.value), ["OK:2", "CONFLICT"])

        // Concurrent duplicate requests with identical requestId
        let dupGroup = DispatchGroup()
        let dupOutcomesBox = LockedBox<[Result<TransitionResult, Error>]>([])
        let dupRev = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "2")
        for _ in 0..<4 {
            dupGroup.enter()
            DispatchQueue.global().async {
                defer { dupGroup.leave() }
                do {
                    let s = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
                    let res = try s.commitTransition(TransitionRequest(
                        actorID: "actor-a",
                        workspaceID: "ws-1",
                        operation: "task.finish",
                        requestID: "req-same-dup",
                        objectID: "task-1",
                        ownerModule: "ARC-07",
                        expectedRevision: dupRev,
                        normalizedInput: .object([("done", .bool(true))]),
                        nextStateJSON: "{\"status\":\"done\"}",
                        events: [NewEventRecord(eventID: "evt-same-dup", sourceID: "core", kind: "done", payloadJSON: "{}", observedAt: t0 + 2)],
                        responseJSON: "{\"done\":true}",
                        nowEpochSeconds: t0 + 2
                    ))
                    dupOutcomesBox.withLock { $0.append(.success(res)) }
                } catch {
                    dupOutcomesBox.withLock { $0.append(.failure(error)) }
                }
            }
        }
        dupGroup.wait()
        let successes = dupOutcomesBox.value.compactMap { try? $0.get() }
        XCTAssertEqual(successes.count, 4)
        XCTAssertEqual(successes.filter { !$0.idempotentReplay }.count, 1)
        XCTAssertEqual(successes.filter { $0.idempotentReplay }.count, 3)
        XCTAssertTrue(successes.allSatisfy { $0.revision.revision == "3" })
    }

    func testSubprocessCrashAtEachWriteBoundaryLeavesZeroPartialCommits() throws {
        // Skip infinite recursion when invoked as child crash helper
        if let stageName = ProcessInfo.processInfo.environment["OCHES_TEST_CRASH_STAGE"],
           let dbPath = ProcessInfo.processInfo.environment["OCHES_TEST_CRASH_DB"] {
            let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
            let expected = RevisionRef(objectID: "task-1", storeGeneration: "gen-1", revision: "1")
            let stage: TransitionCrashStage? = TransitionCrashStage(rawValue: stageName)
            let res = try store.commitTransition(TransitionRequest(
                actorID: "actor-crash",
                workspaceID: "ws-1",
                operation: "task.crash",
                requestID: "req-crash-\(stageName)",
                objectID: "task-1",
                ownerModule: "ARC-07",
                expectedRevision: expected,
                normalizedInput: .object([("stage", .string(stageName))]),
                nextStateJSON: "{\"status\":\"crashed\"}",
                events: [NewEventRecord(eventID: "evt-crash-\(stageName)", sourceID: "core", kind: "crash", payloadJSON: "{}", observedAt: 1000)],
                responseJSON: "{}",
                nowEpochSeconds: 1000,
                crashStage: stage,
                onCrashStage: { crashedAt in
                    let exitCode: Int32
                    switch crashedAt {
                    case .afterStateWrite: exitCode = 71
                    case .afterEventWrite: exitCode = 72
                    case .afterIdempotencyWrite: exitCode = 73
                    }
                    _exit(exitCode)
                }
            ))
            if stageName == "commit", res.revision.revision == "2" {
                _exit(0)
            }
            return
        }

        let xctestBinary = ProcessInfo.processInfo.arguments[0]
        let bundlePath = Bundle(for: SQLiteStorageTests.self).bundlePath

        for (stage, expectedExit) in [("afterStateWrite", Int32(71)), ("afterEventWrite", Int32(72)), ("afterIdempotencyWrite", Int32(73))] {
            let subDir = tempDir.appendingPathComponent("crash-\(stage)", isDirectory: true)
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
            let dbPath = subDir.appendingPathComponent("crash.db").path
            let store = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
            _ = try store.commitTransition(TransitionRequest(
                actorID: "actor-init",
                workspaceID: "ws-1",
                operation: "task.init",
                requestID: "req-init",
                objectID: "task-1",
                ownerModule: "ARC-07",
                expectedRevision: nil,
                normalizedInput: .object([]),
                nextStateJSON: "{\"status\":\"ready\"}",
                events: [],
                responseJSON: "{}",
                nowEpochSeconds: 900
            ))

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: xctestBinary)
            proc.arguments = ["-XCTest", "OchesCoreTests.SQLiteStorageTests/testSubprocessCrashAtEachWriteBoundaryLeavesZeroPartialCommits", bundlePath]
            var env = ProcessInfo.processInfo.environment
            env["OCHES_TEST_CRASH_STAGE"] = stage
            env["OCHES_TEST_CRASH_DB"] = dbPath
            proc.environment = env
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try proc.run()
            proc.waitUntilExit()
            XCTAssertEqual(proc.terminationStatus, expectedExit, "Expected child exit \(expectedExit) for \(stage)")

            let reopened = try SQLiteStore(path: dbPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
            let snap = try reopened.readSnapshot(workspaceID: "ws-1", objectID: "task-1")
            XCTAssertEqual(snap.revision.revision, "1")
            XCTAssertEqual(snap.stateJSON, "{\"status\":\"ready\"}")
            let evs = try reopened.listEvents(workspaceID: "ws-1", after: EventCursor(workspaceID: "ws-1", storeGeneration: "gen-1", sequence: 0))
            XCTAssertEqual(evs.events.count, 0)
        }

        // Positive control: after commit completes, crash/exit preserves committed transition
        let okDir = tempDir.appendingPathComponent("crash-commit", isDirectory: true)
        try FileManager.default.createDirectory(at: okDir, withIntermediateDirectories: true)
        let okDBPath = okDir.appendingPathComponent("ok.db").path
        let okStore = try SQLiteStore(path: okDBPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        _ = try okStore.commitTransition(TransitionRequest(
            actorID: "actor-init",
            workspaceID: "ws-1",
            operation: "task.init",
            requestID: "req-init",
            objectID: "task-1",
            ownerModule: "ARC-07",
            expectedRevision: nil,
            normalizedInput: .object([]),
            nextStateJSON: "{\"status\":\"ready\"}",
            events: [],
            responseJSON: "{}",
            nowEpochSeconds: 900
        ))
        let okProc = Process()
        okProc.executableURL = URL(fileURLWithPath: xctestBinary)
        okProc.arguments = ["-XCTest", "OchesCoreTests.SQLiteStorageTests/testSubprocessCrashAtEachWriteBoundaryLeavesZeroPartialCommits", bundlePath]
        var okEnv = ProcessInfo.processInfo.environment
        okEnv["OCHES_TEST_CRASH_STAGE"] = "commit"
        okEnv["OCHES_TEST_CRASH_DB"] = okDBPath
        okProc.environment = okEnv
        okProc.standardOutput = Pipe()
        okProc.standardError = Pipe()
        try okProc.run()
        okProc.waitUntilExit()
        XCTAssertEqual(okProc.terminationStatus, 0)

        let reopenedOK = try SQLiteStore(path: okDBPath, workspaceID: "ws-1", initialStoreGeneration: "gen-1")
        let okSnap = try reopenedOK.readSnapshot(workspaceID: "ws-1", objectID: "task-1")
        XCTAssertEqual(okSnap.revision.revision, "2")
        XCTAssertEqual(okSnap.stateJSON, "{\"status\":\"crashed\"}")
        let okEvents = try reopenedOK.listEvents(workspaceID: "ws-1", after: EventCursor(workspaceID: "ws-1", storeGeneration: "gen-1", sequence: 0))
        XCTAssertEqual(okEvents.events.count, 1)
    }
}
