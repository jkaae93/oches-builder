import Foundation
import XCTest
@testable import OchesCore

final class AgentDefinitionRepositoryTests: XCTestCase {
    private let sample = #"{"schemaVersion":{"major":1,"minor":0},"definitionId":"agent","revision":1,"role":"review","instructions":"inspect","inputs":[],"outputs":[],"tools":[],"permissions":[],"resourceLimits":{"maxDurationSeconds":60,"maxAttempts":1}}"#

    func testImmutableVersionsIdempotencyAndRestart() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db").path
        let repository = AgentDefinitionRepository(store: try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "gen"))
        let first = try repository.save(Data(sample.utf8), actorID: "actor", requestID: "one", nowEpochSeconds: 100)
        XCTAssertTrue(try repository.save(Data(sample.utf8), actorID: "actor", requestID: "one", nowEpochSeconds: 101).idempotentReplay)
        let changed = Data(sample.replacingOccurrences(of: "inspect", with: "changed").utf8)
        XCTAssertThrowsError(try repository.save(changed, actorID: "actor", requestID: "one", nowEpochSeconds: 102))
        XCTAssertThrowsError(try repository.save(changed, actorID: "actor", requestID: "two", nowEpochSeconds: 102))
        let second = Data(sample.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":2").utf8)
        _ = try repository.save(second, actorID: "actor", requestID: "three", nowEpochSeconds: 103)
        let reopened = AgentDefinitionRepository(store: try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "ignored"))
        let loaded = try reopened.load(definitionID: "agent", definitionRevision: 1, storageRevision: first.revision)
        XCTAssertEqual(loaded.digest, try AgentDefinitionValidator.validate(Data(sample.utf8)).digest)
        XCTAssertThrowsError(try reopened.load(definitionID: "agent", definitionRevision: 2, storageRevision: first.revision))
    }

    func testEventFailureRollsBackPublication() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let repository = AgentDefinitionRepository(store: store)
        try store.executeRawForTesting("CREATE TRIGGER fail_definition_event BEFORE INSERT ON event_log BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        XCTAssertThrowsError(try repository.save(Data(sample.utf8), actorID: "actor", requestID: "one", nowEpochSeconds: 100))
        try store.executeRawForTesting("DROP TRIGGER fail_definition_event")
        XCTAssertFalse(try repository.save(Data(sample.utf8), actorID: "actor", requestID: "one", nowEpochSeconds: 101).idempotentReplay)
    }
}
