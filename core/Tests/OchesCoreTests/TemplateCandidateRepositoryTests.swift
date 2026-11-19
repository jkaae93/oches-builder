import Foundation
import XCTest
@testable import OchesCore

final class TemplateCandidateRepositoryTests: XCTestCase {
    func testDurableCandidateReplayExpiryAndProvenanceConflict() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db").path
        let repository = TemplateCandidateRepository(store: try SQLiteStore(path: path, workspaceID: "ws", initialStoreGeneration: "gen"))
        let data = Data(#"{"schemaVersion":{"major":1,"minor":0},"metadata":{"name":"fixture","description":"","tags":[],"useCases":[]},"nodes":[{}],"edges":[],"requirements":{"capabilities":[],"permissions":[]}}"#.utf8)
        let staged = try repository.stage(candidateID: "candidate", data: data, provenance: "untrusted fixture",
            actorID: "actor", requestID: "request", now: 100)
        XCTAssertTrue(try repository.stage(candidateID: "candidate", data: data, provenance: "untrusted fixture",
            actorID: "actor", requestID: "request", now: 101).idempotentReplay)
        XCTAssertThrowsError(try repository.stage(candidateID: "candidate", data: data, provenance: "other",
            actorID: "actor", requestID: "request", now: 101))
        let reopened = TemplateCandidateRepository(store: try SQLiteStore(path: path, workspaceID: "ws"))
        let loaded = try reopened.load(candidateID: "candidate", revision: staged.revision, now: 86_499)
        XCTAssertEqual(loaded.provenance, "untrusted fixture")
        XCTAssertEqual(loaded.candidate.contentDigest, try TemplateExchangeCandidate.parse(data).contentDigest)
        XCTAssertThrowsError(try reopened.load(candidateID: "candidate", revision: staged.revision, now: 86_500))
        XCTAssertThrowsError(try reopened.load(candidateID: "candidate", revision: staged.revision, now: 99))
        XCTAssertThrowsError(try reopened.load(candidateID: "other", revision: staged.revision, now: 101))
        XCTAssertThrowsError(try reopened.expire(candidateID: "candidate", revision: staged.revision, actorID: "actor", requestID: "expire", now: 86_499))
        let expired = try reopened.expire(candidateID: "candidate", revision: staged.revision, actorID: "actor", requestID: "expire", now: 86_500)
        XCTAssertThrowsError(try reopened.load(candidateID: "candidate", revision: expired.revision, now: 86_501))
        let store = try SQLiteStore(path: path, workspaceID: "ws")
        let snapshot = try store.readSnapshot(workspaceID: "ws", objectID: expired.revision.objectID)
        XCTAssertFalse(snapshot.stateJSON.contains("untrusted fixture"))
        XCTAssertFalse(snapshot.stateJSON.contains(data.base64EncodedString()))
        XCTAssertTrue(try repository.stage(candidateID: "candidate", data: data, provenance: "untrusted fixture",
            actorID: "actor", requestID: "request", now: 86_501).idempotentReplay)
        XCTAssertEqual(try store.readSnapshot(workspaceID: "ws", objectID: expired.revision.objectID).revision, expired.revision)
        XCTAssertThrowsError(try repository.stage(candidateID: "candidate", data: data, provenance: "untrusted fixture",
            actorID: "actor", requestID: "new-request", now: 86_501))
    }
}
