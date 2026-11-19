import Foundation

enum TemplateGraphDecodeError: Error { case invalidSchema, unsupportedNode }
struct TemplateDomainReference {
    let nodeID: String
    let role: String
    let identifier: String
    let revision: String
}
struct DecodedTemplateGraph {
    let nodes: [TemplateGraphNode]
    let relations: [TemplateGraphRelation]
    let externalInputs: [GraphPortReference]
    let domainReferences: [TemplateDomainReference]
    let exchangeDigest: Data
}

enum TemplateGraphDecoder {
    static func decode(_ candidate: TemplateExchangeCandidate) throws -> DecodedTemplateGraph {
        var nodes: [TemplateGraphNode] = []
        var externalInputs: [GraphPortReference] = []
        var domainReferences: [TemplateDomainReference] = []
        for value in candidate.nodes {
            guard case .object(let raw) = value, Set(raw.map { $0.0 }).count == raw.count else { throw TemplateGraphDecodeError.invalidSchema }
            let preliminary = Dictionary(uniqueKeysWithValues: raw)
            guard case .string(let kindText) = preliminary["kind"], let kind = TemplateNodeKind(rawValue: kindText)
            else { throw TemplateGraphDecodeError.unsupportedNode }
            var required: Set<String> = ["id", "kind", "label", "requirements"]
            switch kind {
            case .agent: required.insert("definition")
            case .task: required.formUnion(["goal", "inputs", "outputs", "resourceLimits"])
            case .tool: required.formUnion(["capability", "inputs", "outputs", "permissions"])
            case .memory: required.formUnion(["memoryRef", "evidenceRefs", "inputs", "outputs"])
            case .evaluation: required.formUnion(["criteriaRef", "evaluatorRef", "inputs", "outputs"])
            case .approval: required.formUnion(["action", "targetRef", "scope", "expiresAfterSeconds", "inputs", "outputs"])
            }
            let node = try object(value, required: required, optional: ["externalInputs"])
            let identifier = try string(node["id"]!)
            _ = try string(node["label"]!)
            let inputs: [GraphPort]
            let outputs: [GraphPort]
            if kindText == "agent" {
                let definition = try AgentDefinitionValidator.validate(canonicalizeJSON(node["definition"]!))
                guard case .object(let members) = definition.value else { throw TemplateGraphDecodeError.invalidSchema }
                let fields = Dictionary(uniqueKeysWithValues: members)
                inputs = try ports(fields["inputs"]!)
                outputs = try ports(fields["outputs"]!)
            } else {
                inputs = try ports(node["inputs"]!)
                outputs = try ports(node["outputs"]!)
                switch kind {
                case .task:
                    _ = try string(node["goal"]!)
                    let limits = try object(node["resourceLimits"]!, required: ["maxDurationSeconds", "maxRetries"])
                    try integer(limits["maxDurationSeconds"]!, minimum: 1, maximum: 86_400)
                    try integer(limits["maxRetries"]!, minimum: 0, maximum: 3)
                case .tool:
                    _ = try string(node["capability"]!)
                    guard case .array(let permissions) = node["permissions"]!, permissions.count <= 256 else { throw TemplateGraphDecodeError.invalidSchema }
                    for permission in permissions {
                        let fields = try object(permission, required: ["action", "scope", "approvalRequired"])
                        _ = try string(fields["action"]!)
                        _ = try string(fields["scope"]!)
                        guard case .bool = fields["approvalRequired"]! else { throw TemplateGraphDecodeError.invalidSchema }
                    }
                case .memory:
                    domainReferences.append(try reference(node["memoryRef"]!, nodeID: identifier, role: "memory"))
                    guard case .array(let references) = node["evidenceRefs"]!, !references.isEmpty, references.count <= 256 else { throw TemplateGraphDecodeError.invalidSchema }
                    for value in references { domainReferences.append(try reference(value, nodeID: identifier, role: "evidence")) }
                case .evaluation:
                    domainReferences.append(try reference(node["criteriaRef"]!, nodeID: identifier, role: "criteria"))
                    domainReferences.append(try reference(node["evaluatorRef"]!, nodeID: identifier, role: "evaluator"))
                case .approval:
                    _ = try string(node["action"]!)
                    _ = try string(node["scope"]!)
                    domainReferences.append(try reference(node["targetRef"]!, nodeID: identifier, role: "approvalTarget"))
                    try integer(node["expiresAfterSeconds"]!, minimum: 1, maximum: 900)
                case .agent: throw TemplateGraphDecodeError.invalidSchema
                }
            }
            guard case .array(let requirements) = node["requirements"]!, requirements.count <= 256 else { throw TemplateGraphDecodeError.invalidSchema }
            for requirement in requirements {
                let fields = try object(requirement, required: ["capability", "required"])
                _ = try string(fields["capability"]!)
                guard case .bool = fields["required"]! else { throw TemplateGraphDecodeError.invalidSchema }
            }
            if let external = node["externalInputs"] {
                guard case .array(let identifiers) = external, identifiers.count <= 128 else { throw TemplateGraphDecodeError.invalidSchema }
                for port in identifiers { externalInputs.append(GraphPortReference(node: identifier, port: try string(port))) }
            }
            nodes.append(TemplateGraphNode(kind: kind,
                ports: GraphPortNode(identifier: identifier, inputs: inputs, outputs: outputs)))
        }
        var relations: [TemplateGraphRelation] = []
        for edge in candidate.edges {
            let fields = try object(edge, required: ["kind", "fromNode", "toNode"], optional: ["fromPort", "toPort"])
            guard let kind = TemplateRelationKind(rawValue: try string(fields["kind"]!)) else { throw TemplateGraphDecodeError.invalidSchema }
            relations.append(TemplateGraphRelation(kind: kind, source: try string(fields["fromNode"]!),
                target: try string(fields["toNode"]!), sourcePort: try fields["fromPort"].map(string),
                targetPort: try fields["toPort"].map(string)))
        }
        let root = try validateUniqueJSONKeys(candidate.canonicalContent, maximumBytes: 1_048_576, maximumDepth: 32, maximumStringBytes: 65_536)
        guard case .object(let rootMembers) = root,
              let requirements = rootMembers.first(where: { $0.0 == "requirements" })?.1 else { throw TemplateGraphDecodeError.invalidSchema }
        let requirementFields = try object(requirements, required: ["capabilities", "permissions"])
        guard case .array(let capabilities) = requirementFields["capabilities"]!, capabilities.count <= 256,
              case .array(let permissions) = requirementFields["permissions"]!, permissions.count <= 256
        else { throw TemplateGraphDecodeError.invalidSchema }
        for capability in capabilities {
            let fields = try object(capability, required: ["capability", "required"])
            _ = try string(fields["capability"]!)
            guard case .bool = fields["required"]! else { throw TemplateGraphDecodeError.invalidSchema }
        }
        for permission in permissions {
            let fields = try object(permission, required: ["action", "scope", "approvalRequired"])
            _ = try string(fields["action"]!)
            _ = try string(fields["scope"]!)
            guard case .bool = fields["approvalRequired"]! else { throw TemplateGraphDecodeError.invalidSchema }
        }
        if let external = rootMembers.first(where: { $0.0 == "externalInputs" })?.1 {
            guard case .array(let references) = external else { throw TemplateGraphDecodeError.invalidSchema }
            for reference in references {
                let fields = try object(reference, required: ["node", "port"])
                externalInputs.append(GraphPortReference(node: try string(fields["node"]!), port: try string(fields["port"]!)))
            }
        }
        try TemplateRelationValidator.validate(nodes: nodes, relations: relations, externalInputs: externalInputs)
        return DecodedTemplateGraph(nodes: nodes, relations: relations, externalInputs: externalInputs,
            domainReferences: domainReferences, exchangeDigest: candidate.contentDigest)
    }

