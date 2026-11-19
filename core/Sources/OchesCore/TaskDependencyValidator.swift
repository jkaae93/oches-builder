import Foundation

enum TaskDependencyError: Error, Equatable {
    case limitExceeded, invalidIdentifier, invalidReference, duplicateDependency, cycle, missingDataOrder
}

struct TaskDependency: Codable {
    let predecessor: String
    let successor: String
}

enum TaskDependencyValidator {
    static func validate(tasks: [String], dependencies: [TaskDependency], dataFlows: [TaskDependency]) throws -> [String] {
        guard !tasks.isEmpty, tasks.count <= 1024, dependencies.count + dataFlows.count <= 4096
        else { throw TaskDependencyError.limitExceeded }
        var positions: [Data: Int] = [:]
        for (index, identifier) in tasks.enumerated() {
            guard identifier.utf8.count <= 128,
                  identifier.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil,
                  positions.updateValue(index, forKey: Data(identifier.utf8)) == nil
            else { throw TaskDependencyError.invalidIdentifier }
        }
        var adjacency = [[Int]](repeating: [], count: tasks.count)
        var indegrees = [Int](repeating: 0, count: tasks.count)
        var edges = Set<Int>()
        func endpoints(_ edge: TaskDependency) throws -> (Int, Int) {
            guard let source = positions[Data(edge.predecessor.utf8)], let target = positions[Data(edge.successor.utf8)], source != target
            else { throw TaskDependencyError.invalidReference }
            return (source, target)
        }
        for edge in dependencies {
            let (source, target) = try endpoints(edge)
            guard edges.insert(source * tasks.count + target).inserted else { throw TaskDependencyError.duplicateDependency }
            adjacency[source].append(target)
            indegrees[target] += 1
        }
        var ready = tasks.indices.filter { indegrees[$0] == 0 }
        var cursor = 0
        while cursor < ready.count {
            let source = ready[cursor]
            cursor += 1
            for target in adjacency[source] {
                indegrees[target] -= 1
                if indegrees[target] == 0 { ready.append(target) }
            }
        }
        guard ready.count == tasks.count else { throw TaskDependencyError.cycle }
        var reachability: [Int: Set<Int>] = [:]
        for flow in dataFlows {
            let (source, target) = try endpoints(flow)
            if reachability[source] == nil {
                var reached = Set<Int>()
                var pending = adjacency[source]
                while let next = pending.popLast() {
                    if reached.insert(next).inserted { pending.append(contentsOf: adjacency[next]) }
                }
                reachability[source] = reached
            }
            guard reachability[source]!.contains(target) else { throw TaskDependencyError.missingDataOrder }
        }
        return ready.map { tasks[$0] }
    }
}
