import Foundation

enum TemplateStructuralReport {
    static func validate(candidate: TemplateExchangeCandidate, binding: TemplateValidationBinding,
                         observedAt: Int64) throws -> TemplateValidationReport {
        let parsed = try TemplateExchangeCandidate.parse(candidate.canonicalContent)
        guard binding.exchangeDigest == parsed.contentDigest else { throw TemplateValidationReportError.invalidBinding }
        let graph = try TemplateGraphDecoder.decode(parsed)
        return try validate(nodes: graph.nodes, relations: graph.relations, externalInputs: graph.externalInputs,
            binding: binding, observedAt: observedAt)
    }

    static func graphDigest(nodes: [TemplateGraphNode], relations: [TemplateGraphRelation], externalInputs: [GraphPortReference]) throws -> Data {
        guard nodes.count <= 1024, relations.count <= 4096, externalInputs.count <= 131_072,
              nodes.allSatisfy({ $0.ports.inputs.count <= 128 && $0.ports.outputs.count <= 128 })
        else { throw TemplateRelationError.limitExceeded }
        func port(_ value: GraphPort) -> RawJSONValue {
            .object([("id", .string(value.identifier)), ("type", .string(value.type.rawValue)), ("required", .bool(value.required))])
        }
        let nodeValues: [RawJSONValue] = nodes.map {
            .object([("id", .string($0.ports.identifier)), ("kind", .string($0.kind.rawValue)),
                ("inputs", .array($0.ports.inputs.map(port))), ("outputs", .array($0.ports.outputs.map(port)))])
        }
        let edgeValues: [RawJSONValue] = relations.map {
            .object([("kind", .string($0.kind.rawValue)), ("source", .string($0.source)), ("target", .string($0.target)),
                ("sourcePort", $0.sourcePort.map { .string($0) } ?? .null),
                ("targetPort", $0.targetPort.map { .string($0) } ?? .null)])
        }
        return try canonicalSHA256(.object([("domain", .string("oches.template.structural-graph.v1")),
            ("nodes", .array(nodeValues)), ("relations", .array(edgeValues)),
            ("externalInputs", .array(externalInputs.map { .object([("node", .string($0.node)), ("port", .string($0.port))]) }))]))
    }

    static func validate(nodes: [TemplateGraphNode], relations: [TemplateGraphRelation], externalInputs: [GraphPortReference],
                         binding: TemplateValidationBinding, observedAt: Int64) throws -> TemplateValidationReport {
        try TemplateRelationValidator.validate(nodes: nodes, relations: relations, externalInputs: externalInputs)
        guard try graphDigest(nodes: nodes, relations: relations, externalInputs: externalInputs) == binding.graphDigest
        else { throw TemplateValidationReportError.invalidBinding }
        return try TemplateValidationReport(binding: binding, observedAt: observedAt, structural: .pass, capability: .unknown, policy: .unknown)
    }
}