    private static func object(_ value: RawJSONValue, required: Set<String>, optional: Set<String> = []) throws -> [String: RawJSONValue] {
        guard case .object(let members) = value else { throw TemplateGraphDecodeError.invalidSchema }
        let keys = Set(members.map { $0.0 })
        guard keys.count == members.count, required.isSubset(of: keys), keys.isSubset(of: required.union(optional))
        else { throw TemplateGraphDecodeError.invalidSchema }
        return Dictionary(uniqueKeysWithValues: members)
    }

    private static func string(_ value: RawJSONValue) throws -> String {
        guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 65_536 else { throw TemplateGraphDecodeError.invalidSchema }
        return text
    }

    private static func ports(_ value: RawJSONValue) throws -> [GraphPort] {
        guard case .array(let ports) = value, ports.count <= 128 else { throw TemplateGraphDecodeError.invalidSchema }
        return try ports.map {
            let fields = try object($0, required: ["portId", "type", "required"])
            guard let type = GraphPortType(rawValue: try string(fields["type"]!)), case .bool(let required) = fields["required"]!
            else { throw TemplateGraphDecodeError.invalidSchema }
            return GraphPort(identifier: try string(fields["portId"]!), type: type, required: required)
        }
    }

    private static func integer(_ value: RawJSONValue, minimum: Int, maximum: Int) throws {
        guard case .number(let token) = value, !token.isEmpty,
              token.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(token),
              number >= minimum, number <= maximum else { throw TemplateGraphDecodeError.invalidSchema }
    }

    private static func reference(_ value: RawJSONValue, nodeID: String, role: String) throws -> TemplateDomainReference {
        let fields = try object(value, required: ["id", "revision"])
        let identifier = try string(fields["id"]!)
        let revision = try string(fields["revision"]!)
        guard identifier.utf8.count <= 128,
              identifier.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil,
              revision.first != "0", revision.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(revision) != nil
        else { throw TemplateGraphDecodeError.invalidSchema }
        return TemplateDomainReference(nodeID: nodeID, role: role, identifier: identifier, revision: revision)
    }
}
