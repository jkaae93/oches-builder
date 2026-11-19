import Foundation

public enum VerificationCaseStatus: String, Sendable, Equatable, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case notRun = "NOT RUN"
    case blocked = "BLOCKED"
    case indeterminate = "INDETERMINATE"
}

public enum VerificationEvidenceLayer: String, Sendable, Equatable, Codable {
    case unitAndContractTest
    case productGate
}

public enum ReleasePhase: String, Sendable, Equatable, Codable {
    case phase1LocalCoreDesktop = "Phase 1 (Local Core + Desktop)"
    case phase2ExtensionsAndPackaging = "Phase 2 (Extensions + Packaging)"
}

public enum ReleaseGateError: Error, Sendable, Equatable {
    case invalidEvidenceClaim(String)
    case emptyRequiredCases
}

public struct VerificationEvidenceRecord: Sendable, Equatable, Codable {
    public let id: String
    public let category: String
    public let layer: VerificationEvidenceLayer
    public let status: VerificationCaseStatus
    public let version: String
    public let environment: String
    public let repeats: Int
    public let passedCount: Int
    public let denominator: Int
    public let evidencePath: String
    public let residualLimits: String?

    public init(
        id: String,
        category: String,
        layer: VerificationEvidenceLayer,
        status: VerificationCaseStatus,
        version: String,
        environment: String,
        repeats: Int,
        passedCount: Int,
        denominator: Int,
        evidencePath: String,
        residualLimits: String? = nil
    ) {
        self.id = id
        self.category = category
        self.layer = layer
        self.status = status
        self.version = version
        self.environment = environment
        self.repeats = repeats
        self.passedCount = passedCount
        self.denominator = denominator
        self.evidencePath = evidencePath
        self.residualLimits = residualLimits
    }

    public func validateIntegrity() throws {
        guard !id.isEmpty, !version.isEmpty, !environment.isEmpty, !evidencePath.isEmpty else {
            throw ReleaseGateError.invalidEvidenceClaim("missing required metadata for \(id)")
        }
        guard repeats >= 0, denominator >= 0, passedCount >= 0, passedCount <= denominator else {
            throw ReleaseGateError.invalidEvidenceClaim("invalid repeat/denominator counts for \(id)")
        }
        if repeats > 0, denominator > 0, denominator < repeats {
            throw ReleaseGateError.invalidEvidenceClaim("denominator \(denominator) < repeats \(repeats) for \(id)")
        }
        if status == .pass {
            guard denominator > 0, passedCount == denominator else {
                throw ReleaseGateError.invalidEvidenceClaim(
                    "cannot mark PASS when passedCount (\(passedCount)) != denominator (\(denominator)) for \(id)"
                )
            }
            if layer == .productGate, let residualLimits, !residualLimits.isEmpty {
                throw ReleaseGateError.invalidEvidenceClaim(
                    "productGate \(id) cannot be PASS while unresolved residual limits remain: \(residualLimits)"
                )
            }
        }
    }
}

public struct ReleasePhaseGateDecision: Sendable, Equatable {
    public let phase: ReleasePhase
    public let verdict: VerificationCaseStatus
    public let passingCount: Int
    public let failingCount: Int
    public let notRunOrIndeterminateCount: Int
    public let blockedReasons: [String]
}

public struct PairedComparisonRowSummary: Sendable, Equatable {
    public let providerName: String
    public let repeats: Int
    public let passedCount: Int
    public let failedCount: Int
    public let costUnavailableCount: Int
    public let subscriptionIncludedCount: Int
    public let confirmedTotalMicroUSD: Int64?
    public let liveProviderVerified: Bool
}

public enum ReleaseGateEvaluator {
    public static func evaluatePhaseGate(
        phase: ReleasePhase,
        requiredCases: [VerificationEvidenceRecord]
    ) throws -> ReleasePhaseGateDecision {
        guard !requiredCases.isEmpty else {
            throw ReleaseGateError.emptyRequiredCases
        }
        var passCount = 0
        var failCount = 0
        var blockedCount = 0
        var blockedReasons: [String] = []

        for item in requiredCases {
            try item.validateIntegrity()
            switch item.status {
            case .pass:
                passCount += 1
            case .fail:
                failCount += 1
                blockedReasons.append("\(item.id): FAIL (\(item.residualLimits ?? item.evidencePath))")
            case .notRun, .blocked, .indeterminate:
                blockedCount += 1
                blockedReasons.append("\(item.id): \(item.status.rawValue) (\(item.residualLimits ?? "unverified"))")
            }
        }

        let verdict: VerificationCaseStatus
        if failCount > 0 {
            verdict = .fail
        } else if blockedCount > 0 {
            verdict = .blocked
        } else {
            verdict = .pass
        }

        return ReleasePhaseGateDecision(
            phase: phase,
            verdict: verdict,
            passingCount: passCount,
            failingCount: failCount,
            notRunOrIndeterminateCount: blockedCount,
            blockedReasons: blockedReasons
        )
    }

    public static func summarizePairedComparison(
        fixtureID: String,
        entries: [ProviderComparisonEntry]
    ) -> [PairedComparisonRowSummary] {
        let report = ProviderComparisonHarness.buildReport(fixtureID: fixtureID, entries: entries)
        let grouped = Dictionary(grouping: report.entries, by: \.providerName)
        return grouped.keys.sorted().map { provider in
            let list = grouped[provider] ?? []
            let summary = report.costSummaryByProvider[provider]
            let passed = list.filter { $0.evaluationVerdict == .pass }.count
            let failed = list.filter { $0.evaluationVerdict == .fail }.count
            let unavailable = summary?.unknownCount ?? list.count
            let subIncluded = summary?.subscriptionIncludedCount ?? 0
            let liveVerified = !list.isEmpty && list.allSatisfy { $0.executionMode == .liveExternalAPI }
            return PairedComparisonRowSummary(
                providerName: provider,
                repeats: list.count,
                passedCount: passed,
                failedCount: failed,
                costUnavailableCount: unavailable,
                subscriptionIncludedCount: subIncluded,
                confirmedTotalMicroUSD: summary?.confirmedTotalMicroUSD,
                liveProviderVerified: liveVerified
            )
        }
    }
}
