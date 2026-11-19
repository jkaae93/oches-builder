import CryptoKit
import Foundation
import SQLite3

public enum MemoryLifecycleState: String, Sendable, Equatable, Codable {
    case candidate = "Candidate"
    case verified = "Verified"
    case rejected = "Rejected"
    case stale = "Stale"
    case invalid = "Invalid"
}

public enum MemoryError: Error, Equatable, Sendable {
    case invalidInput(String)
    case evidenceMissingOrDeleted(String)
    case illegalStateTransition(from: MemoryLifecycleState, to: MemoryLifecycleState)
    case dreamingUnsupportedV1
    case selectionStale(reasons: [String])
    case approvalRequired([ApprovalKind])
    case permissionDenied(String)
    case budgetInvalid
}

public struct MemoryEvidenceRef: Sendable, Equatable, Codable {
    public let evidenceID: String
    public let objectID: String
    public let revision: RevisionRef
    public let contentDigest: String
    public let requiredScope: PermissionScope
    public let originUntrusted: Bool

    public init(
        evidenceID: String,
        objectID: String,
        revision: RevisionRef,
        contentDigest: String,
        requiredScope: PermissionScope,
        originUntrusted: Bool = true
    ) {
        self.evidenceID = evidenceID
        self.objectID = objectID
        self.revision = revision
        self.contentDigest = contentDigest
        self.requiredScope = requiredScope
        self.originUntrusted = originUntrusted
    }
}

public struct EvidenceVerificationState: Sendable, Equatable {
    public let exists: Bool
    public let currentRevision: RevisionRef?
    public let currentDigest: String?
    public let revoked: Bool

    public init(
        exists: Bool,
        currentRevision: RevisionRef?,
        currentDigest: String?,
        revoked: Bool = false
    ) {
        self.exists = exists
        self.currentRevision = currentRevision
        self.currentDigest = currentDigest
        self.revoked = revoked
    }
}

public typealias EvidenceStatusResolver = (MemoryEvidenceRef) throws -> EvidenceVerificationState

public struct MemoryEntryRecord: Sendable, Equatable, Codable {
    public let memoryID: String
    public let workspaceID: String
    public let title: String
    public let keywords: [String]
    public let bodyMarkdown: String
    public let evidenceRefs: [MemoryEvidenceRef]
    public let state: MemoryLifecycleState
    public let policyVersion: UInt64
    public let createdAt: Int64
    public let verifiedAt: Int64?
    public let expiresAt: Int64?
    public let accessScope: PermissionScope
    public let invalidationReason: String?

    public init(
        memoryID: String,
        workspaceID: String,
        title: String,
        keywords: [String],
        bodyMarkdown: String,
        evidenceRefs: [MemoryEvidenceRef],
        state: MemoryLifecycleState,
        policyVersion: UInt64,
        createdAt: Int64,
        verifiedAt: Int64? = nil,
        expiresAt: Int64? = nil,
        accessScope: PermissionScope,
        invalidationReason: String? = nil
    ) {
        self.memoryID = memoryID
        self.workspaceID = workspaceID
        self.title = title
        self.keywords = keywords
        self.bodyMarkdown = bodyMarkdown
        self.evidenceRefs = evidenceRefs
        self.state = state
        self.policyVersion = policyVersion
        self.createdAt = createdAt
        self.verifiedAt = verifiedAt
        self.expiresAt = expiresAt
        self.accessScope = accessScope
        self.invalidationReason = invalidationReason
    }
}

public final class MemoryStore: @unchecked Sendable {
    /// Frozen E7 TTL: 90 days in seconds.
    public static let verifiedTTLSeconds: Int64 = 90 * 86_400

    private static let secretMarkers = [
        "sk-ant-",
        "bearer ",
        "begin private key",
        "cookie=",
    ]

    public let store: SQLiteStore
    private let deletionLifecycle: DeletionRequestLifecycle

