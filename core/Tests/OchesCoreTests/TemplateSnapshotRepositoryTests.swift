import Foundation
import XCTest
@testable import OchesCore

final class TemplateSnapshotRepositoryTests: XCTestCase {
    func testVersionImmutabilityAndIndependentInstances() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws")
        let repository = TemplateSnapshotRepository(store: store)
        let data = Data(#"{"schemaVersion":{"major":1,"minor":0},"metadata":{"name":"original","description":"","tags":[],"useCases":[]},"nodes":[{}],"edges":[],"requirements":{"capabilities":[],"permissions":[]}}"#.utf8)
        let version = try repository.saveVersionSnapshot(familyID: "family", versionID: "v1", data: data, actorID: "actor", requestID: "version", now: 100)
        let first = try repository.instantiate(instanceID: "one", sourceVersion: version.revision, actorID: "actor", requestID: "one", now: 101)
        let second = try repository.instantiate(instanceID: "two", sourceVersion: version.revision, actorID: "actor", requestID: "two", now: 101)
        let changed = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "original", with: "edited").utf8)
        let edited = try repository.editInstance(instanceID: "one", revision: first.revision, data: changed, actorID: "actor", requestID: "edit", now: 102)
        let replay = try repository.editInstance(instanceID: "one", revision: first.revision, data: changed, actorID: "actor", requestID: "edit", now: 103)
        XCTAssertTrue(replay.idempotentReplay)
        XCTAssertEqual(replay.revision, edited.revision)
        XCTAssertThrowsError(try repository.editInstance(instanceID: "one", revision: first.revision, data: data,
            actorID: "actor", requestID: "edit", now: 103))
        XCTAssertNotEqual(try repository.load(edited.revision).contentDigest, try repository.load(second.revision).contentDigest)
        XCTAssertEqual(try repository.load(version.revision).contentDigest, try repository.load(second.revision).contentDigest)
        XCTAssertThrowsError(try repository.saveVersionSnapshot(familyID: "family", versionID: "v1", data: changed, actorID: "actor", requestID: "overwrite", now: 103))
        XCTAssertThrowsError(try repository.editInstance(instanceID: "one", revision: first.revision, data: changed, actorID: "actor", requestID: "stale", now: 103))
        try store.executeRawForTesting("CREATE TRIGGER fail_instance_event BEFORE INSERT ON event_log BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        XCTAssertThrowsError(try repository.editInstance(instanceID: "two", revision: second.revision, data: changed,
            actorID: "actor", requestID: "failed-edit", now: 104))
        XCTAssertEqual(try repository.load(second.revision).contentDigest, try repository.load(version.revision).contentDigest)
        try store.executeRawForTesting("DROP TRIGGER fail_instance_event")
        XCTAssertFalse(try repository.editInstance(instanceID: "two", revision: second.revision, data: changed,
            actorID: "actor", requestID: "failed-edit", now: 105).idempotentReplay)
        let sourceID = version.revision.objectID
        try store.executeRawForTesting("DELETE FROM operational_state WHERE object_id = '\(sourceID)'")
        XCTAssertThrowsError(try repository.load(version.revision))
        XCTAssertEqual(try repository.load(edited.revision).contentDigest, try TemplateExchangeCandidate.parse(changed).contentDigest)
    }
}
