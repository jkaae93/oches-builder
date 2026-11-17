import Foundation

public enum CapabilityID: String, Sendable, CaseIterable, Codable {
    case providerInstall = "provider.install"
    case authOfficial = "auth.official"
    case authAccountIsolation = "auth.accountIsolation"
    case runStart = "run.start"
    case runCancel = "run.cancel"
    case runResume = "run.resume"
    case eventStructured = "event.structured"
    case permissionEnforce = "permission.enforce"
    case configExport = "config.export"
    case usageMeasure = "usage.measure"
    case clientLocal = "client.local"
    case clientRemoteWorkspace = "client.remoteWorkspace"
}

public enum CapabilityStatus: String, Sendable, Equatable, Codable {
    case supported
    case unsupported
    case unknown
}

public enum CapabilityEvidenceBasis: String, Sendable, Equatable, Codable {
    case documented
    case experiment
    case policy
    case verifiedInOches = "VERIFIED_IN_OCHES"
}

public struct CapabilityScope: Sendable, Equatable, Codable {
    public let installationID: String
    public let executableIdentity: String
    public let cliVersion: String
    public let adapterVersion: String
    public let osVersionArch: String
    public let accountRef: String
    public let accountType: AccountKind
    public let workspaceID: String
    public let workspaceLocationAuthority: String
    public let workspaceTrust: Bool
    public let clientID: String
    public let clientKind: String
    public let negotiatedProtocolMajorMinor: String
    public let policyVersion: UInt64

    public init(
        installationID: String,
        executableIdentity: String,
        cliVersion: String,
        adapterVersion: String,
        osVersionArch: String,
        accountRef: String,
        accountType: AccountKind,
        workspaceID: String,
        workspaceLocationAuthority: String,
        workspaceTrust: Bool,
        clientID: String,
        clientKind: String,
        negotiatedProtocolMajorMinor: String,
        policyVersion: UInt64
    ) {
        self.installationID = installationID
        self.executableIdentity = executableIdentity
        self.cliVersion = cliVersion
        self.adapterVersion = adapterVersion
        self.osVersionArch = osVersionArch
        self.accountRef = accountRef
        self.accountType = accountType
        self.workspaceID = workspaceID
        self.workspaceLocationAuthority = workspaceLocationAuthority
        self.workspaceTrust = workspaceTrust
        self.clientID = clientID
        self.clientKind = clientKind
        self.negotiatedProtocolMajorMinor = negotiatedProtocolMajorMinor
        self.policyVersion = policyVersion
    }

    public var isRemoteWorkspace: Bool {
        workspaceLocationAuthority != "local"
    }

    public func mismatchReason(against other: CapabilityScope) -> String? {
        if installationID != other.installationID { return "installationID changed" }
        if executableIdentity != other.executableIdentity { return "executableIdentity changed" }
        if cliVersion != other.cliVersion { return "cliVersion changed" }
        if adapterVersion != other.adapterVersion { return "adapterVersion changed" }
        if osVersionArch != other.osVersionArch { return "osVersionArch changed" }
        if accountRef != other.accountRef { return "accountRef changed" }
        if accountType != other.accountType { return "accountType changed" }
        if workspaceID != other.workspaceID { return "workspaceID changed" }
        if workspaceLocationAuthority != other.workspaceLocationAuthority { return "workspaceLocationAuthority changed" }
        if workspaceTrust != other.workspaceTrust { return "workspaceTrust changed" }
        if clientID != other.clientID { return "clientID changed" }
        if clientKind != other.clientKind { return "clientKind changed" }
        if negotiatedProtocolMajorMinor != other.negotiatedProtocolMajorMinor { return "negotiatedProtocolMajorMinor changed" }
        if policyVersion != other.policyVersion { return "policyVersion changed" }
        return nil
    }
}

public struct CapabilityEntry: Sendable, Equatable, Codable {
    public let capabilityID: CapabilityID
    public let status: CapabilityStatus
    public let basis: CapabilityEvidenceBasis
    public let evidenceRef: String
    public let observedAt: Int64

