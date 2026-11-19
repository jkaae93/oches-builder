import Foundation

struct TemplateSnapshotRepository {
    private struct Payload: Codable {
        let schemaVersion: Int
        let content: Data
        let source: RevisionRef?
    }
    let store: SQLiteStore

    func saveVersionSnapshot(familyID: String, versionID: String, data: Data, actorID: String,
                             requestID: String, now: Int64) throws -> TransitionResult {
        let objectID = try key("version", familyID) + "/" + component(versionID)
        return try commit(objectID: objectID, data: data, source: nil, expected: nil,
            operation: "template.snapshot.store", actorID: actorID, requestID: requestID, now: now)
    }

    func instantiate(instanceID: String, sourceVersion: RevisionRef, actorID: String,
                     requestID: String, now: Int64) throws -> TransitionResult {
        guard sourceVersion.objectID.hasPrefix("arc15/version/") else { throw StorageError.invalidInput }
        let source = try load(sourceVersion)
        return try commit(objectID: key("instance", instanceID), data: source.canonicalContent,
            source: sourceVersion, expected: nil, operation: "template.instance.create",
            actorID: actorID, requestID: requestID, now: now)
    }

    func editInstance(instanceID: String, revision: RevisionRef, data: Data, actorID: String,
                      requestID: String, now: Int64) throws -> TransitionResult {
        let objectID = try key("instance", instanceID)
        guard revision.objectID.utf8.elementsEqual(objectID.utf8) else { throw StorageError.invalidInput }
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: objectID)
        guard snapshot.ownerModule == "ARC-15" else { throw StorageError.versionConflict }
        let old = try JSONDecoder().decode(Payload.self, from: Data(snapshot.stateJSON.utf8))
        guard old.schemaVersion == 1, old.source != nil else { throw StorageError.corrupt("invalid instance payload") }
        return try commit(objectID: objectID, data: data, source: old.source, expected: revision,
            operation: "template.instance.edit", actorID: actorID, requestID: requestID, now: now)
    }

    func load(_ revision: RevisionRef) throws -> TemplateExchangeCandidate {
        guard revision.objectID.hasPrefix("arc15/version/") || revision.objectID.hasPrefix("arc15/instance/")
        else { throw StorageError.invalidInput }
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: revision.objectID)
        guard snapshot.revision == revision, snapshot.ownerModule == "ARC-15" else { throw StorageError.versionConflict }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(snapshot.stateJSON.utf8))
        guard payload.schemaVersion == 1 else { throw StorageError.corrupt("unsupported template snapshot") }
        return try TemplateExchangeCandidate.parse(payload.content)
    }

    private func commit(objectID: String, data: Data, source: RevisionRef?, expected: RevisionRef?, operation: String,
                        actorID: String, requestID: String, now: Int64) throws -> TransitionResult {
        let candidate = try TemplateExchangeCandidate.parse(data)
        let payload = Payload(schemaVersion: 1, content: candidate.canonicalContent, source: source)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(payload)
        return try store.commitTransition(TransitionRequest(actorID: actorID, workspaceID: store.workspaceID,
            operation: operation, requestID: requestID, objectID: objectID, ownerModule: "ARC-15", expectedRevision: expected,
            normalizedInput: .object([("payload", .string(String(decoding: json, as: UTF8.self)))]),
            nextStateJSON: String(decoding: json, as: UTF8.self),
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-15", kind: operation, payloadJSON: "{}", observedAt: now)],
            responseJSON: "{}", nowEpochSeconds: now))
    }

    private func key(_ kind: String, _ identifier: String) throws -> String { "arc15/" + kind + "/" + (try component(identifier)) }
    private func component(_ value: String) throws -> String {
        guard value.utf8.count <= 128,
              value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil else { throw StorageError.invalidInput }
        return value
    }
}
