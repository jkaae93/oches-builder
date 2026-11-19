import XCTest
@testable import OchesCore

final class FIFOSchedulingPlannerTests: XCTestCase {
    private func task(_ identifier: String, sequence: UInt64, state: TaskLifecycleState = .ready,
                      attempt: ExecutionAttemptState? = nil, account: String? = nil,
                      isolation: CapabilityStatus = .unknown, resources: [String] = []) -> SchedulingTaskSnapshot {
        SchedulingTaskSnapshot(taskID: identifier, workspaceID: "ws", state: state, attemptState: attempt,
            enqueueSequence: sequence, installationID: "installation", accountRef: account ?? identifier,
            isolation: isolation, exclusiveResourceIDs: resources)
    }

    func testFourSlotsFIFOAndEvaluatingPredecessorIsNotSuccess() throws {
        let tasks = (1...6).reversed().map { task("task-\($0)", sequence: UInt64($0)) }
        XCTAssertEqual(try FIFOSchedulingPlanner.select(workspaceID: "ws", tasks: tasks, dependencies: []), ["task-1", "task-2", "task-3", "task-4"])
        let edge = TaskDependency(predecessor: "first", successor: "second")
        XCTAssertEqual(try FIFOSchedulingPlanner.select(workspaceID: "ws", tasks: [task("first", sequence: 1, state: .evaluating), task("second", sequence: 2)], dependencies: [edge]), [])
        XCTAssertEqual(try FIFOSchedulingPlanner.select(workspaceID: "ws", tasks: [task("first", sequence: 1, state: .succeeded), task("second", sequence: 2)], dependencies: [edge]), ["second"])
    }

    func testAccountResourceAndUnknownAttemptBlockConcurrency() throws {
        let shared = [task("a", sequence: 1, account: "shared"), task("b", sequence: 2, account: "shared")]
        XCTAssertEqual(try FIFOSchedulingPlanner.select(workspaceID: "ws", tasks: shared, dependencies: []), ["a"])
        let resources = [task("a", sequence: 1, resources: ["canonical-resource"]), task("b", sequence: 2, resources: ["canonical-resource"])]
        XCTAssertEqual(try FIFOSchedulingPlanner.select(workspaceID: "ws", tasks: resources, dependencies: []), ["a"])
        let uncertain = [task("unknown", sequence: 0, state: .blocked, attempt: .unknown, account: "shared"),
            task("retry", sequence: 1, account: "shared"), task("other", sequence: 2)]
        XCTAssertEqual(try FIFOSchedulingPlanner.select(workspaceID: "ws", tasks: uncertain, dependencies: []), ["other"])
        XCTAssertThrowsError(try FIFOSchedulingPlanner.select(workspaceID: "different", tasks: shared, dependencies: []))
    }
}
