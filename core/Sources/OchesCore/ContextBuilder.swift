import CryptoKit
import Foundation
import SQLite3

public enum ContextExclusionReason: String, Sendable, Equatable, Codable {
    case notVerified
    case staleExpired
    case evidenceDeleted
    case evidenceChanged
    case evidenceUnverified
    case permissionRevoked
    case policyChanged
    case budgetExceeded
    case timeoutPartial
    case deleted
}

public struct ContextSelectionItem: Sendable, Equatable, Codable {
    public let memoryID: String
    public let memoryRevision: RevisionRef
    public let evidenceRefs: [MemoryEvidenceRef]
    public let byteLength: Int
    public let selectionReason: String
    public let treatedAsDataOnly: Bool

    public init(
        memoryID: String,
        memoryRevision: RevisionRef,
        evidenceRefs: [MemoryEvidenceRef],
        byteLength: Int,
        selectionReason: String,
        treatedAsDataOnly: Bool = true
    ) {
        self.memoryID = memoryID
        self.memoryRevision = memoryRevision
        self.evidenceRefs = evidenceRefs
        self.byteLength = byteLength
        self.selectionReason = selectionReason
        self.treatedAsDataOnly = treatedAsDataOnly
    }
}

public struct ContextExclusionItem: Sendable, Equatable, Codable {
    public let memoryID: String
    public let reason: ContextExclusionReason
    public let detail: String

    public init(memoryID: String, reason: ContextExclusionReason, detail: String) {
        self.memoryID = memoryID
        self.reason = reason
        self.detail = detail
    }
}

public struct ContextSelectionRecord: Sendable, Equatable, Codable {
    public let selectionID: String
    public let workspaceID: String
    public let taskRevision: RevisionRef
    public let policyVersion: UInt64
    public let budgetBytes: Int
    public let usedBytes: Int
    public let selectedItems: [ContextSelectionItem]
    public let excludedItems: [ContextExclusionItem]
    public let transferPreviewDigest: String
    public let partial: Bool
    public let incompleteReason: String?
    public let selectedAt: Int64
    public let transferExecuted: Bool

    public init(
        selectionID: String,
        workspaceID: String,
        taskRevision: RevisionRef,
        policyVersion: UInt64,
        budgetBytes: Int,
        usedBytes: Int,
        selectedItems: [ContextSelectionItem],
        excludedItems: [ContextExclusionItem],
        transferPreviewDigest: String,
        partial: Bool,
        incompleteReason: String?,
        selectedAt: Int64,
        transferExecuted: Bool = false
    ) {
        self.selectionID = selectionID
        self.workspaceID = workspaceID
        self.taskRevision = taskRevision
        self.policyVersion = policyVersion
        self.budgetBytes = budgetBytes
        self.usedBytes = usedBytes
        self.selectedItems = selectedItems
        self.excludedItems = excludedItems
        self.transferPreviewDigest = transferPreviewDigest
        self.partial = partial
        self.incompleteReason = incompleteReason
        self.selectedAt = selectedAt
        self.transferExecuted = transferExecuted
    }
}

public struct TransferAuthorizationResult: Sendable, Equatable {
    public let selectionRevision: RevisionRef
    public let approvedItemCount: Int
    public let transferPreviewDigest: String
    public let consumedApprovalID: String
}

public final class ContextBuilder: @unchecked Sendable {
    /// Frozen E8 context cap: 64 KiB.
    public static let maxContextBudgetBytes: Int = 65_536
    /// Frozen E8 selection timeout: 5 seconds.
    public static let defaultTimeoutSeconds: Int64 = 5

    public let store: SQLiteStore
    public let memoryStore: MemoryStore
    public let deletionLifecycle: DeletionRequestLifecycle

    public init(store: SQLiteStore, memoryStore: MemoryStore) throws {
        guard memoryStore.store === store else {
            throw StorageError.invalidInput
        }
        self.store = store
        self.memoryStore = memoryStore
        self.deletionLifecycle = try DeletionRequestLifecycle(store: store)
    }