    public init(
        capabilityID: CapabilityID,
        status: CapabilityStatus,
        basis: CapabilityEvidenceBasis,
        evidenceRef: String,
        observedAt: Int64
    ) {
        self.capabilityID = capabilityID
        self.status = status
        self.basis = basis
        self.evidenceRef = evidenceRef
        self.observedAt = observedAt
    }

    /// Documented-only entries never become supported without product experiment/policy verification (`CV01`, `CV18`).
    public var effectiveStatus: CapabilityStatus {
        if basis == .documented && status == .supported {
            return .unknown
        }
        return status
    }
}

public struct CapabilitySnapshot: Sendable, Equatable, Codable {
    public let snapshotID: String
    public let scope: CapabilityScope
    public let entries: [CapabilityID: CapabilityEntry]
    public let observedAt: Int64

    public init(
        snapshotID: String,
        scope: CapabilityScope,
        entries: [CapabilityEntry],
        observedAt: Int64
    ) {
        self.snapshotID = snapshotID
        self.scope = scope
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.capabilityID, $0) })
        self.observedAt = observedAt
    }
}

public enum CapabilityGateOutcome: Sendable, Equatable {
    case supported
    case unsupported(capability: CapabilityID)
    case unknown(capability: CapabilityID, reason: String)
    case stale(reason: String)

    public var safeWireError: SafeWireError? {
        switch self {
        case .supported:
            return nil
        case .unsupported:
            return SafeWireError(code: .unsupported, detail: nil)
        case .unknown:
            return SafeWireError(code: .unknown, detail: nil)
        case .stale:
            return SafeWireError(code: .stale, detail: nil)
        }
    }
}

public struct CapabilityEvaluator: Sendable {
    public init() {}

    public func evaluate(
        snapshot: CapabilitySnapshot,
        requestedScope: CapabilityScope,
        requiredCapabilities: [CapabilityID]
    ) -> CapabilityGateOutcome {
        if let mismatch = snapshot.scope.mismatchReason(against: requestedScope) {
            return .stale(reason: mismatch)
        }

        if requestedScope.accountRef.isEmpty || requestedScope.installationID.isEmpty || !requestedScope.workspaceTrust {
            return .unknown(capability: .clientLocal, reason: "incomplete scope or untrusted workspace")
        }

        // CV06: remote workspace cannot coerce to local and requires client.remoteWorkspace == supported
        if requestedScope.isRemoteWorkspace {
            let remoteEntry = snapshot.entries[.clientRemoteWorkspace]
            let remoteEffective = remoteEntry?.effectiveStatus ?? .unknown
            if remoteEffective == .unsupported {
                return .unsupported(capability: .clientRemoteWorkspace)
            }
            if remoteEffective != .supported {
                return .unknown(capability: .clientRemoteWorkspace, reason: "remote workspace capability unverified")
            }
        }

        var firstUnknown: CapabilityID?
        for capID in requiredCapabilities {
            guard let entry = snapshot.entries[capID] else {
                if firstUnknown == nil { firstUnknown = capID }
                continue
            }
            switch entry.effectiveStatus {
            case .supported:
                continue
            case .unsupported:
                return .unsupported(capability: capID)
            case .unknown:
                if firstUnknown == nil { firstUnknown = capID }
            }
        }

        if let unknownCap = firstUnknown {
            return .unknown(capability: unknownCap, reason: "required capability \(unknownCap.rawValue) is unknown or documented-only")
        }
        return .supported
    }

    public func evaluateConcurrentAccountIsolation(
        snapshot: CapabilitySnapshot,
        requestedScope: CapabilityScope,
        otherActiveAttemptCount: Int
    ) -> CapabilityGateOutcome {
        if let mismatch = snapshot.scope.mismatchReason(against: requestedScope) {
            return .stale(reason: mismatch)
        }
        guard otherActiveAttemptCount > 0 else {
            return .supported
        }
        let isolation = snapshot.entries[.authAccountIsolation]?.effectiveStatus ?? .unknown
        switch isolation {
        case .supported:
            return .supported
        case .unsupported:
            return .unsupported(capability: .authAccountIsolation)
        case .unknown:
            return .unknown(capability: .authAccountIsolation, reason: "concurrent account isolation unverified")
        }
    }
}
