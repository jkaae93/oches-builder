import Foundation
import SQLite3

public struct AuthorizedExecutionInput: @unchecked Sendable {
    public let actorID: String
    public let clientID: String
    public let keyID: String
    public let nonceID: String
    public let workspaceID: String
    public let workspaceRootPath: String
    public let candidateTargetPath: String
    public let requiredScope: PermissionScope
    public let operation: String
    public let requestID: String
    public let objectID: String
    public let expectedRevision: RevisionRef?
    public let preparedAttemptID: String?
    public let requestDigest: String
    public let executionApprovalID: String?
    public let transferApprovalID: String?
    public let requiresExternalTransfer: Bool
    public let applyApprovalID: String?
    public let normalizedInput: RawJSONValue
    public let nextStateJSON: String
    public let responseJSON: String
    public let nowEpochSeconds: Int64
    public let injectAuditFailure: Bool

    public init(
        actorID: String,
        clientID: String,
        keyID: String,
        nonceID: String,
        workspaceID: String,
        workspaceRootPath: String,
        candidateTargetPath: String,
        requiredScope: PermissionScope,
        operation: String,
        requestID: String,
        objectID: String,
        expectedRevision: RevisionRef?,
        preparedAttemptID: String?,
        requestDigest: String,
        executionApprovalID: String? = nil,
        transferApprovalID: String? = nil,
        requiresExternalTransfer: Bool = false,
        applyApprovalID: String? = nil,
        normalizedInput: RawJSONValue,
        nextStateJSON: String,
        responseJSON: String,
        nowEpochSeconds: Int64,
        injectAuditFailure: Bool = false
    ) {
        self.actorID = actorID
        self.clientID = clientID
        self.keyID = keyID
        self.nonceID = nonceID
        self.workspaceID = workspaceID
        self.workspaceRootPath = workspaceRootPath
        self.candidateTargetPath = candidateTargetPath
        self.requiredScope = requiredScope
        self.operation = operation
        self.requestID = requestID
        self.objectID = objectID
        self.expectedRevision = expectedRevision
        self.preparedAttemptID = preparedAttemptID
        self.requestDigest = requestDigest
        self.executionApprovalID = executionApprovalID
        self.transferApprovalID = transferApprovalID
        self.requiresExternalTransfer = requiresExternalTransfer
        self.applyApprovalID = applyApprovalID
        self.normalizedInput = normalizedInput
        self.nextStateJSON = nextStateJSON
        self.responseJSON = responseJSON
        self.nowEpochSeconds = nowEpochSeconds
        self.injectAuditFailure = injectAuditFailure
    }
}

public struct AuditLogEntry: Sendable, Equatable {
    public let auditID: Int64
    public let workspaceID: String
    public let actorID: String
    public let clientID: String
    public let operation: String
    public let requestID: String
    public let decision: String
    public let detail: String
    public let recordedAt: Int64
}

public final class AuthorizationEnforcer: @unchecked Sendable {
    public let store: SQLiteStore

