import Foundation

public enum PermissionScope: String, Sendable, CaseIterable, Codable {
    case workspaceRead = "workspace:read"
    case workspaceWrite = "workspace:write"
    case observationRawRead = "observation:raw:read"
    case diagnosticsRead = "diagnostics:read"
    case templateRead = "template:read"
    case templateWrite = "template:write"
    case runRequest = "run:request"
    case runObserve = "run:observe"
    case runCancel = "run:cancel"
    case contextSubmit = "context:submit"
    case approvalDecide = "approval:decide"
}

public enum ApprovalKind: String, Sendable, Equatable, Codable {
    case configExportApply = "CONFIG_EXPORT_APPLY"
    case execution = "EXECUTION"
    case externalTransfer = "EXTERNAL_TRANSFER"
    case templateImportConfirm = "TEMPLATE_IMPORT_CONFIRM"
}

public enum ApprovalStatus: String, Sendable, Equatable, Codable {
    case pending = "PENDING"
    case approved = "APPROVED"
    case denied = "DENIED"
    case expired = "EXPIRED"
    case revoked = "REVOKED"
}

public struct ApprovalBinding: Sendable, Equatable, Codable {
    // CONFIG_EXPORT_APPLY
    public let planID: String?
    public let planDigest: String?
    public let targetFileVersions: [String: String]?
    public let agentDefinitionRevision: RevisionRef?
    public let adapterVersion: String?

    // EXECUTION
    public let runID: String?
    public let taskRevision: RevisionRef?
    public let preparedAttemptID: String?
    public let instanceRevision: RevisionRef?
    public let bindingDigest: String?
    public let capabilitySnapshotID: String?
    public let executionRequestDigest: String?

    // EXTERNAL_TRANSFER
    public let providerID: String?
    public let accountRef: String?
    public let recipientScope: String?
    public let contextSelectionRevision: RevisionRef?
    public let inputDigest: String?
    public let transferPurpose: String?
    public let dataScope: String?

    // TEMPLATE_IMPORT_CONFIRM
    public let candidateID: String?
    public let canonicalDigest: String?
    public let validatorVersion: String?
    public let targetFamily: String?
    public let expectedRevision: RevisionRef?

    public init(
        planID: String? = nil,
        planDigest: String? = nil,
        targetFileVersions: [String: String]? = nil,
        agentDefinitionRevision: RevisionRef? = nil,
        adapterVersion: String? = nil,
        runID: String? = nil,
        taskRevision: RevisionRef? = nil,
        preparedAttemptID: String? = nil,
        instanceRevision: RevisionRef? = nil,
        bindingDigest: String? = nil,
        capabilitySnapshotID: String? = nil,
        executionRequestDigest: String? = nil,
        providerID: String? = nil,
        accountRef: String? = nil,
        recipientScope: String? = nil,
        contextSelectionRevision: RevisionRef? = nil,
        inputDigest: String? = nil,
        transferPurpose: String? = nil,
        dataScope: String? = nil,
        candidateID: String? = nil,
        canonicalDigest: String? = nil,
        validatorVersion: String? = nil,
        targetFamily: String? = nil,
        expectedRevision: RevisionRef? = nil
    ) {
        self.planID = planID
        self.planDigest = planDigest
        self.targetFileVersions = targetFileVersions
        self.agentDefinitionRevision = agentDefinitionRevision
        self.adapterVersion = adapterVersion
        self.runID = runID
        self.taskRevision = taskRevision
        self.preparedAttemptID = preparedAttemptID
        self.instanceRevision = instanceRevision
        self.bindingDigest = bindingDigest
        self.capabilitySnapshotID = capabilitySnapshotID
        self.executionRequestDigest = executionRequestDigest
        self.providerID = providerID
        self.accountRef = accountRef
        self.recipientScope = recipientScope
        self.contextSelectionRevision = contextSelectionRevision
        self.inputDigest = inputDigest
        self.transferPurpose = transferPurpose
        self.dataScope = dataScope
        self.candidateID = candidateID
        self.canonicalDigest = canonicalDigest
        self.validatorVersion = validatorVersion
        self.targetFamily = targetFamily
        self.expectedRevision = expectedRevision
    }

    public func isValid(for kind: ApprovalKind) -> Bool {
        func nonEmpty(_ s: String?) -> Bool { !(s?.isEmpty ?? true) }
        switch kind {
        case .configExportApply:
            return nonEmpty(planID)
                && nonEmpty(planDigest)
                && !(targetFileVersions?.isEmpty ?? true)
                && agentDefinitionRevision != nil
                && nonEmpty(adapterVersion)
        case .execution:
            return nonEmpty(runID)
                && taskRevision != nil
                && nonEmpty(preparedAttemptID)
                && instanceRevision != nil
                && nonEmpty(bindingDigest)
                && nonEmpty(capabilitySnapshotID)
                && nonEmpty(executionRequestDigest)
        case .externalTransfer:
            return nonEmpty(providerID)
                && nonEmpty(accountRef)
                && nonEmpty(recipientScope)
                && contextSelectionRevision != nil
                && nonEmpty(inputDigest)
                && nonEmpty(transferPurpose)
                && nonEmpty(dataScope)
        case .templateImportConfirm:
            return nonEmpty(candidateID)
                && nonEmpty(canonicalDigest)
                && nonEmpty(validatorVersion)
                && nonEmpty(targetFamily)
                && expectedRevision != nil
        }
    }
}

