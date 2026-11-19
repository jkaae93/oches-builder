import Foundation

enum AgentApplyJournalState: String, Codable {
    case applying, applied, conflict, unavailable, partial, unknown
}

struct AgentApplyJournal {
    struct Entry: Codable {
        let schemaVersion: Int
        let documentDigest: String
        let state: AgentApplyJournalState
    }

    let store: SQLiteStore

    func apply(document: AgentExportDocument, currentBinding: AgentExportBinding,
               planID: String, approvalID: String, actorID: String, clientID: String,
               keyID: String, nonceID: String, rootPath: String, requestID: String, now: Int64,
               writer: () -> AgentConfigWriteOutcome) throws -> AgentApplyJournalState {
        try document.plan.revalidate(current: currentBinding)
        guard document.rootIdentity != nil, document.rootSessionID != nil else { throw AgentExportPlanError.stale }
        guard !document.plan.requiresOptionalLossApproval else { throw AgentExportPlanError.optionalLossApprovalRequired }
        let intent = try recordAuthorizedIntent(document: document, planID: planID, approvalID: approvalID,
            actorID: actorID, clientID: clientID, keyID: keyID, nonceID: nonceID,
            rootPath: rootPath, requestID: requestID, now: now)
        if intent.idempotentReplay {
            let state = try read(documentDigest: document.approvalDigest).entry.state
            return state == .applying ? .unknown : state
        }
        let outcome = writer()
        do {
            _ = try recordOutcome(documentDigest: document.approvalDigest, outcome: outcome, intent: intent.revision,
                actorID: actorID, requestID: requestID + "/outcome", now: now)
            return try read(documentDigest: document.approvalDigest).entry.state
        } catch {
            return .unknown
        }
    }

    func recordAuthorizedIntent(document: AgentExportDocument, planID: String, approvalID: String,
                                actorID: String, clientID: String, keyID: String, nonceID: String,
                                rootPath: String, requestID: String, now: Int64,
                                injectAuditFailure: Bool = false) throws -> TransitionResult {
        let binding = try document.approvalRequestBinding(planID: planID)
        let digest = hex(document.approvalDigest)
        let entry = Entry(schemaVersion: 1, documentDigest: digest, state: .applying)
        let data = try JSONEncoder().encode(entry)
        let enforcer = try AuthorizationEnforcer(store: store)
        return try enforcer.authorizeAndCommitExecution(AuthorizedExecutionInput(actorID: actorID, clientID: clientID,
            keyID: keyID, nonceID: nonceID, workspaceID: store.workspaceID, workspaceRootPath: rootPath,
            candidateTargetPath: document.plan.binding.targetPath, requiredScope: .workspaceWrite,
            operation: "config.intent", requestID: requestID, objectID: "arc04/apply/" + digest,
            expectedRevision: nil, preparedAttemptID: nil, requestDigest: digest, applyApprovalID: approvalID,
            expectedApplyBinding: binding, normalizedInput: .object([("documentDigest", .string(digest))]),
            nextStateJSON: String(decoding: data, as: UTF8.self), responseJSON: "{}", nowEpochSeconds: now,
            injectAuditFailure: injectAuditFailure))
    }

    func recordIntent(documentDigest: Data, actorID: String, requestID: String, now: Int64) throws -> TransitionResult {
        guard documentDigest.count == 32 else { throw StorageError.invalidInput }
        return try commit(Entry(schemaVersion: 1, documentDigest: hex(documentDigest), state: .applying),
            actorID: actorID, requestID: requestID, expected: nil, now: now)
    }

    func recordOutcome(documentDigest: Data, outcome: AgentConfigWriteOutcome, intent: RevisionRef,
                       actorID: String, requestID: String, now: Int64) throws -> TransitionResult {
        let prior = try read(documentDigest: documentDigest)
        guard prior.entry.state == .applying, prior.revision == intent else { throw StorageError.versionConflict }
        let state: AgentApplyJournalState
        switch outcome {
        case .applied: state = .applied
        case .conflict: state = .conflict
        case .unavailable: state = .unavailable
        case .partial: state = .partial
        case .unknown: state = .unknown
        }
        return try commit(Entry(schemaVersion: 1, documentDigest: hex(documentDigest), state: state),
            actorID: actorID, requestID: requestID, expected: intent, now: now)
    }

    func recover(documentDigest: Data, actorID: String, requestID: String, now: Int64) throws -> AgentApplyJournalState {
        let current = try read(documentDigest: documentDigest)
        guard current.entry.state == .applying else { return current.entry.state }
        _ = try recordOutcome(documentDigest: documentDigest, outcome: .unknown, intent: current.revision,
            actorID: actorID, requestID: requestID, now: now)
        return .unknown
    }

    private func read(documentDigest: Data) throws -> (entry: Entry, revision: RevisionRef) {
        guard documentDigest.count == 32 else { throw StorageError.invalidInput }
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: "arc04/apply/" + hex(documentDigest))
        guard snapshot.ownerModule == "ARC-04" || snapshot.ownerModule == "ARC-09" else { throw StorageError.corrupt("invalid apply owner") }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(snapshot.stateJSON.utf8))
        guard entry.schemaVersion == 1, entry.documentDigest == hex(documentDigest) else { throw StorageError.corrupt("invalid apply binding") }
        return (entry, snapshot.revision)
    }

    private func commit(_ entry: Entry, actorID: String, requestID: String, expected: RevisionRef?, now: Int64) throws -> TransitionResult {
        let data = try JSONEncoder().encode(entry)
        let value: RawJSONValue = .object([("domain", .string("oches.agent.apply-journal.v1")),
            ("documentDigest", .string(entry.documentDigest)), ("state", .string(entry.state.rawValue))])
        return try store.commitTransition(TransitionRequest(actorID: actorID, workspaceID: store.workspaceID,
            operation: expected == nil ? "config.intent" : "config.outcome", requestID: requestID,
            objectID: "arc04/apply/" + entry.documentDigest, ownerModule: "ARC-04", expectedRevision: expected,
            normalizedInput: value, nextStateJSON: String(decoding: data, as: UTF8.self),
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-04", kind: "config." + entry.state.rawValue,
                payloadJSON: "{}", observedAt: now)], responseJSON: "{}", nowEpochSeconds: now))
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
