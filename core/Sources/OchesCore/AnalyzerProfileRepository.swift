import Foundation

/// Internal adapter. The product entry point must authenticate the caller and
/// bind the approved scope before using it. It neither performs nor grants I/O.
struct AnalyzerProfileRepository {
    private struct Payload: Codable {
        let schemaVersion: Int
        let profile: AnalyzerProfileDraft
    }
    private struct Header: Decodable { let schemaVersion: Int }

    private let store: SQLiteStore
    private static let prefix = "arc02/profile/"

    init(store: SQLiteStore) { self.store = store }

    func save(_ draft: AnalyzerProfileDraft, actorID: String, requestID: String,
              expectedRevision: RevisionRef?, nowEpochSeconds: Int64) throws -> TransitionResult {
        guard validIdentifier(actorID), validIdentifier(requestID), valid(draft),
              draft.workspaceRef.utf8.elementsEqual(store.workspaceID.utf8) else { throw StorageError.invalidInput }
        let objectID = Self.prefix + draft.profileID
        if let expectedRevision, !expectedRevision.objectID.utf8.elementsEqual(objectID.utf8) { throw StorageError.invalidInput }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(Payload(schemaVersion: 1, profile: draft)) }
        catch { throw StorageError.invalidInput }
        guard let json = String(data: data, encoding: .utf8) else { throw StorageError.invalidInput }
        let request = TransitionRequest(actorID: actorID, workspaceID: store.workspaceID,
            operation: "profile.commit", requestID: requestID, objectID: objectID,
            ownerModule: "ARC-02", expectedRevision: expectedRevision, normalizedInput: .object([]),
            nextStateJSON: json, events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-02", kind: "profile.committed", payloadJSON: "{}", observedAt: nowEpochSeconds)],
            responseJSON: "{}", nowEpochSeconds: nowEpochSeconds)
        return try store.commitProfileTransition(request)
    }

    func load(profileID: String, revision: RevisionRef) throws -> AnalyzerProfileDraft {
        guard validIdentifier(profileID), revision.objectID.utf8.elementsEqual((Self.prefix + profileID).utf8) else { throw StorageError.invalidInput }
        let json = try store.readProfileRevision(workspaceID: store.workspaceID, revision: revision)
        let payload: Payload
        let data = Data(json.utf8)
        do {
            _ = try validateUniqueJSONKeys(data, maximumBytes: data.count, maximumDepth: 32, maximumStringBytes: data.count)
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: data)
            guard header.schemaVersion == 1 else { throw StorageError.unavailable("unsupported profile schema") }
            payload = try decoder.decode(Payload.self, from: data)
        }
        catch let error as StorageError { throw error }
        catch { throw StorageError.corrupt("invalid profile payload") }
        guard valid(payload.profile), payload.profile.profileID.utf8.elementsEqual(profileID.utf8),
              payload.profile.workspaceRef.utf8.elementsEqual(store.workspaceID.utf8) else { throw StorageError.corrupt("invalid profile binding") }
        return payload.profile
    }

    private func validIdentifier(_ value: String) -> Bool { !value.isEmpty && !value.utf8.contains(0) }

    private func valid(_ draft: AnalyzerProfileDraft) -> Bool {
        guard validIdentifier(draft.profileID), validIdentifier(draft.workspaceRef), validIdentifier(draft.analyzerVersion),
              draft.analyzedAt.timeIntervalSince1970.isFinite, !draft.roots.isEmpty,
              draft.roots.allSatisfy(validIdentifier) else { return false }
        var paths = Set<Data>()
        for entry in draft.evidence {
            do { _ = try AnalyzerExclusions.classify(relativePath: entry.relativePath) }
            catch { return false }
            guard entry.size >= 0, (0..<1_000_000_000).contains(entry.modifiedNanoseconds),
                  entry.sha256.utf8.count == 64,
                  entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  paths.insert(Data(entry.relativePath.utf8)).inserted else { return false }
        }
        for entry in draft.skipped {
            do { _ = try AnalyzerExclusions.classify(relativePath: entry.relativePath) }
            catch { return false }
            guard entry.size >= 0, (0..<1_000_000_000).contains(entry.modifiedNanoseconds),
                  !entry.reason.isEmpty else { return false }
        }
        return draft.observations.allSatisfy { paths.contains(Data($0.evidencePath.utf8)) } &&
               draft.inferences.allSatisfy { !$0.evidencePaths.isEmpty && $0.evidencePaths.allSatisfy { paths.contains(Data($0.utf8)) } }
    }
}
