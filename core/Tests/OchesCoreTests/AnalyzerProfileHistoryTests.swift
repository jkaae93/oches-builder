import Foundation
import XCTest
@testable import OchesCore

final class AnalyzerProfileHistoryTests: XCTestCase {
    func testVersionOneDatabaseMigratesWithoutLosingState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("db").path
        do {
            let store = try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "gen")
            try store.executeRawForTesting("INSERT INTO operational_state(object_id, workspace_id, owner_module, revision, state_json, updated_at) VALUES ('old', 'ws', 'ARC-02', 1, '{}', 1)")
            try store.executeRawForTesting("DROP TABLE profile_revisions")
            try store.executeRawForTesting("UPDATE workspace_meta SET schema_version = 1 WHERE workspace_id = 'ws'")
        }
        let migrated = try SQLiteStore(path: path, workspaceID: "ws")
        XCTAssertEqual(try migrated.readSnapshot(workspaceID: "ws", objectID: "old").stateJSON, "{}")
        let request = TransitionRequest(actorID: "actor", workspaceID: "ws", operation: "profile.commit", requestID: "r", objectID: "new", ownerModule: "ARC-02", expectedRevision: nil, normalizedInput: .object([]), nextStateJSON: "{}", events: [], responseJSON: "{}", nowEpochSeconds: 1)
        let result = try migrated.commitProfileTransition(request)
        XCTAssertEqual(try migrated.readProfileRevision(workspaceID: "ws", revision: result.revision), "{}")
        XCTAssertEqual(try migrated.verifyIntegrity(), .available)
    }

    func testHistoryIsAtomicIdempotentAndDeletionBlocksAccess() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        func request(_ id: String, _ body: String, _ expected: RevisionRef? = nil) -> TransitionRequest {
            TransitionRequest(actorID: "actor", workspaceID: "ws", operation: "profile.commit", requestID: id,
                              objectID: "profile:p", ownerModule: "ARC-02", expectedRevision: expected,
                              normalizedInput: .object([]), nextStateJSON: body,
                              events: [NewEventRecord(eventID: "event-" + id, sourceID: "analyzer", kind: "profile.committed", payloadJSON: "{}", observedAt: 1)],
                              responseJSON: "{}", nowEpochSeconds: 1)
        }
        let first = try store.commitProfileTransition(request("1", "{\"v\":1}"))
        let replay = try store.commitProfileTransition(request("1", "{\"v\":1}"))
        XCTAssertTrue(replay.idempotentReplay)
        XCTAssertThrowsError(try store.commitProfileTransition(request("1", "{\"v\":2}"))) { XCTAssertEqual($0 as? StorageError, .idempotencyConflict) }
        let second = try store.commitProfileTransition(request("2", "{\"v\":2}", first.revision))
        XCTAssertEqual(try store.readProfileRevision(workspaceID: "ws", revision: first.revision), "{\"v\":1}")
        XCTAssertEqual(try store.readProfileRevision(workspaceID: "ws", revision: second.revision), "{\"v\":2}")
        XCTAssertThrowsError(try store.commitProfileTransition(request("3", "{}", first.revision))) { XCTAssertEqual($0 as? StorageError, .versionConflict) }
        XCTAssertThrowsError(try store.readProfileRevision(workspaceID: "other", revision: first.revision)) { XCTAssertEqual($0 as? StorageError, .denied) }
        let deletion = try DeletionRequestLifecycle(store: store)
        _ = try deletion.beginDeletion(requestID: "del", targetID: "profile:p")
        XCTAssertThrowsError(try store.readProfileRevision(workspaceID: "ws", revision: first.revision)) { XCTAssertEqual($0 as? StorageError, .denied) }
        XCTAssertThrowsError(try store.commitProfileTransition(request("4", "{}", second.revision))) { XCTAssertEqual($0 as? StorageError, .denied) }
        _ = try deletion.executeDeletion(requestID: "del", targetID: "profile:p")
        try store.executeRawForTesting("DELETE FROM deletion_requests WHERE request_id = 'del'")
        XCTAssertThrowsError(try store.readProfileRevision(workspaceID: "ws", revision: first.revision)) { XCTAssertEqual($0 as? StorageError, .notFound) }
    }

    func testHistoryInsertionFailureRollsBackStateAndEvents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        try store.executeRawForTesting("CREATE TRIGGER fail_profile BEFORE INSERT ON profile_revisions BEGIN SELECT RAISE(ABORT, 'injected'); END")
        let request = TransitionRequest(actorID: "actor", workspaceID: "ws", operation: "profile.commit", requestID: "r", objectID: "p", ownerModule: "ARC-02", expectedRevision: nil, normalizedInput: .object([]), nextStateJSON: "{}", events: [], responseJSON: "{}", nowEpochSeconds: 1)
        XCTAssertThrowsError(try store.commitProfileTransition(request))
        XCTAssertThrowsError(try store.readSnapshot(workspaceID: "ws", objectID: "p")) { XCTAssertEqual($0 as? StorageError, .notFound) }
        try store.executeRawForTesting("DROP TRIGGER fail_profile")
        let result = try store.commitProfileTransition(request)
        XCTAssertFalse(result.idempotentReplay)
        XCTAssertEqual(result.revision.revision, "1")
    }
}
