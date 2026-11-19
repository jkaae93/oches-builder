import Foundation

enum TemplateNodeKind: String { case agent, task, tool, memory, evaluation, approval }
enum TemplateRelationKind: String { case dependency, data, roleBinding, toolRef, memoryRef, evaluationRef, approvalRef }
struct TemplateGraphNode { let kind: TemplateNodeKind; let ports: GraphPortNode }
struct TemplateGraphRelation {
    let kind: TemplateRelationKind
    let source: String
    let target: String
    let sourcePort: String?
    let targetPort: String?
}
enum TemplateRelationError: Error { case invalidReference, invalidRelation, duplicateRelation, ambiguousRole, limitExceeded }

enum TemplateRelationValidator {
    static func validate(nodes: [TemplateGraphNode], relations: [TemplateGraphRelation], externalInputs: [GraphPortReference]) throws {
        guard !nodes.isEmpty, nodes.count <= 1024, relations.count <= 4096 else { throw TemplateRelationError.limitExceeded }
        try GraphPortValidator.validate(nodes: nodes.map { GraphPortNode(identifier: $0.ports.identifier, inputs: [], outputs: []) },
            edges: [], externalInputs: [])
        let lookup = Dictionary(uniqueKeysWithValues: nodes.map { (Data($0.ports.identifier.utf8), $0) })
        var seen = Set<Data>()
        var roles = Set<Data>()
        var dependencies: [TaskDependency] = []
        var dataEdges: [GraphDataEdge] = []
        var taskFlows: [TaskDependency] = []
        for relation in relations {
            guard let source = lookup[Data(relation.source.utf8)], let target = lookup[Data(relation.target.utf8)],
                  !relation.source.utf8.elementsEqual(relation.target.utf8) else { throw TemplateRelationError.invalidReference }
            let identity = try canonicalizeJSON(.array([.string(relation.kind.rawValue), .string(relation.source),
                .string(relation.target), relation.sourcePort.map { .string($0) } ?? .null,
                relation.targetPort.map { .string($0) } ?? .null]))
            guard seen.insert(identity).inserted else { throw TemplateRelationError.duplicateRelation }
            switch relation.kind {
            case .data, .dependency:
                guard let sourcePort = relation.sourcePort, let targetPort = relation.targetPort,
                      let output = source.ports.outputs.first(where: { $0.identifier.utf8.elementsEqual(sourcePort.utf8) }),
                      let input = target.ports.inputs.first(where: { $0.identifier.utf8.elementsEqual(targetPort.utf8) })
                else { throw TemplateRelationError.invalidReference }
                if relation.kind == .dependency {
                    guard source.kind == .task, target.kind == .task, output.type == .control, input.type == .control
                    else { throw TemplateRelationError.invalidRelation }
                    dependencies.append(TaskDependency(predecessor: relation.source, successor: relation.target))
                } else {
                    dataEdges.append(GraphDataEdge(source: GraphPortReference(node: relation.source, port: sourcePort),
                        target: GraphPortReference(node: relation.target, port: targetPort)))
                    if source.kind == .task && target.kind == .task {
                        taskFlows.append(TaskDependency(predecessor: relation.source, successor: relation.target))
                    }
                }
            default:
                guard relation.sourcePort == nil, relation.targetPort == nil else { throw TemplateRelationError.invalidRelation }
                let allowed: Bool
                switch relation.kind {
                case .roleBinding:
                    allowed = source.kind == .task && target.kind == .agent
                    guard roles.insert(Data(relation.source.utf8)).inserted else { throw TemplateRelationError.ambiguousRole }
                case .toolRef: allowed = (source.kind == .agent || source.kind == .task) && target.kind == .tool
                case .memoryRef: allowed = (source.kind == .agent || source.kind == .task) && target.kind == .memory
                case .evaluationRef: allowed = source.kind == .task && target.kind == .evaluation
                case .approvalRef: allowed = source.kind == .task && target.kind == .approval
                default: allowed = false
                }
                guard allowed else { throw TemplateRelationError.invalidRelation }
            }
        }
        try GraphPortValidator.validate(nodes: nodes.map(\.ports), edges: dataEdges, externalInputs: externalInputs)
        let tasks = nodes.filter { $0.kind == .task }.map { $0.ports.identifier }
        if !tasks.isEmpty { _ = try TaskDependencyValidator.validate(tasks: tasks, dependencies: dependencies, dataFlows: taskFlows) }
    }
}
