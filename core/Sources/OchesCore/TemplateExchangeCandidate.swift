import Foundation

enum TemplateExchangeError: Error, Equatable { case invalidEnvelope, unsupportedVersion, limitExceeded }

struct TemplateExchangeCandidate {
    let canonicalContent: Data
    let contentDigest: Data
    let nodes: [RawJSONValue]
    let edges: [RawJSONValue]

    static func parse(_ data: Data) throws -> TemplateExchangeCandidate {
        let value = try validateUniqueJSONKeys(data, maximumBytes: 1_048_576, maximumDepth: 32, maximumStringBytes: 65_536)
        let root = try object(value, required: ["schemaVersion", "metadata", "nodes", "edges", "requirements"], optional: ["externalInputs"])
        let version = try object(root["schemaVersion"]!, required: ["major", "minor"])
        guard case .number("1") = version["major"]!, case .number("0") = version["minor"]!
        else { throw TemplateExchangeError.unsupportedVersion }
        let metadata = try object(root["metadata"]!, required: ["name", "description", "tags", "useCases"])
        _ = try text(metadata["name"]!, nonempty: true)
        _ = try text(metadata["description"]!, nonempty: false)
        for field in ["tags", "useCases"] {
            for item in try array(metadata[field]!, maximum: 256) { _ = try text(item, nonempty: true) }
        }
        let requirements = try object(root["requirements"]!, required: ["capabilities", "permissions"])
        _ = try array(requirements["capabilities"]!, maximum: 256)
        _ = try array(requirements["permissions"]!, maximum: 256)
        let nodes = try array(root["nodes"]!, maximum: 1024)
        guard !nodes.isEmpty else { throw TemplateExchangeError.invalidEnvelope }
        let edges = try array(root["edges"]!, maximum: 4096)
        if let external = root["externalInputs"] { _ = try array(external, maximum: 131_072) }
        let canonical = try canonicalizeJSON(value)
        guard canonical.count <= 1_048_576 else { throw TemplateExchangeError.limitExceeded }
        return TemplateExchangeCandidate(canonicalContent: canonical,
            contentDigest: try canonicalSHA256(value), nodes: nodes, edges: edges)
    }

    private static func object(_ value: RawJSONValue, required: Set<String>, optional: Set<String> = []) throws -> [String: RawJSONValue] {
        guard case .object(let members) = value else { throw TemplateExchangeError.invalidEnvelope }
        let keys = Set(members.map { $0.0 })
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional))
        else { throw TemplateExchangeError.invalidEnvelope }
        return Dictionary(uniqueKeysWithValues: members)
    }

    private static func array(_ value: RawJSONValue, maximum: Int) throws -> [RawJSONValue] {
        guard case .array(let items) = value else { throw TemplateExchangeError.invalidEnvelope }
        guard items.count <= maximum else { throw TemplateExchangeError.limitExceeded }
        return items
    }

    private static func text(_ value: RawJSONValue, nonempty: Bool) throws -> String {
        guard case .string(let string) = value, string.utf8.count <= 65_536,
              !nonempty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw TemplateExchangeError.invalidEnvelope }
        return string
    }
}
