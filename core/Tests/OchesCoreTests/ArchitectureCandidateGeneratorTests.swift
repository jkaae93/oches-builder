import XCTest
@testable import OchesCore

final class ArchitectureCandidateGeneratorTests: XCTestCase {
    func testSixCandidatesRetainBaselineBoundsEvidenceAndUnknowns() throws {
        let constraints = [RecommendationConstraint(constraintID: "one-task", subject: "taskCount", predicate: .atMost, value: .integer(1), version: "1"),
            RecommendationConstraint(constraintID: "resume", subject: "resume", predicate: .equals, value: .boolean(true), version: "1")]
        let candidates = try ArchitectureCandidateGenerator.generate(constraints: constraints)
        XCTAssertEqual(candidates.count, 6)
        XCTAssertEqual(candidates.first?.pattern, .singleAgent)
        XCTAssertEqual(candidates.first?.constraints.map(\.result), [.pass, .unknown])
        for candidate in candidates {
            XCTAssertFalse(candidate.claim.isEmpty)
            XCTAssertFalse(candidate.evidenceRefs.isEmpty)
            XCTAssertTrue(candidate.uncertainties.contains("candidate_not_executable"))
            if candidate.pattern != .singleAgent {
                XCTAssertTrue(candidate.alternatives.contains(.singleAgent))
                XCTAssertEqual(candidate.constraints.first?.result, .fail)
            }
            if candidate.pattern == .routing || candidate.pattern == .evaluatorOptimizer {
                XCTAssertEqual(candidate.structuralSupport, .fail)
            }
            XCTAssertNoThrow(try TaskDependencyValidator.validate(tasks: candidate.tasks, dependencies: candidate.dependencies, dataFlows: []))
        }
    }
}