    public init(store: SQLiteStore) throws {
        self.store = store
        self.deletionLifecycle = try DeletionRequestLifecycle(store: store)
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS memory_search_index (
                memory_object_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                memory_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                title TEXT NOT NULL,
                keywords_json TEXT NOT NULL,
                state TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS memory_evidence_links (
                workspace_id TEXT NOT NULL,
                memory_object_id TEXT NOT NULL,
                evidence_object_id TEXT NOT NULL,
                PRIMARY KEY (workspace_id, memory_object_id, evidence_object_id)
            );
            """
        )
    }

    public static func objectID(for memoryID: String) throws -> String {
        guard memoryID.utf8.count <= 128,
              memoryID.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil else {
            throw MemoryError.invalidInput("invalid memoryID")
        }
        return "arc08/memory/" + memoryID
    }

    public func proposeMemory(
        memoryID: String,
        title: String,
        keywords: [String],
        bodyMarkdown: String,
        evidenceRefs: [MemoryEvidenceRef],
        policyVersion: UInt64,
        accessScope: PermissionScope,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> (revision: RevisionRef, entry: MemoryEntryRecord) {
        let objID = try Self.objectID(for: memoryID)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              !trimmedBody.isEmpty,
              !evidenceRefs.isEmpty,
              now >= 0 else {
            throw MemoryError.invalidInput("memory requires non-empty title, body, and evidenceRefs")
        }
        guard !Self.containsSecretMarker(trimmedTitle),
              !Self.containsSecretMarker(trimmedBody),
              !keywords.contains(where: Self.containsSecretMarker) else {
            throw MemoryError.invalidInput("secret-like content rejected from memory store")
        }
        for ref in evidenceRefs {
            guard !ref.evidenceID.isEmpty,
                  !ref.objectID.isEmpty,
                  !ref.contentDigest.isEmpty else {
                throw MemoryError.invalidInput("invalid evidence reference")
            }
            if try isTargetDeleted(objID) || isTargetDeleted(ref.objectID) {
                throw MemoryError.evidenceMissingOrDeleted(ref.objectID)
            }
        }
        if try isTargetDeleted(objID) {
            throw MemoryError.evidenceMissingOrDeleted(objID)
        }

        let entry = MemoryEntryRecord(
            memoryID: memoryID,
            workspaceID: store.workspaceID,
            title: trimmedTitle,
            keywords: keywords,
            bodyMarkdown: trimmedBody,
            evidenceRefs: evidenceRefs,
            state: .candidate,
            policyVersion: policyVersion,
            createdAt: now,
            verifiedAt: nil,
            expiresAt: nil,
            accessScope: accessScope,
            invalidationReason: nil
        )
        let payloadJSON = try encodeJSON(entry)
        let request = TransitionRequest(
            actorID: actorID,
            workspaceID: store.workspaceID,
            operation: "memory.propose",
            requestID: requestID,
            objectID: objID,
            ownerModule: "ARC-08",
            expectedRevision: nil,
            normalizedInput: .object([
                ("memoryID", .string(memoryID)),
                ("title", .string(trimmedTitle)),
                ("policyVersion", .number(String(policyVersion))),
            ]),
            nextStateJSON: payloadJSON,
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-08", kind: "memory.propose", payloadJSON: "{}", observedAt: now)],
            responseJSON: payloadJSON,
            nowEpochSeconds: now
        )
        let result = try store.commitTransition(request)
        try syncDerivedIndex(objectID: objID, entry: entry)
        let decoded = try JSONDecoder().decode(MemoryEntryRecord.self, from: Data(result.responseJSON.utf8))
        return (result.revision, decoded)
    }

    public func validateMemory(
        memoryID: String,
        expectedRevision: RevisionRef,
        approve: Bool,
        evidenceResolver: EvidenceStatusResolver,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> (revision: RevisionRef, entry: MemoryEntryRecord) {
        let objID = try Self.objectID(for: memoryID)
        guard expectedRevision.objectID.utf8.elementsEqual(objID.utf8) else {
            throw StorageError.invalidInput
        }
        if try isTargetDeleted(objID) {
            throw StorageError.denied
        }

        let (currentRev, current) = try readCanonical(memoryID: memoryID)
        let nextEntry: MemoryEntryRecord
        if currentRev == expectedRevision {
            guard current.state == .candidate || current.state == .stale else {
                let target: MemoryLifecycleState = approve ? .verified : .rejected
                throw MemoryError.illegalStateTransition(from: current.state, to: target)
            }
            if approve {
                for ref in current.evidenceRefs {
                    if try isTargetDeleted(ref.objectID) {
                        throw MemoryError.evidenceMissingOrDeleted(ref.objectID)
                    }
                    let status = try evidenceResolver(ref)
                    guard status.exists,
                          !status.revoked,
                          status.currentRevision == ref.revision,
                          status.currentDigest == ref.contentDigest else {
                        throw MemoryError.evidenceMissingOrDeleted(ref.objectID)
                    }
                }
                nextEntry = MemoryEntryRecord(
                    memoryID: current.memoryID,
                    workspaceID: current.workspaceID,
                    title: current.title,
                    keywords: current.keywords,
                    bodyMarkdown: current.bodyMarkdown,
                    evidenceRefs: current.evidenceRefs,
                    state: .verified,
                    policyVersion: current.policyVersion,
                    createdAt: current.createdAt,
                    verifiedAt: now,
                    expiresAt: now + Self.verifiedTTLSeconds,
                    accessScope: current.accessScope,
                    invalidationReason: nil
                )
            } else {
                nextEntry = MemoryEntryRecord(
                    memoryID: current.memoryID,
                    workspaceID: current.workspaceID,
                    title: current.title,
                    keywords: current.keywords,
                    bodyMarkdown: current.bodyMarkdown,
                    evidenceRefs: current.evidenceRefs,
                    state: .rejected,
                    policyVersion: current.policyVersion,
                    createdAt: current.createdAt,
                    verifiedAt: nil,
                    expiresAt: nil,
                    accessScope: current.accessScope,
                    invalidationReason: "rejected during validation"
                )
            }
        } else {
            nextEntry = current
        }

        let payloadJSON = try encodeJSON(nextEntry)
        let request = TransitionRequest(
            actorID: actorID,
            workspaceID: store.workspaceID,
            operation: "memory.validate",
            requestID: requestID,
            objectID: objID,
            ownerModule: "ARC-08",
            expectedRevision: expectedRevision,
            normalizedInput: .object([
                ("memoryID", .string(memoryID)),
                ("approve", .bool(approve)),
            ]),
            nextStateJSON: payloadJSON,
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-08", kind: "memory.validate", payloadJSON: "{}", observedAt: now)],
            responseJSON: payloadJSON,
            nowEpochSeconds: now
        )
        let result = try store.commitTransition(request)
        if !result.idempotentReplay {
            try syncDerivedIndex(objectID: objID, entry: nextEntry)
        }
        let decoded = try JSONDecoder().decode(MemoryEntryRecord.self, from: Data(result.responseJSON.utf8))
        return (result.revision, decoded)
    }

    public func invalidate(
        memoryID: String,
        expectedRevision: RevisionRef,
        targetState: MemoryLifecycleState,
        reason: String,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> (revision: RevisionRef, entry: MemoryEntryRecord) {
        let objID = try Self.objectID(for: memoryID)
        guard expectedRevision.objectID.utf8.elementsEqual(objID.utf8),
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageError.invalidInput
        }
        if try isTargetDeleted(objID) {
            throw StorageError.denied
        }

        let (currentRev, current) = try readCanonical(memoryID: memoryID)
        let nextEntry: MemoryEntryRecord
        if currentRev == expectedRevision {
            let validTransition: Bool
            switch (current.state, targetState) {
            case (.verified, .stale), (.verified, .invalid), (.stale, .invalid):
                validTransition = true
            default:
                validTransition = false
            }
            guard validTransition else {
                throw MemoryError.illegalStateTransition(from: current.state, to: targetState)
            }
            nextEntry = MemoryEntryRecord(
                memoryID: current.memoryID,
                workspaceID: current.workspaceID,
                title: current.title,
                keywords: current.keywords,
                bodyMarkdown: current.bodyMarkdown,
                evidenceRefs: current.evidenceRefs,
                state: targetState,
                policyVersion: current.policyVersion,
                createdAt: current.createdAt,
                verifiedAt: current.verifiedAt,
                expiresAt: current.expiresAt,
                accessScope: current.accessScope,
                invalidationReason: reason
            )
        } else {
            nextEntry = current
        }

        let payloadJSON = try encodeJSON(nextEntry)
        let request = TransitionRequest(
            actorID: actorID,
            workspaceID: store.workspaceID,
            operation: "memory.invalidate",
            requestID: requestID,
            objectID: objID,
            ownerModule: "ARC-08",
            expectedRevision: expectedRevision,
            normalizedInput: .object([
                ("memoryID", .string(memoryID)),
                ("targetState", .string(targetState.rawValue)),
                ("reason", .string(reason)),
            ]),
            nextStateJSON: payloadJSON,
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-08", kind: "memory.invalidate", payloadJSON: "{}", observedAt: now)],
            responseJSON: payloadJSON,
            nowEpochSeconds: now
        )
        let result = try store.commitTransition(request)
        if !result.idempotentReplay {
            try syncDerivedIndex(objectID: objID, entry: nextEntry)
        }
        let decoded = try JSONDecoder().decode(MemoryEntryRecord.self, from: Data(result.responseJSON.utf8))
        return (result.revision, decoded)
    }

    public func readCanonical(memoryID: String) throws -> (revision: RevisionRef, entry: MemoryEntryRecord) {
        let objID = try Self.objectID(for: memoryID)
        if try isTargetDeleted(objID) {
            throw StorageError.denied
        }
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: objID)
        guard snapshot.ownerModule == "ARC-08" else {
            throw StorageError.corrupt("invalid memory owner")
        }
        let entry = try JSONDecoder().decode(MemoryEntryRecord.self, from: Data(snapshot.stateJSON.utf8))
        return (snapshot.revision, entry)
    }

    public func listAllCanonicalEntries() throws -> [(revision: RevisionRef, entry: MemoryEntryRecord)] {
        let objectIDs: [String] = try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                "SELECT object_id FROM operational_state WHERE workspace_id = ? AND owner_module = 'ARC-08' AND substr(object_id, 1, 13) = 'arc08/memory/' ORDER BY object_id ASC"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: store.workspaceID)
            var ids: [String] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw store.mapSQLiteError(rc) }
                ids.append(store.columnText(stmt, index: 0))
            }
            return ids
        }

        var result: [(RevisionRef, MemoryEntryRecord)] = []
        for objID in objectIDs {
            if try isTargetDeleted(objID) {
                continue
            }
            let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: objID)
            let entry = try JSONDecoder().decode(MemoryEntryRecord.self, from: Data(snapshot.stateJSON.utf8))
            result.append((snapshot.revision, entry))
        }
        return result
    }

    public func searchDerivedIndex(keywords: [String]) throws -> [String] {
        let loweredKeywords = keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        return try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                "SELECT memory_id, title, keywords_json FROM memory_search_index WHERE workspace_id = ? ORDER BY memory_id ASC"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: store.workspaceID)
            var matched: [String] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw store.mapSQLiteError(rc) }
                let memoryID = store.columnText(stmt, index: 0)
                let title = store.columnText(stmt, index: 1).lowercased()
                let entryKeywords = (try? JSONDecoder().decode([String].self, from: Data(store.columnText(stmt, index: 2).utf8))) ?? []
                let lowerEntryKeywords = entryKeywords.map { $0.lowercased() }
                if loweredKeywords.isEmpty
                    || loweredKeywords.contains(where: { kw in
                        title.contains(kw) || lowerEntryKeywords.contains(where: { $0.contains(kw) })
                    }) {
                    matched.append(memoryID)
                }
            }
            return matched
        }
    }

    @discardableResult
    public func rebuildDerivedIndex() throws -> Int {
        let canonical = try listAllCanonicalEntries()
        var validEntries: [(objectID: String, entry: MemoryEntryRecord)] = []
        for (_, entry) in canonical {
            let objID = try Self.objectID(for: entry.memoryID)
            guard !entry.evidenceRefs.isEmpty else { continue }
            var anyEvidenceDeleted = false
            for ref in entry.evidenceRefs {
                if try isTargetDeleted(ref.objectID) {
                    anyEvidenceDeleted = true
                    break
                }
            }
            if !anyEvidenceDeleted {
                validEntries.append((objID, entry))
            }
        }

        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let clearIndex = try store.prepare("DELETE FROM memory_search_index WHERE workspace_id = ?")
                defer { sqlite3_finalize(clearIndex) }
                try store.bindText(clearIndex, index: 1, value: store.workspaceID)
                guard sqlite3_step(clearIndex) == SQLITE_DONE else {
                    throw StorageError.unavailable("clear memory_search_index failed")
                }

                let clearLinks = try store.prepare("DELETE FROM memory_evidence_links WHERE workspace_id = ?")
                defer { sqlite3_finalize(clearLinks) }
                try store.bindText(clearLinks, index: 1, value: store.workspaceID)
                guard sqlite3_step(clearLinks) == SQLITE_DONE else {
                    throw StorageError.unavailable("clear memory_evidence_links failed")
                }

                for item in validEntries {
                    try upsertDerivedIndexInTx(objectID: item.objectID, entry: item.entry)
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
        return validEntries.count
    }

    public static func renderMarkdownWithFrontmatter(_ entry: MemoryEntryRecord) -> String {
        func yamlQuote(_ s: String) -> String {
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        let evidenceList = entry.evidenceRefs.map { yamlQuote($0.evidenceID) }.joined(separator: ", ")
        let verifiedStr = entry.verifiedAt.map(String.init) ?? "null"
        let expiresStr = entry.expiresAt.map(String.init) ?? "null"
        return """
        ---
        memory_id: \(yamlQuote(entry.memoryID))
        state: \(yamlQuote(entry.state.rawValue))
        policy_version: \(entry.policyVersion)
        verified_at: \(verifiedStr)
        expires_at: \(expiresStr)
        evidence_ids: [\(evidenceList)]
        ---
        # \(entry.title)

        \(entry.bodyMarkdown)
        """
    }

    public func requestDreaming(actorID: String) throws -> Never {
        _ = actorID
        throw MemoryError.dreamingUnsupportedV1
    }

    func isTargetDeleted(_ targetID: String) throws -> Bool {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                "SELECT 1 FROM deletion_requests WHERE workspace_id = ? AND target_id = ? LIMIT 1"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: store.workspaceID)
            try store.bindText(stmt, index: 2, value: targetID)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { return true }
            if rc == SQLITE_DONE { return false }
            throw store.mapSQLiteError(rc)
        }
    }

    private func syncDerivedIndex(objectID: String, entry: MemoryEntryRecord) throws {
        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                try upsertDerivedIndexInTx(objectID: objectID, entry: entry)
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    private func upsertDerivedIndexInTx(objectID: String, entry: MemoryEntryRecord) throws {
        let keywordsJSON = try encodeJSON(entry.keywords)
        let idxStmt = try store.prepare(
            """
            INSERT OR REPLACE INTO memory_search_index (
                memory_object_id, workspace_id, memory_id, target_id, title, keywords_json, state
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(idxStmt) }
        try store.bindText(idxStmt, index: 1, value: objectID)
        try store.bindText(idxStmt, index: 2, value: store.workspaceID)
        try store.bindText(idxStmt, index: 3, value: entry.memoryID)
        try store.bindText(idxStmt, index: 4, value: objectID)
        try store.bindText(idxStmt, index: 5, value: entry.title)
        try store.bindText(idxStmt, index: 6, value: keywordsJSON)
        try store.bindText(idxStmt, index: 7, value: entry.state.rawValue)
        guard sqlite3_step(idxStmt) == SQLITE_DONE else {
            throw StorageError.unavailable("upsert memory_search_index failed")
        }

        let delOldLinks = try store.prepare(
            "DELETE FROM memory_evidence_links WHERE workspace_id = ? AND memory_object_id = ?"
        )
        defer { sqlite3_finalize(delOldLinks) }
        try store.bindText(delOldLinks, index: 1, value: store.workspaceID)
        try store.bindText(delOldLinks, index: 2, value: objectID)
        guard sqlite3_step(delOldLinks) == SQLITE_DONE else {
            throw StorageError.unavailable("clear old evidence links failed")
        }

        for ref in entry.evidenceRefs {
            let linkStmt = try store.prepare(
                "INSERT OR IGNORE INTO memory_evidence_links (workspace_id, memory_object_id, evidence_object_id) VALUES (?, ?, ?)"
            )
            defer { sqlite3_finalize(linkStmt) }
            try store.bindText(linkStmt, index: 1, value: store.workspaceID)
            try store.bindText(linkStmt, index: 2, value: objectID)
            try store.bindText(linkStmt, index: 3, value: ref.objectID)
            guard sqlite3_step(linkStmt) == SQLITE_DONE else {
                throw StorageError.unavailable("insert memory_evidence_links failed")
            }
        }
    }

    private func encodeJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func containsSecretMarker(_ text: String) -> Bool {
        let lower = text.lowercased()
        return secretMarkers.contains { lower.contains($0) }
    }
}
