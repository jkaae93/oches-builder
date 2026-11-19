import Foundation

struct TemplateCandidateRepository {
    private struct Payload: Codable {
        let schemaVersion: Int
        let content: Data
        let provenance: String
        let createdAt: Int64
        let expired: Bool?
    }
    let store: SQLiteStore

    func stage(candidateID: String, data: Data, provenance: String, actorID: String,
               requestID: String, now: Int64) throws -> TransitionResult {
        let objectID = try identifier(candidateID)
        guard now >= 0, now <= Int64.max - 86_400, !provenance.isEmpty,
              provenance.utf8.count <= 4096, !provenance.utf8.contains(0)
        else { throw StorageError.invalidInput }
        let candidate = try TemplateExchangeCandidate.parse(data)
        let payload = Payload(schemaVersion: 1, content: candidate.canonicalContent, provenance: provenance, createdAt: now, expired: false)
        let json = try JSONEncoder().encode(payload)
        let digest = candidate.contentDigest.map { String(format: "%02x", $0) }.joined()
        return try store.commitTransition(TransitionRequest(actorID: actorID, workspaceID: store.workspaceID,
            operation: "template.candidate.stage", requestID: requestID, objectID: objectID, ownerModule: "ARC-15",
            expectedRevision: nil, normalizedInput: .object([("contentDigest", .string(digest)), ("provenance", .string(provenance))]),
            nextStateJSON: String(decoding: json, as: UTF8.self),
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-15", kind: "candidate.staged", payloadJSON: "{}", observedAt: now)],
            responseJSON: "{}", nowEpochSeconds: now))
    }

    func load(candidateID: String, revision: RevisionRef, now: Int64) throws -> (candidate: TemplateExchangeCandidate, provenance: String) {
        let objectID = try identifier(candidateID)
        guard revision.objectID.utf8.elementsEqual(objectID.utf8) else { throw StorageError.invalidInput }
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: objectID)
        guard snapshot.revision == revision else { throw StorageError.versionConflict }
        guard snapshot.ownerModule == "ARC-15" else { throw StorageError.corrupt("invalid candidate owner") }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(snapshot.stateJSON.utf8))
        guard payload.schemaVersion == 1, payload.createdAt >= 0 else { throw StorageError.corrupt("invalid candidate payload") }
        guard payload.expired != true, now >= payload.createdAt, now - payload.createdAt < 86_400 else { throw StorageError.denied }
        return (try TemplateExchangeCandidate.parse(payload.content), payload.provenance)
    }

    func expire(candidateID: String, revision: RevisionRef, actorID: String, requestID: String, now: Int64) throws -> TransitionResult {
        let objectID = try identifier(candidateID)
        guard revision.objectID.utf8.elementsEqual(objectID.utf8) else { throw StorageError.invalidInput }
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: objectID)
        guard snapshot.revision == revision else { throw StorageError.versionConflict }
        guard snapshot.ownerModule == "ARC-15" else { throw StorageError.corrupt("invalid candidate owner") }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(snapshot.stateJSON.utf8))
        guard payload.schemaVersion == 1, payload.createdAt >= 0,
              now >= payload.createdAt, now - payload.createdAt >= 86_400 else { throw StorageError.denied }
        let redacted = Payload(schemaVersion: 1, content: Data(), provenance: "", createdAt: payload.createdAt, expired: true)
        let json = try JSONEncoder().encode(redacted)
        return try store.commitTransition(TransitionRequest(actorID: actorID, workspaceID: store.workspaceID,
            operation: "template.candidate.expire", requestID: requestID, objectID: objectID, ownerModule: "ARC-15",
            expectedRevision: revision, normalizedInput: .object([("expired", .bool(true))]),
            nextStateJSON: String(decoding: json, as: UTF8.self),
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-15", kind: "candidate.expired", payloadJSON: "{}", observedAt: now)],
            responseJSON: "{}", nowEpochSeconds: now))
    }

    private func identifier(_ value: String) throws -> String {
        guard value.utf8.count <= 128,
              value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil
        else { throw StorageError.invalidInput }
        return "arc15/candidate/" + value
    }
}
