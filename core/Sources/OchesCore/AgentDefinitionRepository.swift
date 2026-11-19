import Foundation

struct AgentDefinitionRepository {
    let store: SQLiteStore

    func save(_ data: Data, actorID: String, requestID: String,
              nowEpochSeconds: Int64) throws -> TransitionResult {
        let definition = try AgentDefinitionValidator.validate(data)
        guard !actorID.isEmpty, !actorID.utf8.contains(0),
              !requestID.isEmpty, !requestID.utf8.contains(0),
              let json = String(data: data, encoding: .utf8) else { throw StorageError.invalidInput }
        let objectID = Self.objectID(definition.definitionID, revision: definition.revision)
        return try store.commitTransition(TransitionRequest(actorID: actorID, workspaceID: store.workspaceID,
            operation: "definition.publish", requestID: requestID, objectID: objectID, ownerModule: "ARC-04",
            expectedRevision: nil, normalizedInput: definition.value, nextStateJSON: json,
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-04", kind: "definition.published",
                payloadJSON: "{}", observedAt: nowEpochSeconds)], responseJSON: "{}", nowEpochSeconds: nowEpochSeconds))
    }

    func load(definitionID: String, definitionRevision: UInt64, storageRevision: RevisionRef) throws -> ValidatedAgentDefinition {
        let objectID = Self.objectID(definitionID, revision: definitionRevision)
        guard objectID.utf8.elementsEqual(storageRevision.objectID.utf8) else { throw StorageError.invalidInput }
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: objectID)
        guard snapshot.revision == storageRevision else { throw StorageError.versionConflict }
        guard snapshot.ownerModule == "ARC-04" else { throw StorageError.corrupt("invalid definition owner") }
        let definition = try AgentDefinitionValidator.validate(Data(snapshot.stateJSON.utf8))
        guard definition.definitionID.utf8.elementsEqual(definitionID.utf8), definition.revision == definitionRevision
        else { throw StorageError.corrupt("invalid definition binding") }
        return definition
    }

    func planExport(definitionID: String, definitionRevision: UInt64, binding: AgentExportBinding,
                    mappings: [AgentFieldMapping]) throws -> AgentExportPlan {
        let definition = try load(definitionID: definitionID, definitionRevision: definitionRevision,
            storageRevision: binding.definitionRevision)
        return try AgentExportPlan.build(definition: definition, binding: binding, mappings: mappings)
    }

    static func objectID(_ identifier: String, revision: UInt64) -> String {
        "arc04/definition/\(identifier)/\(revision)"
    }
}
