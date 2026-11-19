import XCTest
@testable import OchesCore

final class TaskDependencyValidatorTests: XCTestCase {
    func testExplicitTransitiveOrderAndIndependentTasks() throws {
        let edges = [TaskDependency(predecessor: "a", successor: "b"), TaskDependency(predecessor: "b", successor: "c")]
        let order = try TaskDependencyValidator.validate(tasks: ["a", "b", "c", "independent"], dependencies: edges,
            dataFlows: [TaskDependency(predecessor: "a", successor: "c")])
        XCTAssertLessThan(order.firstIndex(of: "a")!, order.firstIndex(of: "c")!)
        XCTAssertEqual(order.count, 4)
        XCTAssertThrowsError(try TaskDependencyValidator.validate(tasks: ["a", "b"], dependencies: [],
            dataFlows: [TaskDependency(predecessor: "a", successor: "b")]))
    }

    func testCyclesDuplicatesMissingReferencesAndBounds() {
        let edge = TaskDependency(predecessor: "a", successor: "b")
        for edges in [[edge, edge], [edge, TaskDependency(predecessor: "b", successor: "a")],
                      [TaskDependency(predecessor: "a", successor: "missing")]] {
            XCTAssertThrowsError(try TaskDependencyValidator.validate(tasks: ["a", "b"], dependencies: edges, dataFlows: []))
        }
        XCTAssertThrowsError(try TaskDependencyValidator.validate(tasks: ["a", "a"], dependencies: [], dataFlows: []))
        XCTAssertThrowsError(try TaskDependencyValidator.validate(tasks: [], dependencies: [], dataFlows: []))
        XCTAssertThrowsError(try TaskDependencyValidator.validate(tasks: (0...1024).map { "task-\($0)" }, dependencies: [], dataFlows: []))
    }
}