    public init(store: SQLiteStore) throws {
        self.store = store
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS approvals (
                approval_id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                subject_client_id TEXT NOT NULL,
                decided_by_actor_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                normalized_target TEXT NOT NULL,
                allowed_scopes_json TEXT NOT NULL,
                binding_json TEXT NOT NULL,
                policy_version INTEGER NOT NULL,
                issued_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                status TEXT NOT NULL,
                consumed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS auth_nonces (
                nonce_id TEXT PRIMARY KEY,
                client_id TEXT NOT NULL,
                key_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                purpose TEXT NOT NULL,
                expires_at INTEGER NOT NULL,
                consumed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS audit_log (
                audit_id INTEGER PRIMARY KEY AUTOINCREMENT,
                workspace_id TEXT NOT NULL,
                actor_id TEXT NOT NULL,
                client_id TEXT NOT NULL,
                operation TEXT NOT NULL,
                request_id TEXT NOT NULL,
                decision TEXT NOT NULL,
                detail TEXT NOT NULL,
                recorded_at INTEGER NOT NULL
            );
            """
        )
    }

    public static func canonicalPathWithinRoot(candidatePath: String, rootPath: String) -> String? {
        let rootURL = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL
        let candidateURL = URL(fileURLWithPath: candidatePath).resolvingSymlinksInPath().standardizedFileURL
        let rootStr = rootURL.path
        let candStr = candidateURL.path
        if candStr == rootStr || candStr.hasPrefix(rootStr + "/") {
            return candStr
        }
        return nil
    }

    public func issueNonce(
        nonceID: String,
        clientID: String,
        keyID: String,
        workspaceID: String,
        purpose: String,
        expiresAt: Int64
    ) throws {
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    "INSERT INTO auth_nonces (nonce_id, client_id, key_id, workspace_id, purpose, expires_at, consumed) VALUES (?, ?, ?, ?, ?, ?, 0)"
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: nonceID)
                try store.bindText(stmt, index: 2, value: clientID)
                try store.bindText(stmt, index: 3, value: keyID)
                try store.bindText(stmt, index: 4, value: workspaceID)
                try store.bindText(stmt, index: 5, value: purpose)
                sqlite3_bind_int64(stmt, 6, expiresAt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw AuthorizationError.unavailable("failed to issue nonce")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func recordApproval(_ approval: ApprovalRecord, decidedByTrustedUI: Bool) throws {
        guard decidedByTrustedUI else {
            throw AuthorizationError.denied("only trusted Desktop UI can issue approvals")
        }
        guard approval.isStructurallyValid() else {
            throw AuthorizationError.invalidInput("invalid approval binding or timestamps")
        }
        let scopesData = try JSONEncoder().encode(approval.allowedScopes)
        let bindingData = try JSONEncoder().encode(approval.binding)
        let scopesJSON = String(decoding: scopesData, as: UTF8.self)
        let bindingJSON = String(decoding: bindingData, as: UTF8.self)

        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT OR REPLACE INTO approvals (
                        approval_id, kind, subject_client_id, decided_by_actor_id, workspace_id,
                        normalized_target, allowed_scopes_json, binding_json, policy_version,
                        issued_at, expires_at, status, consumed
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: approval.approvalID)
                try store.bindText(stmt, index: 2, value: approval.kind.rawValue)
                try store.bindText(stmt, index: 3, value: approval.subjectClientID)
                try store.bindText(stmt, index: 4, value: approval.decidedByActorID)
                try store.bindText(stmt, index: 5, value: approval.workspaceID)
                try store.bindText(stmt, index: 6, value: approval.normalizedTarget)
                try store.bindText(stmt, index: 7, value: scopesJSON)
                try store.bindText(stmt, index: 8, value: bindingJSON)
                sqlite3_bind_int64(stmt, 9, Int64(bitPattern: approval.policyVersion))
                sqlite3_bind_int64(stmt, 10, approval.issuedAt)
                sqlite3_bind_int64(stmt, 11, approval.expiresAt)
                try store.bindText(stmt, index: 12, value: approval.status.rawValue)
                sqlite3_bind_int(stmt, 13, approval.consumed ? 1 : 0)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw AuthorizationError.unavailable("failed to store approval")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func revokeApproval(approvalID: String, nowEpochSeconds: Int64) throws {
        try store.withConnectionLock { _ in
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare("UPDATE approvals SET status = ? WHERE approval_id = ?")
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: ApprovalStatus.revoked.rawValue)
                try store.bindText(stmt, index: 2, value: approvalID)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw AuthorizationError.unavailable("failed to revoke approval")
                }
                let audit = try store.prepare(
                    "INSERT INTO audit_log (workspace_id, actor_id, client_id, operation, request_id, decision, detail, recorded_at) VALUES ('*', 'system', 'desktop', 'approval.revoke', ?, 'REVOKED', ?, ?)"
                )
                defer { sqlite3_finalize(audit) }
                try store.bindText(audit, index: 1, value: approvalID)
                try store.bindText(audit, index: 2, value: "approval revoked")
                sqlite3_bind_int64(audit, 3, nowEpochSeconds)
                guard sqlite3_step(audit) == SQLITE_DONE else {
                    throw AuthorizationError.unavailable("audit write failed during revocation")
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Revalidates client status, policy version, workspace, symlink-resolved canonical path,
    /// approvals (execution + optional external transfer + apply), single-use nonce, and writes
    /// state + audit log atomically inside SQLite `BEGIN IMMEDIATE`.
    public func authorizeAndCommitExecution(_ input: AuthorizedExecutionInput) throws -> TransitionResult {
        guard let canonicalTarget = Self.canonicalPathWithinRoot(
            candidatePath: input.candidateTargetPath,
            rootPath: input.workspaceRootPath
        ) else {
            throw AuthorizationError.denied("target escapes workspace root or invalid symlink")
        }

        let inputDigestData = try canonicalSHA256(.object([
            ("operation", .string(input.operation)),
            ("objectId", .string(input.objectID)),
            ("expectedRevision", input.expectedRevision.map {
                .object([
                    ("objectId", .string($0.objectID)),
                    ("storeGeneration", .string($0.storeGeneration)),
                    ("revision", .string($0.revision)),
                ])
            } ?? .null),
            ("normalizedInput", input.normalizedInput),
        ]))
        let idempotencyDigest = inputDigestData.map { String(format: "%02x", $0) }.joined()

        return try store.withConnectionLock { db in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                // 1. Verify active client & workspace scope & policy version
                let clientInfo = try queryClientAuthRow(clientID: input.clientID)
                guard clientInfo.status == ClientRegistrationStatus.active.rawValue,
                      clientInfo.signingKeyID == input.keyID,
                      input.nowEpochSeconds < clientInfo.expiresAt,
                      clientInfo.workspaces.contains(input.workspaceID),
                      clientInfo.scopes.contains(input.requiredScope.rawValue) else {
                    throw AuthorizationError.denied("client inactive, key mismatch, or missing scope/workspace")
                }

                // 2. Atomically consume single-use nonce
                try consumeNonceInTx(
                    db: db,
                    nonceID: input.nonceID,
                    clientID: input.clientID,
                    keyID: input.keyID,
                    workspaceID: input.workspaceID,
                    nowEpochSeconds: input.nowEpochSeconds
                )

                // 3. Check idempotency record first (if exists & valid, return without re-consuming approvals)
                if let existing = try queryExistingIdempotency(
                    actorID: input.actorID,
                    workspaceID: input.workspaceID,
                    operation: input.operation,
                    requestID: input.requestID
                ) {
                    if existing.tombstoned || input.nowEpochSeconds >= existing.expiresAt {
                        throw AuthorizationError.conflict("idempotency expired")
                    }
                    if existing.inputDigest != idempotencyDigest {
                        throw AuthorizationError.conflict("idempotency input mismatch")
                    }
                    try insertAuditInTx(
                        workspaceID: input.workspaceID,
                        actorID: input.actorID,
                        clientID: input.clientID,
                        operation: input.operation,
                        requestID: input.requestID,
                        decision: "IDEMPOTENT_REPLAY",
                        detail: "replayed existing result",
                        nowEpochSeconds: input.nowEpochSeconds,
                        injectFailure: input.injectAuditFailure
                    )
                    let gen = try queryStoreGenInTx()
                    try store.execute("COMMIT")
                    return TransitionResult(
                        revision: RevisionRef(objectID: input.objectID, storeGeneration: gen, revision: String(existing.resultRevision ?? 0)),
                        eventCursor: EventCursor(workspaceID: input.workspaceID, storeGeneration: gen, sequence: existing.resultCursor ?? 0),
                        responseJSON: existing.responseJSON ?? "{}",
                        idempotentReplay: true
                    )
                }

                // 4. Revalidate & consume approvals depending on required operation
                if let applyID = input.applyApprovalID {
                    try revalidateAndConsumeApprovalInTx(
                        db: db,
                        approvalID: applyID,
                        expectedKind: .configExportApply,
                        input: input,
                        canonicalTarget: canonicalTarget,
                        clientPolicyVersion: clientInfo.policyVersion
                    )
                } else {
                    guard let execApprovalID = input.executionApprovalID else {
                        throw AuthorizationError.approvalRequired([.execution])
                    }
                    try revalidateAndConsumeApprovalInTx(
                        db: db,
                        approvalID: execApprovalID,
                        expectedKind: .execution,
                        input: input,
                        canonicalTarget: canonicalTarget,
                        clientPolicyVersion: clientInfo.policyVersion
                    )
                    if input.requiresExternalTransfer {
                        guard let transferID = input.transferApprovalID else {
                            throw AuthorizationError.approvalRequired([.externalTransfer])
                        }
                        try revalidateAndConsumeApprovalInTx(
                            db: db,
                            approvalID: transferID,
                            expectedKind: .externalTransfer,
                            input: input,
                            canonicalTarget: canonicalTarget,
                            clientPolicyVersion: clientInfo.policyVersion
                        )
                    }
                }

                // 5. Perform state transition & idempotency insert inside the same tx
                let currentGen = try queryStoreGenInTx()
                let currentStateRev = try queryCurrentRevisionInTx(workspaceID: input.workspaceID, objectID: input.objectID)
                let newRev: UInt64
                if let expected = input.expectedRevision {
                    guard expected.objectID == input.objectID else {
                        throw AuthorizationError.invalidInput("objectID mismatch")
                    }
                    guard expected.storeGeneration == currentGen else {
                        throw AuthorizationError.stale("STALE_GENERATION")
                    }
                    guard let expNum = UInt64(expected.revision), let curNum = currentStateRev, curNum == expNum else {
                        throw AuthorizationError.conflict("revision mismatch")
                    }
                    newRev = expNum + 1
                } else {
                    guard currentStateRev == nil else {
                        throw AuthorizationError.conflict("state already exists")
                    }
                    newRev = 1
                }

                if currentStateRev != nil {
                    let upd = try store.prepare(
                        "UPDATE operational_state SET revision = ?, state_json = ?, updated_at = ? WHERE workspace_id = ? AND object_id = ?"
                    )
                    defer { sqlite3_finalize(upd) }
                    sqlite3_bind_int64(upd, 1, Int64(bitPattern: newRev))
                    try store.bindText(upd, index: 2, value: input.nextStateJSON)
                    sqlite3_bind_int64(upd, 3, input.nowEpochSeconds)
                    try store.bindText(upd, index: 4, value: input.workspaceID)
                    try store.bindText(upd, index: 5, value: input.objectID)
                    guard sqlite3_step(upd) == SQLITE_DONE else { throw AuthorizationError.unavailable("state update failed") }
                } else {
                    let ins = try store.prepare(
                        "INSERT INTO operational_state (object_id, workspace_id, owner_module, revision, state_json, updated_at) VALUES (?, ?, 'ARC-09', ?, ?, ?)"
                    )
                    defer { sqlite3_finalize(ins) }
                    try store.bindText(ins, index: 1, value: input.objectID)
                    try store.bindText(ins, index: 2, value: input.workspaceID)
                    sqlite3_bind_int64(ins, 3, Int64(bitPattern: newRev))
                    try store.bindText(ins, index: 4, value: input.nextStateJSON)
                    sqlite3_bind_int64(ins, 5, input.nowEpochSeconds)
                    guard sqlite3_step(ins) == SQLITE_DONE else { throw AuthorizationError.unavailable("state insert failed") }
                }

                let evtStmt = try store.prepare(
                    "INSERT INTO event_log (event_id, workspace_id, store_generation, object_id, source_id, kind, payload_json, observed_at) VALUES (?, ?, ?, ?, 'authz', 'authorized.execution', '{}', ?)"
                )
                defer { sqlite3_finalize(evtStmt) }
                try store.bindText(evtStmt, index: 1, value: "evt-\(input.requestID)")
                try store.bindText(evtStmt, index: 2, value: input.workspaceID)
                try store.bindText(evtStmt, index: 3, value: currentGen)
                try store.bindText(evtStmt, index: 4, value: input.objectID)
                sqlite3_bind_int64(evtStmt, 5, input.nowEpochSeconds)
                guard sqlite3_step(evtStmt) == SQLITE_DONE else { throw AuthorizationError.unavailable("event insert failed") }

                let cursorSeq = try queryMaxSeqInTx(workspaceID: input.workspaceID)
                let expiresAt = input.nowEpochSeconds + TransitionRequest.defaultRetentionSeconds
                let idemp = try store.prepare(
                    """
                    INSERT INTO idempotency_records (
                        actor_id, workspace_id, operation, request_id, input_digest,
                        response_json, result_revision, result_cursor, created_at, expires_at, tombstoned
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                    """
                )
                defer { sqlite3_finalize(idemp) }
                try store.bindText(idemp, index: 1, value: input.actorID)
                try store.bindText(idemp, index: 2, value: input.workspaceID)
                try store.bindText(idemp, index: 3, value: input.operation)
                try store.bindText(idemp, index: 4, value: input.requestID)
                try store.bindText(idemp, index: 5, value: idempotencyDigest)
                try store.bindText(idemp, index: 6, value: input.responseJSON)
                sqlite3_bind_int64(idemp, 7, Int64(bitPattern: newRev))
                sqlite3_bind_int64(idemp, 8, Int64(bitPattern: cursorSeq))
                sqlite3_bind_int64(idemp, 9, input.nowEpochSeconds)
                sqlite3_bind_int64(idemp, 10, expiresAt)
                guard sqlite3_step(idemp) == SQLITE_DONE else { throw AuthorizationError.unavailable("idempotency insert failed") }

                // 6. Mandatory audit log insertion (failure rolls back everything)
                try insertAuditInTx(
                    workspaceID: input.workspaceID,
                    actorID: input.actorID,
                    clientID: input.clientID,
                    operation: input.operation,
                    requestID: input.requestID,
                    decision: "ALLOW",
                    detail: "authorized and committed",
                    nowEpochSeconds: input.nowEpochSeconds,
                    injectFailure: input.injectAuditFailure
                )

                try store.execute("COMMIT")
                return TransitionResult(
                    revision: RevisionRef(objectID: input.objectID, storeGeneration: currentGen, revision: String(newRev)),
                    eventCursor: EventCursor(workspaceID: input.workspaceID, storeGeneration: currentGen, sequence: cursorSeq),
                    responseJSON: input.responseJSON,
                    idempotentReplay: false
                )
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func retryRetrieveResultWithFreshNonce(
        actorID: String,
        clientID: String,
        keyID: String,
        freshNonceID: String,
        workspaceID: String,
        operation: String,
        requestID: String,
        nowEpochSeconds: Int64
    ) throws -> TransitionResult {
        try store.withConnectionLock { db in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let clientInfo = try queryClientAuthRow(clientID: clientID)
                guard clientInfo.status == ClientRegistrationStatus.active.rawValue,
                      clientInfo.signingKeyID == keyID,
                      nowEpochSeconds < clientInfo.expiresAt,
                      clientInfo.workspaces.contains(workspaceID),
                      clientInfo.scopes.contains(PermissionScope.workspaceRead.rawValue) else {
                    throw AuthorizationError.denied("client lacks active read permission")
                }

                // Consume the fresh single-use nonce before exposing cached result
                try consumeNonceInTx(
                    db: db,
                    nonceID: freshNonceID,
                    clientID: clientID,
                    keyID: keyID,
                    workspaceID: workspaceID,
                    nowEpochSeconds: nowEpochSeconds
                )

                guard let existing = try queryExistingIdempotency(
                    actorID: actorID,
                    workspaceID: workspaceID,
                    operation: operation,
                    requestID: requestID
                ) else {
                    throw AuthorizationError.invalidInput("no previous request recorded")
                }
                guard !existing.tombstoned && nowEpochSeconds < existing.expiresAt else {
                    throw AuthorizationError.conflict("idempotency expired")
                }

                try insertAuditInTx(
                    workspaceID: workspaceID,
                    actorID: actorID,
                    clientID: clientID,
                    operation: operation,
                    requestID: requestID,
                    decision: "RETRY_READ",
                    detail: "fresh nonce result retrieval",
                    nowEpochSeconds: nowEpochSeconds,
                    injectFailure: false
                )

                let gen = try queryStoreGenInTx()
                try store.execute("COMMIT")
                return TransitionResult(
                    revision: RevisionRef(objectID: requestID, storeGeneration: gen, revision: String(existing.resultRevision ?? 0)),
                    eventCursor: EventCursor(workspaceID: workspaceID, storeGeneration: gen, sequence: existing.resultCursor ?? 0),
                    responseJSON: existing.responseJSON ?? "{}",
                    idempotentReplay: true
                )
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func listAuditLogs(workspaceID: String) throws -> [AuditLogEntry] {
        try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                "SELECT audit_id, workspace_id, actor_id, client_id, operation, request_id, decision, detail, recorded_at FROM audit_log WHERE workspace_id = ? ORDER BY audit_id ASC"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: workspaceID)
            var entries: [AuditLogEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                entries.append(AuditLogEntry(
                    auditID: sqlite3_column_int64(stmt, 0),
                    workspaceID: store.columnText(stmt, index: 1),
                    actorID: store.columnText(stmt, index: 2),
                    clientID: store.columnText(stmt, index: 3),
                    operation: store.columnText(stmt, index: 4),
                    requestID: store.columnText(stmt, index: 5),
                    decision: store.columnText(stmt, index: 6),
                    detail: store.columnText(stmt, index: 7),
                    recordedAt: sqlite3_column_int64(stmt, 8)
                ))
            }
            return entries
        }
    }

    // MARK: - Private Tx Helpers

    private func consumeNonceInTx(
        db: OpaquePointer,
        nonceID: String,
        clientID: String,
        keyID: String,
        workspaceID: String,
        nowEpochSeconds: Int64
    ) throws {
        let stmt = try store.prepare(
            "SELECT client_id, key_id, workspace_id, expires_at, consumed FROM auth_nonces WHERE nonce_id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: nonceID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw AuthorizationError.denied("unknown nonce")
        }
        let nClient = store.columnText(stmt, index: 0)
        let nKey = store.columnText(stmt, index: 1)
        let nWS = store.columnText(stmt, index: 2)
        let expiresAt = sqlite3_column_int64(stmt, 3)
        let consumed = sqlite3_column_int(stmt, 4)

        guard nClient == clientID, nKey == keyID, nWS == workspaceID else {
            throw AuthorizationError.denied("nonce binding mismatch")
        }
        guard consumed == 0, nowEpochSeconds < expiresAt else {
            throw AuthorizationError.denied("nonce replayed or expired")
        }
        let upd = try store.prepare("UPDATE auth_nonces SET consumed = 1 WHERE nonce_id = ? AND consumed = 0")
        defer { sqlite3_finalize(upd) }
        try store.bindText(upd, index: 1, value: nonceID)
        guard sqlite3_step(upd) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw AuthorizationError.denied("concurrent nonce consumption race")
        }
    }

    private func revalidateAndConsumeApprovalInTx(
        db: OpaquePointer,
        approvalID: String,
        expectedKind: ApprovalKind,
        input: AuthorizedExecutionInput,
        canonicalTarget: String,
        clientPolicyVersion: UInt64
    ) throws {
        let stmt = try store.prepare(
            """
            SELECT kind, subject_client_id, workspace_id, normalized_target, allowed_scopes_json,
                   binding_json, policy_version, issued_at, expires_at, status, consumed
            FROM approvals WHERE approval_id = ?
            """
        )
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: approvalID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw AuthorizationError.approvalRequired([expectedKind])
        }

        let kindStr = store.columnText(stmt, index: 0)
        let subject = store.columnText(stmt, index: 1)
        let ws = store.columnText(stmt, index: 2)
        let normTarget = store.columnText(stmt, index: 3)
        let scopesJSON = store.columnText(stmt, index: 4)
        let bindingJSON = store.columnText(stmt, index: 5)
        let policyVer = UInt64(bitPattern: sqlite3_column_int64(stmt, 6))
        let issuedAt = sqlite3_column_int64(stmt, 7)
        let expiresAt = sqlite3_column_int64(stmt, 8)
        let status = store.columnText(stmt, index: 9)
        let consumed = sqlite3_column_int(stmt, 10)

        guard kindStr == expectedKind.rawValue else {
            throw AuthorizationError.denied("approval kind mismatch")
        }
        guard subject == input.clientID, ws == input.workspaceID else {
            throw AuthorizationError.denied("approval subject or workspace mismatch")
        }
        guard status == ApprovalStatus.approved.rawValue, consumed == 0 else {
            throw AuthorizationError.denied("approval not approved or already consumed")
        }
        guard issuedAt < expiresAt, input.nowEpochSeconds >= issuedAt, input.nowEpochSeconds < expiresAt else {
            throw AuthorizationError.denied("approval expired or invalid timestamp")
        }
        guard policyVer == clientPolicyVersion else {
            throw AuthorizationError.stale("approval policy version stale")
        }
        guard normTarget == canonicalTarget else {
            throw AuthorizationError.conflict("target path changed after approval")
        }

        let scopes = (try? JSONDecoder().decode([PermissionScope].self, from: Data(scopesJSON.utf8))) ?? []
        guard scopes.contains(input.requiredScope) else {
            throw AuthorizationError.denied("approval scope mismatch")
        }
        guard let binding = try? JSONDecoder().decode(ApprovalBinding.self, from: Data(bindingJSON.utf8)),
              binding.isValid(for: expectedKind) else {
            throw AuthorizationError.invalidInput("invalid approval binding")
        }

        if expectedKind == .execution {
            guard let attemptID = input.preparedAttemptID, binding.preparedAttemptID == attemptID else {
                throw AuthorizationError.denied("execution approval bound to different attemptId")
            }
            guard binding.executionRequestDigest == input.requestDigest else {
                throw AuthorizationError.conflict("execution request digest mismatch")
            }
            if let expRev = input.expectedRevision, binding.taskRevision != expRev {
                throw AuthorizationError.conflict("task revision changed after approval")
            }
        }

        let consumeStmt = try store.prepare("UPDATE approvals SET consumed = 1 WHERE approval_id = ? AND consumed = 0 AND status = 'APPROVED'")
        defer { sqlite3_finalize(consumeStmt) }
        try store.bindText(consumeStmt, index: 1, value: approvalID)
        guard sqlite3_step(consumeStmt) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw AuthorizationError.conflict("concurrent approval consumption")
        }
    }

    private func insertAuditInTx(
        workspaceID: String,
        actorID: String,
        clientID: String,
        operation: String,
        requestID: String,
        decision: String,
        detail: String,
        nowEpochSeconds: Int64,
        injectFailure: Bool
    ) throws {
        if injectFailure {
            throw AuthorizationError.unavailable("AUDIT_WRITE_FAILED")
        }
        let stmt = try store.prepare(
            "INSERT INTO audit_log (workspace_id, actor_id, client_id, operation, request_id, decision, detail, recorded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        )
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: workspaceID)
        try store.bindText(stmt, index: 2, value: actorID)
        try store.bindText(stmt, index: 3, value: clientID)
        try store.bindText(stmt, index: 4, value: operation)
        try store.bindText(stmt, index: 5, value: requestID)
        try store.bindText(stmt, index: 6, value: decision)
        try store.bindText(stmt, index: 7, value: detail)
        sqlite3_bind_int64(stmt, 8, nowEpochSeconds)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw AuthorizationError.unavailable("AUDIT_WRITE_FAILED")
        }
    }

    private func queryClientAuthRow(clientID: String) throws -> (
        signingKeyID: String,
        workspaces: [String],
        scopes: [String],
        status: String,
        policyVersion: UInt64,
        expiresAt: Int64
    ) {
        let stmt = try store.prepare(
            "SELECT signing_key_id, allowed_workspaces_json, allowed_scopes_json, status, policy_version, expires_at FROM registered_clients WHERE client_id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: clientID)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw AuthorizationError.denied("unknown client")
        }
        let keyID = store.columnText(stmt, index: 0)
        let ws = (try? JSONSerialization.jsonObject(with: Data(store.columnText(stmt, index: 1).utf8)) as? [String]) ?? []
        let sc = (try? JSONSerialization.jsonObject(with: Data(store.columnText(stmt, index: 2).utf8)) as? [String]) ?? []
        let status = store.columnText(stmt, index: 3)
        let pVer = UInt64(bitPattern: sqlite3_column_int64(stmt, 4))
        let exp = sqlite3_column_int64(stmt, 5)
        return (keyID, ws, sc, status, pVer, exp)
    }

    private func queryExistingIdempotency(
        actorID: String,
        workspaceID: String,
        operation: String,
        requestID: String
    ) throws -> (inputDigest: String, responseJSON: String?, resultRevision: UInt64?, resultCursor: UInt64?, expiresAt: Int64, tombstoned: Bool)? {
        let stmt = try store.prepare(
            "SELECT input_digest, response_json, result_revision, result_cursor, expires_at, tombstoned FROM idempotency_records WHERE actor_id = ? AND workspace_id = ? AND operation = ? AND request_id = ?"
        )
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: actorID)
        try store.bindText(stmt, index: 2, value: workspaceID)
        try store.bindText(stmt, index: 3, value: operation)
        try store.bindText(stmt, index: 4, value: requestID)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            let digest = store.columnText(stmt, index: 0)
            let resp = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : store.columnText(stmt, index: 1)
            let rev = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(stmt, 2))
            let cur = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(stmt, 3))
            let exp = sqlite3_column_int64(stmt, 4)
            let tomb = sqlite3_column_int(stmt, 5) != 0
            return (digest, resp, rev, cur, exp, tomb)
        }
        return nil
    }

    private func queryStoreGenInTx() throws -> String {
        let stmt = try store.prepare("SELECT store_generation FROM workspace_meta WHERE workspace_id = ?")
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: store.workspaceID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw AuthorizationError.unavailable("missing workspace_meta") }
        return store.columnText(stmt, index: 0)
    }

    private func queryCurrentRevisionInTx(workspaceID: String, objectID: String) throws -> UInt64? {
        let stmt = try store.prepare("SELECT revision FROM operational_state WHERE workspace_id = ? AND object_id = ?")
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: workspaceID)
        try store.bindText(stmt, index: 2, value: objectID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
    }

    private func queryMaxSeqInTx(workspaceID: String) throws -> UInt64 {
        let stmt = try store.prepare("SELECT COALESCE(MAX(seq), 0) FROM event_log WHERE workspace_id = ?")
        defer { sqlite3_finalize(stmt) }
        try store.bindText(stmt, index: 1, value: workspaceID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return UInt64(bitPattern: sqlite3_column_int64(stmt, 0))
    }
}
