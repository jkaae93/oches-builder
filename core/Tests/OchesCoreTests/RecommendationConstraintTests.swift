import XCTest
@testable import OchesCore

final class RecommendationConstraintTests: XCTestCase {
    func testContradictionsMissingAndWrongTypesRemainVisible() throws {
        let constraints = [
            RecommendationConstraint(constraintID: "read-only", subject: "writes", predicate: .equals, value: .boolean(false), version: "1"),
            RecommendationConstraint(constraintID: "requires-write", subject: "writes", predicate: .equals, value: .boolean(true), version: "1"),
            RecommendationConstraint(constraintID: "bounded", subject: "workers", predicate: .atMost, value: .integer(4), version: "1"),
            RecommendationConstraint(constraintID: "resume", subject: "resume", predicate: .equals, value: .boolean(true), version: "1")]
        let results = try RecommendationConstraintEvaluator.evaluate(constraints, facts: ["writes": .boolean(false), "workers": .text("4")])
        XCTAssertEqual(results.map(\.result), [.pass, .fail, .unknown, .unknown])
        XCTAssertThrowsError(try RecommendationConstraintEvaluator.evaluate([constraints[0], constraints[0]], facts: [:]))
        XCTAssertEqual(ArchitecturePattern.allCases.count, 6)
    }
}
