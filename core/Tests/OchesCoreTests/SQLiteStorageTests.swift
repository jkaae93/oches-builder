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
}