public struct ApprovalRecord: Sendable, Equatable, Codable {
    public let approvalID: String
    public let kind: ApprovalKind
    public let subjectClientID: String
    public let decidedByActorID: String
    public let workspaceID: String
    public let normalizedTarget: String
    public let allowedScopes: [PermissionScope]
    public let binding: ApprovalBinding
    public let policyVersion: UInt64
    public let issuedAt: Int64
    public let expiresAt: Int64
    public let status: ApprovalStatus
    public let consumed: Bool

    public init(
        approvalID: String,
        kind: ApprovalKind,
        subjectClientID: String,
        decidedByActorID: String,
        workspaceID: String,
        normalizedTarget: String,
        allowedScopes: [PermissionScope],
        binding: ApprovalBinding,
        policyVersion: UInt64,
        issuedAt: Int64,
        expiresAt: Int64,
        status: ApprovalStatus,
        consumed: Bool = false
    ) {
        self.approvalID = approvalID
        self.kind = kind
        self.subjectClientID = subjectClientID
        self.decidedByActorID = decidedByActorID
        self.workspaceID = workspaceID
        self.normalizedTarget = normalizedTarget
        self.allowedScopes = allowedScopes
        self.binding = binding
        self.policyVersion = policyVersion
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.status = status
        self.consumed = consumed
    }

    public func isStructurallyValid() -> Bool {
        !approvalID.isEmpty
            && !subjectClientID.isEmpty
            && !decidedByActorID.isEmpty
            && !workspaceID.isEmpty
            && !normalizedTarget.isEmpty
            && !allowedScopes.isEmpty
            && issuedAt < expiresAt
            && binding.isValid(for: kind)
    }
}

public enum PolicyDecision: Sendable, Equatable {
    case allow
    case deny(reason: String)
    case approvalRequired([ApprovalKind])
    case unknown(reason: String)
}

public enum AuthorizationError: Error, Sendable, Equatable {
    case denied(String)
    case approvalRequired([ApprovalKind])
    case conflict(String)
    case stale(String)
    case unavailable(String)
    case invalidInput(String)
    case unknown(String)

    public var safeWireError: SafeWireError {
        switch self {
        case .denied:
            return SafeWireError(code: .denied, detail: nil)
        case .approvalRequired:
            return SafeWireError(code: .approvalRequired, detail: nil)
        case .conflict:
            return SafeWireError(code: .conflict, detail: nil)
        case .stale:
            return SafeWireError(code: .stale, detail: nil)
        case .unavailable:
            return SafeWireError(code: .unavailable, detail: nil)
        case .invalidInput:
            return SafeWireError(code: .invalidInput, detail: nil)
        case .unknown:
            return SafeWireError(code: .unknown, detail: nil)
        }
    }
}

public struct PolicyEvaluationRequest: Sendable, Equatable {
    public let trustLevel: ClientTrustLevel
    public let clientScopes: Set<PermissionScope>
    public let workspaceScopes: Set<PermissionScope>
    public let requiredScope: PermissionScope
    public let requiredApprovals: [ApprovalKind]
    public let enforcementVerified: Bool?
    public let isUntrustedContentOrigin: Bool
    public let isTrustedDesktopUISession: Bool

    public init(
        trustLevel: ClientTrustLevel,
        clientScopes: Set<PermissionScope>,
        workspaceScopes: Set<PermissionScope>,
        requiredScope: PermissionScope,
        requiredApprovals: [ApprovalKind] = [],
        enforcementVerified: Bool? = true,
        isUntrustedContentOrigin: Bool = false,
        isTrustedDesktopUISession: Bool = false
    ) {
        self.trustLevel = trustLevel
        self.clientScopes = clientScopes
        self.workspaceScopes = workspaceScopes
        self.requiredScope = requiredScope
        self.requiredApprovals = requiredApprovals
        self.enforcementVerified = enforcementVerified
        self.isUntrustedContentOrigin = isUntrustedContentOrigin
        self.isTrustedDesktopUISession = isTrustedDesktopUISession
    }
}

public struct PolicyEngine: Sendable {
    public init() {}

    public func evaluate(_ request: PolicyEvaluationRequest) -> PolicyDecision {
        // Content scripts, webviews, and untrusted file text can never authorize or decide approvals
        if request.isUntrustedContentOrigin {
            return .deny(reason: "untrusted content origin cannot execute or approve")
        }

        // approval:decide is exclusively reserved for verified Desktop trusted UI sessions
        if request.requiredScope == .approvalDecide {
            guard request.trustLevel == .platformBound,
                  request.isTrustedDesktopUISession,
                  request.clientScopes.contains(.approvalDecide),
                  request.workspaceScopes.contains(.approvalDecide) else {
                return .deny(reason: "approval:decide requires verified trusted Desktop UI")
            }
        }

        // Strict intersection of client scopes and workspace scopes (no implicit cross-scope escalation)
        guard request.clientScopes.contains(request.requiredScope),
              request.workspaceScopes.contains(request.requiredScope) else {
            return .deny(reason: "missing required scope \(request.requiredScope.rawValue)")
        }

        // Fail closed when enforcement verification is unknown or false
        guard let verified = request.enforcementVerified else {
            return .unknown(reason: "enforcement boundary status unknown")
        }
        if !verified {
            return .deny(reason: "unverified enforcement boundary blocks risky action")
        }

        if !request.requiredApprovals.isEmpty {
            return .approvalRequired(request.requiredApprovals)
        }
        return .allow
    }
}