    public func selectContext(
        selectionID: String,
        taskRevision: RevisionRef,
        keywords: [String],
        callerScopes: Set<PermissionScope>,
        currentPolicyVersion: UInt64,
        budgetBytes: Int = ContextBuilder.maxContextBudgetBytes,
        evidenceResolver: EvidenceStatusResolver,
        actorID: String,
        requestID: String,
        now: Int64,
        injectTimeoutAfterCount: Int? = nil
    ) throws -> (revision: RevisionRef, selection: ContextSelectionRecord) {
        let objID = try Self.selectionObjectID(for: selectionID)
        guard budgetBytes > 0, budgetBytes <= Self.maxContextBudgetBytes else {
            throw MemoryError.budgetInvalid
        }
        guard now >= 0, !taskRevision.objectID.isEmpty else {
            throw StorageError.invalidInput
        }

        let candidateIDs: [String]
        if keywords.isEmpty {
            let fromIndex = Set(try memoryStore.searchDerivedIndex(keywords: []))
            let fromCanonical = Set(try memoryStore.listAllCanonicalEntries().map(\.entry.memoryID))
            candidateIDs = Array(fromIndex.union(fromCanonical)).sorted()
        } else {
            candidateIDs = Array(Set(try memoryStore.searchDerivedIndex(keywords: keywords))).sorted()
        }

        var selectedItems: [ContextSelectionItem] = []
        var excludedItems: [ContextExclusionItem] = []
        var itemDigests: [RawJSONValue] = []
        var usedBytes = 0
        var partial = false
        var incompleteReason: String?
        var processed = 0

        for index in candidateIDs.indices {
            let memoryID = candidateIDs[index]
            if let limit = injectTimeoutAfterCount, processed >= limit {
                partial = true
                incompleteReason = "selectContext timeout (\(Self.defaultTimeoutSeconds)s)"
                for remainingID in candidateIDs[index...] {
                    excludedItems.append(ContextExclusionItem(
                        memoryID: remainingID,
                        reason: .timeoutPartial,
                        detail: "excluded due to selection timeout"
                    ))
                }
                break
            }
            processed += 1

            let memObjID = try MemoryStore.objectID(for: memoryID)
            if try memoryStore.isTargetDeleted(memObjID) || deletionLifecycle.isTargetBlockedForReads(targetID: memObjID) {
                excludedItems.append(ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .deleted,
                    detail: "memory deleted"
                ))
                continue
            }

            let loaded: (revision: RevisionRef, entry: MemoryEntryRecord)
            do {
                loaded = try memoryStore.readCanonical(memoryID: memoryID)
            } catch {
                excludedItems.append(ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .deleted,
                    detail: "canonical memory unavailable or deleted"
                ))
                continue
            }
            let entry = loaded.entry

