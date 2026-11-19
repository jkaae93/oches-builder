import Foundation

enum AgentDefinitionValidationError: Error, Equatable {
    case invalidDefinition
    case unsupportedVersion
}

struct ValidatedAgentDefinition {
    let definitionID: String
    let revision: UInt64
    let digest: Data
    let value: RawJSONValue
}

enum AgentDefinitionValidator {
    static func validate(_ data: Data) throws -> ValidatedAgentDefinition {
        let value = try validateUniqueJSONKeys(data, maximumBytes: 262_144,
            maximumDepth: 32, maximumStringBytes: 65_536)
        let fields = try object(value, keys: ["schemaVersion", "definitionId", "revision", "role",
            "instructions", "inputs", "outputs", "tools", "permissions", "resourceLimits"])
        let version = try object(fields["schemaVersion"]!, keys: ["major", "minor"])
        guard try integer(version["major"]!, maximum: 9_007_199_254_740_991, minimum: 0) == 1,
              try integer(version["minor"]!, maximum: 9_007_199_254_740_991, minimum: 0) == 0
        else { throw AgentDefinitionValidationError.unsupportedVersion }
        let identifier = try id(fields["definitionId"]!)
        let revision = try integer(fields["revision"]!, maximum: 9_007_199_254_740_991)
        _ = try text(fields["role"]!)
        _ = try text(fields["instructions"]!)
        for direction in ["inputs", "outputs"] {
            var identifiers = Set<Data>()
            for port in try array(fields[direction]!, maximum: 128) {
                let members = try object(port, keys: ["portId", "type", "required"])
                guard identifiers.insert(Data(try id(members["portId"]!).utf8)).inserted,
                      ["text", "json", "artifactRef", "control"].contains(try text(members["type"]!)),
                      case .bool = members["required"]! else { throw AgentDefinitionValidationError.invalidDefinition }
            }
        }
        var tools = Set<Data>()
        for tool in try array(fields["tools"]!, maximum: 256) {
            guard tools.insert(Data(try id(tool).utf8)).inserted else { throw AgentDefinitionValidationError.invalidDefinition }
        }
        for permission in try array(fields["permissions"]!, maximum: 256) {
            let members = try object(permission, keys: ["action", "scope", "approvalRequired"])
            _ = try id(members["action"]!)
            _ = try text(members["scope"]!)
            guard case .bool = members["approvalRequired"]! else { throw AgentDefinitionValidationError.invalidDefinition }
        }
        let limits = try object(fields["resourceLimits"]!, keys: ["maxDurationSeconds", "maxAttempts"])
        _ = try integer(limits["maxDurationSeconds"]!, maximum: 86_400)
        _ = try integer(limits["maxAttempts"]!, maximum: 100)
        return ValidatedAgentDefinition(definitionID: identifier, revision: revision,
            digest: try canonicalSHA256(value), value: value)
    }

    private static func object(_ value: RawJSONValue, keys: Set<String>) throws -> [String: RawJSONValue] {
        guard case .object(let members) = value, members.count == keys.count,
              Set(members.map { $0.0 }) == keys else { throw AgentDefinitionValidationError.invalidDefinition }
        return Dictionary(uniqueKeysWithValues: members)
    }

    private static func array(_ value: RawJSONValue, maximum: Int) throws -> [RawJSONValue] {
        guard case .array(let items) = value, items.count <= maximum else { throw AgentDefinitionValidationError.invalidDefinition }
        return items
    }

    private static func text(_ value: RawJSONValue) throws -> String {
        guard case .string(let string) = value, string.utf8.count <= 65_536,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AgentDefinitionValidationError.invalidDefinition }
        return string
    }

    private static func id(_ value: RawJSONValue) throws -> String {
        let string = try text(value)
        guard string.utf8.count <= 128,
              string.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil
        else { throw AgentDefinitionValidationError.invalidDefinition }
        return string
    }

    private static func integer(_ value: RawJSONValue, maximum: UInt64, minimum: UInt64 = 1) throws -> UInt64 {
        guard case .number(let token) = value, token.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt64(token), number >= minimum, number <= maximum
        else { throw AgentDefinitionValidationError.invalidDefinition }
        return number
    }
}
