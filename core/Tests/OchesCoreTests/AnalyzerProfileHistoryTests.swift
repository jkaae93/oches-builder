import Foundation
import XCTest
@testable import OchesCore

final class AnalyzerProfileHistoryTests: XCTestCase {
    func testProfileRepositoryRoundTripsAndRejectsWrongBindings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic project contents".utf8).write(to: root.appendingPathComponent("main.swift"))
        let collection = try AnalyzerSafeRoot(rootPath: root.path).collectEvidence()
        let draft = try AnalyzerProfileDraft.build(profileID: "p", workspaceRef: "ws", analyzerVersion: "1", analyzedAt: Date(timeIntervalSince1970: 100), roots: ["private/root"], exclusions: [], userConstraints: ["private constraint"], collection: collection)
        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let repository = AnalyzerProfileRepository(store: store)
        let result = try repository.save(draft, actorID: "actor", requestID: "r", expectedRevision: nil, nowEpochSeconds: 101)
        let restored = try repository.load(profileID: "p", revision: result.revision)
        XCTAssertEqual(restored.evidence.first?.sha256, draft.evidence.first?.sha256)
        XCTAssertEqual(restored.userConstraints, ["private constraint"])
        XCTAssertEqual(restored.analyzedAt, draft.analyzedAt)
        XCTAssertTrue(try repository.save(draft, actorID: "actor", requestID: "r", expectedRevision: nil, nowEpochSeconds: 101).idempotentReplay)
        XCTAssertThrowsError(try repository.load(profileID: "other", revision: result.revision))
        let events = try store.listEvents(workspaceID: "ws", after: EventCursor(workspaceID: "ws", storeGeneration: "gen", sequence: 0))
        XCTAssertEqual(events.events.first?.payloadJSON, "{}")
        XCTAssertFalse(String(reflecting: events.events).contains("private constraint"))
        XCTAssertFalse(String(reflecting: restored).contains("synthetic project contents"))
        try store.executeRawForTesting("UPDATE profile_revisions SET payload_json = '{\"schemaVersion\":2,\"profile\":{}}' WHERE object_id = 'arc02/profile/p'")
        XCTAssertThrowsError(try repository.load(profileID: "p", revision: result.revision)) {
            guard case .unavailable = $0 as? StorageError else { return XCTFail("unsupported schema must remain unavailable") }
        }
        try store.executeRawForTesting("UPDATE profile_revisions SET payload_json = '{\"schemaVersion\":1,\"schemaVersion\":1,\"profile\":{}}' WHERE object_id = 'arc02/profile/p'")
        XCTAssertThrowsError(try repository.load(profileID: "p", revision: result.revision)) {
            guard case .corrupt = $0 as? StorageError else { return XCTFail("duplicate keys must be rejected") }
        }
    }

    func testCrashDuringProfileCommitDoesNotPublishPartialRevision() throws {
        if let path = ProcessInfo.processInfo.environment["OCHES_PROFILE_CRASH_DB"],
           let name = ProcessInfo.processInfo.environment["OCHES_PROFILE_CRASH_STAGE"],
           let stage = TransitionCrashStage(rawValue: name) {
            let store = try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "gen")
            let request = TransitionRequest(actorID: "actor", workspaceID: "ws", operation: "profile.commit", requestID: "next", objectID: "p", ownerModule: "ARC-02", expectedRevision: RevisionRef(objectID: "p", storeGeneration: "gen", revision: "1"), normalizedInput: .object([]), nextStateJSON: "{\"v\":2}", events: [NewEventRecord(eventID: "e2", sourceID: "analyzer", kind: "profile.committed", payloadJSON: "{}", observedAt: 2)], responseJSON: "{}", nowEpochSeconds: 2, crashStage: stage, onCrashStage: { _ in _exit(71) })
            _ = try store.commitProfileTransition(request)
            XCTFail("crash hook did not fire")
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for stage in ["afterStateWrite", "afterEventWrite", "afterIdempotencyWrite"] {
            let path = dir.appendingPathComponent(stage).path
            let store = try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "gen")
            let request = TransitionRequest(actorID: "actor", workspaceID: "ws", operation: "profile.commit", requestID: "init", objectID: "p", ownerModule: "ARC-02", expectedRevision: nil, normalizedInput: .object([]), nextStateJSON: "{\"v\":1}", events: [], responseJSON: "{}", nowEpochSeconds: 1)
            let first = try store.commitProfileTransition(request)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            process.arguments = ["-XCTest", "OchesCoreTests.AnalyzerProfileHistoryTests/testCrashDuringProfileCommitDoesNotPublishPartialRevision", Bundle(for: AnalyzerProfileHistoryTests.self).bundlePath]
            var env = ProcessInfo.processInfo.environment
            env["OCHES_PROFILE_CRASH_DB"] = path
            env["OCHES_PROFILE_CRASH_STAGE"] = stage
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 71)
            let reopened = try SQLiteStore(path: path, workspaceID: "ws")
            XCTAssertEqual(try reopened.readSnapshot(workspaceID: "ws", objectID: "p").revision, first.revision)
            XCTAssertEqual(try reopened.readProfileRevision(workspaceID: "ws", revision: first.revision), "{\"v\":1}")
            let second = RevisionRef(objectID: "p", storeGeneration: "gen", revision: "2")
            XCTAssertThrowsError(try reopened.readProfileRevision(workspaceID: "ws", revision: second)) { XCTAssertEqual($0 as? StorageError, .notFound) }
            let events = try reopened.listEvents(workspaceID: "ws", after: EventCursor(workspaceID: "ws", storeGeneration: "gen", sequence: 0))
            XCTAssertTrue(events.events.isEmpty)
            let retry = TransitionRequest(actorID: "actor", workspaceID: "ws", operation: "profile.commit", requestID: "next", objectID: "p", ownerModule: "ARC-02", expectedRevision: first.revision, normalizedInput: .object([]), nextStateJSON: "{\"v\":2}", events: [NewEventRecord(eventID: "e2", sourceID: "analyzer", kind: "profile.committed", payloadJSON: "{}", observedAt: 2)], responseJSON: "{}", nowEpochSeconds: 2)
            XCTAssertFalse(try reopened.commitProfileTransition(retry).idempotentReplay)
        }
    }

    func testConcurrentProfileWritersPreserveOnlyWinningRevision() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("db").path
        let firstStore = try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "gen")
        let secondStore = try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "gen")
        func request(_ id: String, _ expected: RevisionRef?) -> TransitionRequest {
            TransitionRequest(actorID: "actor", workspaceID: "ws", operation: "profile.commit", requestID: id, objectID: "p", ownerModule: "ARC-02", expectedRevision: expected, normalizedInput: .object([]), nextStateJSON: "{\"writer\":\"\(id)\"}", events: [], responseJSON: "{}", nowEpochSeconds: 1)
        }
        let initial = try firstStore.commitProfileTransition(request("initial", nil))
        final class Outcomes: @unchecked Sendable {
            let lock = NSLock()
            var values: [String] = []
            func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        }
        let outcomes = Outcomes()
        let requests = [request("a", initial.revision), request("b", initial.revision)]
        let stores = [firstStore, secondStore]
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do {
                let result = try stores[index].commitProfileTransition(requests[index])
                outcomes.add("ok:" + result.revision.revision)
            } catch StorageError.versionConflict { outcomes.add("conflict") }
            catch { outcomes.add("error:\(error)") }
        }
        XCTAssertEqual(Set(outcomes.values), ["ok:2", "conflict"])
        let latest = try firstStore.readSnapshot(workspaceID: "ws", objectID: "p")
        XCTAssertEqual(try firstStore.readProfileRevision(workspaceID: "ws", revision: latest.revision), latest.stateJSON)
        XCTAssertEqual(try firstStore.readProfileRevision(workspaceID: "ws", revision: initial.revision), "{\"writer\":\"initial\"}")
    }

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