            if entry.state == .stale {
                excludedItems.append(ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .staleExpired,
                    detail: entry.invalidationReason ?? "memory marked stale"
                ))
                continue
            }
            guard entry.state == .verified else {
                excludedItems.append(ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .notVerified,
                    detail: "state is \(entry.state.rawValue)"
                ))
                continue
            }
            guard let expiresAt = entry.expiresAt, now < expiresAt else {
                excludedItems.append(ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .staleExpired,
                    detail: "90-day verification expired"
                ))
                continue
            }
            guard entry.policyVersion == currentPolicyVersion else {
                excludedItems.append(ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .policyChanged,
                    detail: "policy version mismatch (\(entry.policyVersion) != \(currentPolicyVersion))"
                ))
                continue
            }
            guard callerScopes.contains(entry.accessScope) else {
                excludedItems.append(ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .permissionRevoked,
                    detail: "missing scope \(entry.accessScope.rawValue)"
                ))
                continue
            }

            if let evidenceExclusion = try validateEvidenceRefs(
                memoryID: memoryID,
                refs: entry.evidenceRefs,
                callerScopes: callerScopes,
                evidenceResolver: evidenceResolver
            ) {
                excludedItems.append(evidenceExclusion)
                continue
            }

            let rendered = MemoryStore.renderMarkdownWithFrontmatter(entry)
            let renderedBytes = Data(rendered.utf8)
            let byteLen = renderedBytes.count
            guard usedBytes + byteLen <= budgetBytes else {
                excludedItems.append(ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .budgetExceeded,
                    detail: "item size \(byteLen) exceeds remaining budget \(budgetBytes - usedBytes)"
                ))
                continue
            }

            usedBytes += byteLen
            let renderedDigest = Data(SHA256.hash(data: renderedBytes)).map { String(format: "%02x", $0) }.joined()
            selectedItems.append(ContextSelectionItem(
                memoryID: memoryID,
                memoryRevision: loaded.revision,
                evidenceRefs: entry.evidenceRefs,
                byteLength: byteLen,
                selectionReason: "verified evidence-backed entry within budget",
                treatedAsDataOnly: true
            ))
            itemDigests.append(.object([
                ("memoryID", .string(memoryID)),
                ("objectID", .string(loaded.revision.objectID)),
                ("storeGeneration", .string(loaded.revision.storeGeneration)),
                ("revision", .string(loaded.revision.revision)),
                ("renderedDigest", .string(renderedDigest)),
            ]))
        }

        let previewDigestData = try canonicalSHA256(.object([
            ("domain", .string("oches.context.selection.v1")),
            ("selectionID", .string(selectionID)),
            ("workspaceID", .string(store.workspaceID)),
            ("taskObjectID", .string(taskRevision.objectID)),
            ("taskGeneration", .string(taskRevision.storeGeneration)),
            ("taskRevision", .string(taskRevision.revision)),
            ("policyVersion", .number(String(currentPolicyVersion))),
            ("items", .array(itemDigests)),
        ]))
        let previewDigest = previewDigestData.map { String(format: "%02x", $0) }.joined()

        let selection = ContextSelectionRecord(
            selectionID: selectionID,
            workspaceID: store.workspaceID,
            taskRevision: taskRevision,
            policyVersion: currentPolicyVersion,
            budgetBytes: budgetBytes,
            usedBytes: usedBytes,
            selectedItems: selectedItems,
            excludedItems: excludedItems,
            transferPreviewDigest: previewDigest,
            partial: partial,
            incompleteReason: incompleteReason,
            selectedAt: now,
            transferExecuted: false
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadJSON = String(decoding: try encoder.encode(selection), as: UTF8.self)
        let request = TransitionRequest(
            actorID: actorID,
            workspaceID: store.workspaceID,
            operation: "context.select",
            requestID: requestID,
            objectID: objID,
            ownerModule: "ARC-08",
            expectedRevision: nil,
            normalizedInput: .object([
                ("selectionID", .string(selectionID)),
                ("previewDigest", .string(previewDigest)),
                ("policyVersion", .number(String(currentPolicyVersion))),
            ]),
            nextStateJSON: payloadJSON,
            events: [NewEventRecord(eventID: UUID().uuidString, sourceID: "ARC-08", kind: "context.select", payloadJSON: "{}", observedAt: now)],
            responseJSON: payloadJSON,
            nowEpochSeconds: now
        )
        let result = try store.commitTransition(request)
        let decoded = try JSONDecoder().decode(ContextSelectionRecord.self, from: Data(result.responseJSON.utf8))
        return (result.revision, decoded)
    }

    public func revalidateAndAuthorizeTransfer(
        selectionID: String,
        selectionRevision: RevisionRef,
        clientID: String,
        callerScopes: Set<PermissionScope>,
        currentPolicyVersion: UInt64,
        providerID: String,
        accountRef: String,
        recipientScope: String,
        transferPurpose: String,
        dataScope: String,
        transferApprovalID: String?,
        evidenceResolver: EvidenceStatusResolver,
        now: Int64
    ) throws -> TransferAuthorizationResult {
        let objID = try Self.selectionObjectID(for: selectionID)
        let snapshot = try store.readSnapshot(workspaceID: store.workspaceID, objectID: objID)
        guard snapshot.ownerModule == "ARC-08" else {
            throw StorageError.corrupt("invalid context selection owner")
        }
        guard snapshot.revision == selectionRevision else {
            throw MemoryError.selectionStale(reasons: ["selection revision or storeGeneration changed"])
        }
        let selection = try JSONDecoder().decode(ContextSelectionRecord.self, from: Data(snapshot.stateJSON.utf8))

        var staleReasons: [String] = []
        if selection.policyVersion != currentPolicyVersion {
            staleReasons.append("policy version changed")
        }

        for item in selection.selectedItems {
            let memObjID = try MemoryStore.objectID(for: item.memoryID)
            if try memoryStore.isTargetDeleted(memObjID) || deletionLifecycle.isTargetBlockedForReads(targetID: memObjID) {
                staleReasons.append("memory \(item.memoryID) deleted")
                continue
            }
            let currentMem: (revision: RevisionRef, entry: MemoryEntryRecord)
            do {
                currentMem = try memoryStore.readCanonical(memoryID: item.memoryID)
            } catch {
                staleReasons.append("memory \(item.memoryID) unavailable")
                continue
            }
            if currentMem.revision != item.memoryRevision {
                staleReasons.append("memory \(item.memoryID) revision changed")
            }
            if currentMem.entry.state != .verified {
                staleReasons.append("memory \(item.memoryID) is \(currentMem.entry.state.rawValue)")
            }
            if let expiresAt = currentMem.entry.expiresAt, now >= expiresAt {
                staleReasons.append("memory \(item.memoryID) verification expired")
            }
            if currentMem.entry.policyVersion != currentPolicyVersion {
                staleReasons.append("memory \(item.memoryID) policy version changed")
            }
            if !callerScopes.contains(currentMem.entry.accessScope) {
                staleReasons.append("caller lacks scope \(currentMem.entry.accessScope.rawValue)")
            }
            if let evidenceIssue = try validateEvidenceRefs(
                memoryID: item.memoryID,
                refs: currentMem.entry.evidenceRefs,
                callerScopes: callerScopes,
                evidenceResolver: evidenceResolver
            ) {
                staleReasons.append("\(item.memoryID): \(evidenceIssue.detail)")
            }
        }

        guard staleReasons.isEmpty else {
            throw MemoryError.selectionStale(reasons: staleReasons)
        }

        guard let approvalID = transferApprovalID, !approvalID.isEmpty else {
            throw MemoryError.approvalRequired([.externalTransfer])
        }

        try store.withConnectionLock { db in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                guard try approvalsTableExists() else {
                    throw MemoryError.approvalRequired([.externalTransfer])
                }
                let stmt = try store.prepare(
                    "SELECT kind, subject_client_id, workspace_id, binding_json, issued_at, expires_at, status, consumed FROM approvals WHERE approval_id = ?"
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: approvalID)
                guard sqlite3_step(stmt) == SQLITE_ROW else {
                    throw MemoryError.approvalRequired([.externalTransfer])
                }
                let kindStr = store.columnText(stmt, index: 0)
                let subject = store.columnText(stmt, index: 1)
                let ws = store.columnText(stmt, index: 2)
                let bindingJSON = store.columnText(stmt, index: 3)
                let issuedAt = sqlite3_column_int64(stmt, 4)
                let expiresAt = sqlite3_column_int64(stmt, 5)
                let status = store.columnText(stmt, index: 6)
                let consumed = sqlite3_column_int(stmt, 7)

                guard kindStr == ApprovalKind.externalTransfer.rawValue,
                      subject.utf8.elementsEqual(clientID.utf8),
                      ws.utf8.elementsEqual(store.workspaceID.utf8),
                      status == ApprovalStatus.approved.rawValue,
                      consumed == 0,
                      issuedAt < expiresAt,
                      now >= issuedAt,
                      now < expiresAt else {
                    throw MemoryError.approvalRequired([.externalTransfer])
                }

                guard let binding = try? JSONDecoder().decode(ApprovalBinding.self, from: Data(bindingJSON.utf8)),
                      binding.isValid(for: .externalTransfer),
                      binding.providerID == providerID,
                      binding.accountRef == accountRef,
                      binding.recipientScope == recipientScope,
                      binding.contextSelectionRevision == selectionRevision,
                      binding.inputDigest == selection.transferPreviewDigest,
                      binding.transferPurpose == transferPurpose,
                      binding.dataScope == dataScope else {
                    throw MemoryError.permissionDenied("external transfer approval binding mismatch")
                }

                let upd = try store.prepare("UPDATE approvals SET consumed = 1 WHERE approval_id = ? AND consumed = 0")
                defer { sqlite3_finalize(upd) }
                try store.bindText(upd, index: 1, value: approvalID)
                guard sqlite3_step(upd) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                    throw MemoryError.approvalRequired([.externalTransfer])
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }

        return TransferAuthorizationResult(
            selectionRevision: selectionRevision,
            approvedItemCount: selection.selectedItems.count,
            transferPreviewDigest: selection.transferPreviewDigest,
            consumedApprovalID: approvalID
        )
    }

    private func validateEvidenceRefs(
        memoryID: String,
        refs: [MemoryEvidenceRef],
        callerScopes: Set<PermissionScope>,
        evidenceResolver: EvidenceStatusResolver
    ) throws -> ContextExclusionItem? {
        guard !refs.isEmpty else {
            return ContextExclusionItem(
                memoryID: memoryID,
                reason: .evidenceUnverified,
                detail: "no evidence references"
            )
        }
        for ref in refs {
            if try memoryStore.isTargetDeleted(ref.objectID) || deletionLifecycle.isTargetBlockedForReads(targetID: ref.objectID) {
                return ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .evidenceDeleted,
                    detail: "evidence \(ref.objectID) deleted"
                )
            }
            guard callerScopes.contains(ref.requiredScope) else {
                return ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .permissionRevoked,
                    detail: "missing evidence scope \(ref.requiredScope.rawValue)"
                )
            }
            let status = try evidenceResolver(ref)
            if status.revoked {
                return ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .permissionRevoked,
                    detail: "evidence access revoked for \(ref.objectID)"
                )
            }
            if !status.exists {
                return ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .evidenceDeleted,
                    detail: "evidence \(ref.objectID) missing"
                )
            }
            if status.currentRevision != ref.revision || status.currentDigest != ref.contentDigest {
                return ContextExclusionItem(
                    memoryID: memoryID,
                    reason: .evidenceChanged,
                    detail: "evidence \(ref.objectID) changed"
                )
            }
        }
        return nil
    }

    private func approvalsTableExists() throws -> Bool {
        let stmt = try store.prepare("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'approvals'")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    private static func selectionObjectID(for selectionID: String) throws -> String {
        guard selectionID.utf8.count <= 128,
              selectionID.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil else {
            throw MemoryError.invalidInput("invalid selectionID")
        }
        return "arc08/selection/" + selectionID
    }
}
