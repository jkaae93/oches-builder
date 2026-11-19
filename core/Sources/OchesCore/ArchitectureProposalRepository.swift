import Foundation

struct ArchitectureProposalRepository {
    private struct Choice: Codable {
        let pattern: String
        let requirements: String
        let claim: String
        let evidence: [String]
        let ruleVersion: String
        let alternatives: [String]
        let uncertainties: [String]
        let tasks: [String]
        let dependencies: [[String]]
        let reasons: [String]
    }
    private struct Record: Codable {
        let schemaVersion: Int
        let pinsDigest: Data
        let createdAt: Int64
        let evidenceRefs: [RevisionRef]
        let uncertainties: [String]
        let choices: [Choice]
    }
    let store: SQLiteStore

    func save(proposalID: String, evaluation: RecommendationEvaluation, actorID: String,
              requestID: String, now: Int64) throws -> TransitionResult {
        let proposal = evaluation.proposal
        try proposal.validateFreshness(current: proposal.pins, now: now)
        guard proposal.pins.digest.count == 32, proposal.candidates.count == 6, evaluation.assessments.count == 6,
              Set(proposal.candidates.map { $0.pattern.rawValue }).count == 6,
              Set(evaluation.assessments.map { $0.pattern.rawValue }).count == 6 else { throw StorageError.invalidInput }
        let choices = try proposal.candidates.map { candidate -> Choice in
            guard let assessment = evaluation.assessments.first(where: { $0.pattern == candidate.pattern }) else { throw StorageError.invalidInput }
            return Choice(pattern: candidate.pattern.rawValue, requirements: assessment.requirements.rawValue,
                claim: candidate.claim, evidence: candidate.evidenceRefs, ruleVersion: candidate.ruleVersion,
                alternatives: candidate.alternatives.map(\.rawValue), uncertainties: candidate.uncertainties,
                tasks: candidate.tasks, dependencies: candidate.dependencies.map { [$0.predecessor, $0.successor] }, reasons: assessment.reasons)
        }
        let record = Record(schemaVersion: 1, pinsDigest: proposal.pins.digest, createdAt: proposal.createdAt,
            evidenceRefs: evaluation.evidenceRefs, uncertainties: evaluation.uncertainties, choices: choices)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try commit(objectID: objectID(proposalID), operation: "proposal.store", payload: encoder.encode(record),
            actorID: actorID, requestID: requestID, now: now)
    }

    func accept(proposalID: String, revision: RevisionRef, pattern: ArchitecturePattern,
                current: RecommendationVersionPins, actorID: String, requestID: String, now: Int64) throws -> TransitionResult {
        let identifier = try objectID(proposalID)
        guard revision.objectID.utf8.elementsEqual(identifier.utf8) else { throw StorageError.invalidInput }
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: identifier)
        guard snapshot.revision == revision, snapshot.ownerModule == "ARC-03" else { throw StorageError.versionConflict }
        let record = try JSONDecoder().decode(Record.self, from: Data(snapshot.stateJSON.utf8))
        guard record.schemaVersion == 1, record.pinsDigest.count == 32 else { throw StorageError.corrupt("invalid proposal") }
        guard now >= record.createdAt, record.createdAt >= 0, now - record.createdAt < 86_400,
              current.digest == record.pinsDigest else { throw TemplateValidationReportError.stale }
        guard let choice = record.choices.first(where: { $0.pattern == pattern.rawValue }), choice.requirements == "pass"
        else { throw StorageError.denied }
        let payload = try canonicalizeJSON(.object([("proposalObject", .string(identifier)),
            ("generation", .string(revision.storeGeneration)), ("revision", .string(revision.revision)),
            ("pattern", .string(pattern.rawValue)), ("inputDigest", .string(current.digest.base64EncodedString())),
            ("executionAuthorized", .bool(false))]))
        return try commit(objectID: identifier + "/acceptance", operation: "proposal.accept", payload: payload,
            actorID: actorID, requestID: requestID, now: now)
    }

    private func commit(objectID: String, operation: String, payload: Data, actorID: String, requestID: String, now: Int64) throws -> TransitionResult {
        let json = String(decoding: payload, as: UTF8.self)
        return try store.commitTransition(TransitionRequest(actorID: actorID, workspaceID: store.workspaceID,
            operation: operation, requestID: requestID, objectID: objectID, ownerModule: "ARC-03", expectedRevision: nil,
            normalizedInput: .object([("payload", .string(json))]), nextStateJSON: json,
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-03", kind: operation, payloadJSON: "{}", observedAt: now)],
            responseJSON: "{}", nowEpochSeconds: now))
    }

    private func objectID(_ value: String) throws -> String {
        guard value.utf8.count <= 128, value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil
        else { throw StorageError.invalidInput }
        return "arc03/proposal/" + value
    }
}
