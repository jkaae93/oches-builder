import Foundation
import XCTest
@testable import OchesCore

final class ArchitectureProposalRepositoryTests: XCTestCase {
    func testPinnedAcceptanceReplayAndStaleDenial() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(path: directory.appendingPathComponent("db").path, workspaceID: "ws")
        let repository = ArchitectureProposalRepository(store: store)
        let pins = RecommendationVersionPins(digest: Data(repeating: 1, count: 32))
        let candidates = try ArchitectureCandidateGenerator.generate(constraints: [])
        let evaluation = RecommendationEvaluation(proposal: ArchitectureProposal(pins: pins, createdAt: 100, candidates: candidates),
            assessments: candidates.map { RecommendationCandidateAssessment(pattern: $0.pattern,
                requirements: $0.pattern == .singleAgent ? .pass : .unknown, reasons: []) },
            capabilityOutcome: .supported, evidenceRefs: [], uncertainties: ["execution_not_authorized"])
        let saved = try repository.save(proposalID: "proposal", evaluation: evaluation, actorID: "actor", requestID: "store", now: 100)
        XCTAssertTrue(try repository.save(proposalID: "proposal", evaluation: evaluation, actorID: "actor", requestID: "store", now: 101).idempotentReplay)
        XCTAssertThrowsError(try repository.accept(proposalID: "proposal", revision: saved.revision, pattern: .chaining,
            current: pins, actorID: "actor", requestID: "unknown", now: 101))
        XCTAssertThrowsError(try repository.accept(proposalID: "proposal", revision: saved.revision, pattern: .singleAgent,
            current: RecommendationVersionPins(digest: Data(repeating: 2, count: 32)), actorID: "actor", requestID: "stale", now: 101))
        let accepted = try repository.accept(proposalID: "proposal", revision: saved.revision, pattern: .singleAgent,
            current: pins, actorID: "actor", requestID: "accept", now: 101)
        XCTAssertTrue(try repository.accept(proposalID: "proposal", revision: saved.revision, pattern: .singleAgent,
            current: pins, actorID: "actor", requestID: "accept", now: 102).idempotentReplay)
        let snapshot = try store.readSnapshot(workspaceID: "ws", objectID: accepted.revision.objectID)
        XCTAssertTrue(snapshot.stateJSON.contains("\"executionAuthorized\":false"))
        XCTAssertThrowsError(try repository.accept(proposalID: "proposal", revision: saved.revision, pattern: .singleAgent,
            current: pins, actorID: "actor", requestID: "expired", now: 86_500))
    }
}
