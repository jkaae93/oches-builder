import Foundation

enum GraphPortType: String { case text, json, artifactRef, control }
struct GraphPort { let identifier: String; let type: GraphPortType; let required: Bool }
struct GraphPortNode { let identifier: String; let inputs: [GraphPort]; let outputs: [GraphPort] }
struct GraphPortReference { let node: String; let port: String }
struct GraphDataEdge { let source: GraphPortReference; let target: GraphPortReference }
enum GraphPortError: Error, Equatable {
    case invalidIdentifier, limitExceeded, invalidReference, portMismatch, jsonCompatibilityUnknown, multipleSources, missingInput
}

enum GraphPortValidator {
    static func validate(nodes: [GraphPortNode], edges: [GraphDataEdge], externalInputs: [GraphPortReference]) throws {
        guard !nodes.isEmpty, nodes.count <= 1024, edges.count <= 4096, externalInputs.count <= 131_072
        else { throw GraphPortError.limitExceeded }
        func key(_ identifier: String) throws -> Data {
            guard identifier.utf8.count <= 128,
                  identifier.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil
            else { throw GraphPortError.invalidIdentifier }
            return Data(identifier.utf8)
        }
        struct Endpoint: Hashable { let node: Data; let port: Data }
        var inputs: [Endpoint: GraphPort] = [:]
        var outputs: [Endpoint: GraphPort] = [:]
        var nodeIDs = Set<Data>()
        for node in nodes {
            let nodeKey = try key(node.identifier)
            guard nodeIDs.insert(nodeKey).inserted else { throw GraphPortError.invalidIdentifier }
            guard node.inputs.count <= 128, node.outputs.count <= 128 else { throw GraphPortError.limitExceeded }
            for port in node.inputs {
                let endpoint = Endpoint(node: nodeKey, port: try key(port.identifier))
                guard inputs.updateValue(port, forKey: endpoint) == nil else { throw GraphPortError.invalidIdentifier }
            }
            for port in node.outputs {
                let endpoint = Endpoint(node: nodeKey, port: try key(port.identifier))
                guard outputs.updateValue(port, forKey: endpoint) == nil else { throw GraphPortError.invalidIdentifier }
            }
        }
        var sources = Set<Endpoint>()
        for reference in externalInputs {
            let target = Endpoint(node: try key(reference.node), port: try key(reference.port))
            guard let port = inputs[target], port.type != .control else { throw GraphPortError.invalidReference }
            guard sources.insert(target).inserted else { throw GraphPortError.multipleSources }
        }
        var jsonUnknown = false
        for edge in edges {
            let source = Endpoint(node: try key(edge.source.node), port: try key(edge.source.port))
            let target = Endpoint(node: try key(edge.target.node), port: try key(edge.target.port))
            guard source.node != target.node, let output = outputs[source], let input = inputs[target]
            else { throw GraphPortError.invalidReference }
            guard output.type == input.type, output.type != .control else { throw GraphPortError.portMismatch }
            guard sources.insert(target).inserted else { throw GraphPortError.multipleSources }
            if output.type == .json { jsonUnknown = true }
        }
        for (endpoint, port) in inputs where port.required && port.type != .control {
            guard sources.contains(endpoint) else { throw GraphPortError.missingInput }
        }
        if jsonUnknown { throw GraphPortError.jsonCompatibilityUnknown }
    }
}
