import Foundation

struct SchedulingTaskSnapshot: Codable {
    let taskID: String
    let workspaceID: String
    let state: TaskLifecycleState
    let attemptState: ExecutionAttemptState?
    let enqueueSequence: UInt64
    let installationID: String
    let accountRef: String
    let isolation: CapabilityStatus
    let exclusiveResourceIDs: [String]
}

enum FIFOSchedulingPlanner {
    private struct Account: Hashable { let installation: Data; let account: Data }

    static func select(
        workspaceID: String,
        tasks: [SchedulingTaskSnapshot],
        dependencies: [TaskDependency],
        externalOccupied: [SchedulingTaskSnapshot] = []
    ) throws -> [String] {
        func isValidTask(_ task: SchedulingTaskSnapshot) -> Bool {
            task.workspaceID.utf8.elementsEqual(workspaceID.utf8)
                && !task.installationID.isEmpty
                && !task.accountRef.isEmpty
                && task.exclusiveResourceIDs.count <= 256
                && task.exclusiveResourceIDs.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) })
        }
        guard !workspaceID.isEmpty,
              tasks.allSatisfy(isValidTask),
              externalOccupied.allSatisfy(isValidTask)
        else { throw TaskDependencyError.invalidReference }
        _ = try TaskDependencyValidator.validate(tasks: tasks.map(\.taskID), dependencies: dependencies, dataFlows: [])
        let lookup = Dictionary(uniqueKeysWithValues: tasks.map { (Data($0.taskID.utf8), $0) })
        var predecessors: [Data: [Data]] = [:]
        for edge in dependencies { predecessors[Data(edge.successor.utf8), default: []].append(Data(edge.predecessor.utf8)) }
        func account(_ task: SchedulingTaskSnapshot) -> Account { Account(installation: Data(task.installationID.utf8), account: Data(task.accountRef.utf8)) }
        func isOccupied(_ task: SchedulingTaskSnapshot) -> Bool {
            task.state == .prepared || task.state == .running || task.attemptState?.isActiveOrUncertain == true
        }
        let occupied = tasks.filter(isOccupied) + externalOccupied.filter(isOccupied)
        var slots = max(0, 4 - occupied.count)
        var activeAccounts: [Account: Bool] = [:]
        var resources = Set<Data>()
        for task in occupied {
            let key = account(task)
            activeAccounts[key] = (activeAccounts[key] ?? true) && task.isolation == .supported
            resources.formUnion(task.exclusiveResourceIDs.map { Data($0.utf8) })
        }
        let ordered = tasks.enumerated().sorted {
            $0.element.enqueueSequence == $1.element.enqueueSequence ? $0.offset < $1.offset : $0.element.enqueueSequence < $1.element.enqueueSequence
        }
        var selected: [String] = []
        for (_, task) in ordered where slots > 0 {
            guard task.state == .ready, task.attemptState?.isActiveOrUncertain != true,
                  (predecessors[Data(task.taskID.utf8)] ?? []).allSatisfy({
                      lookup[$0]?.state == .succeeded && lookup[$0]?.attemptState?.isActiveOrUncertain != true
                  }) else { continue }
            let key = account(task)
            if let isolation = activeAccounts[key], !isolation || task.isolation != .supported { continue }
            let required = Set(task.exclusiveResourceIDs.map { Data($0.utf8) })
            guard resources.isDisjoint(with: required) else { continue }
            selected.append(task.taskID)
            slots -= 1
            activeAccounts[key] = (activeAccounts[key] ?? true) && task.isolation == .supported
            resources.formUnion(required)
        }
        return selected
    }
}
