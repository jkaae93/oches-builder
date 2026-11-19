import Foundation

enum AgentMappingQuality: String { case exact, lossy, unsupported, unknown }

struct AgentFieldMapping {
    let field: String
    let quality: AgentMappingQuality
    let targetField: String?
    let officialEvidence: String?
    let experimentEvidence: String?
}

struct AgentExportBinding: Equatable {
    let definitionRevision: RevisionRef
    let definitionDigest: Data
    let adapterVersion: String
    let providerVersion: String
    let capabilitySnapshotID: String
    let capabilityVersion: String
    let targetPath: String
    let targetDigest: Data?

    static func == (lhs: AgentExportBinding, rhs: AgentExportBinding) -> Bool {
        lhs.definitionRevision == rhs.definitionRevision && lhs.definitionDigest == rhs.definitionDigest &&
        lhs.targetDigest == rhs.targetDigest &&
        zip([lhs.adapterVersion, lhs.providerVersion, lhs.capabilitySnapshotID, lhs.capabilityVersion, lhs.targetPath],
            [rhs.adapterVersion, rhs.providerVersion, rhs.capabilitySnapshotID, rhs.capabilityVersion, rhs.targetPath])
            .allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

enum AgentExportPlanError: Error, Equatable {
    case invalidMapping
    case unsafeMapping
    case stale
    case optionalLossApprovalRequired
}

struct AgentExportPlan {
    let binding: AgentExportBinding
    let mappings: [AgentFieldMapping]
    let digest: Data
    let requiresOptionalLossApproval: Bool

    static func build(definition: ValidatedAgentDefinition, binding: AgentExportBinding,
                      mappings: [AgentFieldMapping]) throws -> AgentExportPlan {
        let fields: Set<String> = ["schemaVersion", "definitionId", "revision", "role", "instructions",
            "inputs", "outputs", "tools", "permissions", "resourceLimits"]
        guard definition.digest == binding.definitionDigest,
              binding.definitionRevision.objectID.utf8.elementsEqual(
                AgentDefinitionRepository.objectID(definition.definitionID, revision: definition.revision).utf8),
              binding.definitionRevision.revision == "1", !binding.definitionRevision.storeGeneration.isEmpty,
              !binding.adapterVersion.isEmpty, !binding.providerVersion.isEmpty,
              !binding.capabilitySnapshotID.isEmpty, !binding.capabilityVersion.isEmpty,
              binding.targetPath.hasPrefix("/"), !binding.targetPath.utf8.contains(0),
              binding.targetDigest == nil || binding.targetDigest?.count == 32,
              mappings.count == fields.count, Set(mappings.map(\.field)) == fields
        else { throw AgentExportPlanError.invalidMapping }
        let safety: Set<String> = ["tools", "permissions", "resourceLimits", "inputs", "outputs"]
        var optionalLoss = false
        for mapping in mappings {
            if mapping.quality == .exact {
                guard let target = mapping.targetField, !target.isEmpty,
                      let official = mapping.officialEvidence, !official.isEmpty,
                      let experiment = mapping.experimentEvidence, !experiment.isEmpty
                else { throw AgentExportPlanError.invalidMapping }
            } else {
                guard !safety.contains(mapping.field), mapping.quality == .lossy
                else { throw AgentExportPlanError.unsafeMapping }
                optionalLoss = true
            }
        }
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        let mappingValues: [RawJSONValue] = mappings.sorted { $0.field < $1.field }.map { mapping in
            .object([("field", .string(mapping.field)), ("quality", .string(mapping.quality.rawValue)),
                ("target", mapping.targetField.map { .string($0) } ?? .null),
                ("official", mapping.officialEvidence.map { .string($0) } ?? .null),
                ("experiment", mapping.experimentEvidence.map { .string($0) } ?? .null)])
        }
        let digest = try canonicalSHA256(.object([
            ("domain", .string("oches.agent.export-plan.v1")),
            ("definitionID", .string(definition.definitionID)),
            ("definitionVersion", .string(String(definition.revision))),
            ("objectID", .string(binding.definitionRevision.objectID)),
            ("generation", .string(binding.definitionRevision.storeGeneration)),
            ("revision", .string(binding.definitionRevision.revision)),
            ("definitionDigest", .string(hex(binding.definitionDigest))),
            ("adapter", .string(binding.adapterVersion)), ("provider", .string(binding.providerVersion)),
            ("snapshot", .string(binding.capabilitySnapshotID)), ("capabilityVersion", .string(binding.capabilityVersion)),
            ("targetPath", .string(binding.targetPath)),
            ("targetDigest", binding.targetDigest.map { .string(hex($0)) } ?? .null),
            ("mappings", .array(mappingValues))
        ]))
        return AgentExportPlan(binding: binding, mappings: mappings, digest: digest,
            requiresOptionalLossApproval: optionalLoss)
    }

    func revalidate(current: AgentExportBinding) throws {
        guard binding == current else { throw AgentExportPlanError.stale }
    }
}
