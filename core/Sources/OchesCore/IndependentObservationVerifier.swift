import CryptoKit
import Foundation

public enum ObservationBoundary: String, Sendable, Equatable, Codable, CaseIterable {
    case processLifecycle
    case fileReads
    case fileWrites
    case network
    case approvals
    case artifacts
}

public struct ObservedPolicyViolation: Sendable, Equatable, Codable {
    public let code: String
    public let boundary: ObservationBoundary
    public let detail: String

    public init(code: String, boundary: ObservationBoundary, detail: String) {
        self.code = code
        self.boundary = boundary
        self.detail = detail
    }
}

public struct BoundaryObservationReport: Sendable, Equatable, Codable {
    public let boundary: ObservationBoundary
    public let observerID: String
    public let productSourceID: String
    public let observerIsolated: Bool
    public let startMarkerRecorded: Bool
    public let endMarkerRecorded: Bool
    public let observedSequences: [UInt64]
    public let droppedEventsCount: Int
    public let collectorHealthy: Bool
    public let samplingActive: Bool
    public let unobservedChildProcesses: Int
    public let violations: [ObservedPolicyViolation]

    public init(
        boundary: ObservationBoundary,
        observerID: String,
        productSourceID: String,
        observerIsolated: Bool,
        startMarkerRecorded: Bool,
        endMarkerRecorded: Bool,
        observedSequences: [UInt64],
        droppedEventsCount: Int,
        collectorHealthy: Bool,
        samplingActive: Bool,
        unobservedChildProcesses: Int,
        violations: [ObservedPolicyViolation] = []
    ) {
        self.boundary = boundary
        self.observerID = observerID
        self.productSourceID = productSourceID
        self.observerIsolated = observerIsolated
        self.startMarkerRecorded = startMarkerRecorded
        self.endMarkerRecorded = endMarkerRecorded
        self.observedSequences = observedSequences
        self.droppedEventsCount = droppedEventsCount
        self.collectorHealthy = collectorHealthy
        self.samplingActive = samplingActive
        self.unobservedChildProcesses = unobservedChildProcesses
        self.violations = violations
    }
}

public enum ObservationSafetyVerdict: String, Sendable, Equatable, Codable {
    case completeNoViolations = "COMPLETE_NO_VIOLATIONS"
    case fail = "FAIL"
    case indeterminate = "INDETERMINATE"
}

public struct ObservationCompletenessReport: Sendable, Equatable, Codable {
    public let trialID: String
    public let verdict: ObservationSafetyVerdict
    public let violations: [ObservedPolicyViolation]
    public let unknownBoundaries: [ObservationBoundary]
    public let incompletenessReasons: [String]
    public let bundleDigest: String

    public init(
        trialID: String,
        verdict: ObservationSafetyVerdict,
        violations: [ObservedPolicyViolation],
        unknownBoundaries: [ObservationBoundary],
        incompletenessReasons: [String],
        bundleDigest: String
    ) {
        self.trialID = trialID
        self.verdict = verdict
        self.violations = violations
        self.unknownBoundaries = unknownBoundaries
        self.incompletenessReasons = incompletenessReasons
        self.bundleDigest = bundleDigest
    }
}

public enum IndependentObservationVerifier {
    private static let forbiddenDetailMarkers = [
        "sk-ant-",
        "Bearer ",
        "BEGIN PRIVATE KEY",
        "COOKIE=",
    ]

    public static func verify(
        trialID: String,
        requiredBoundaries: [ObservationBoundary],
        reports: [BoundaryObservationReport]
    ) throws -> ObservationCompletenessReport {
        guard !trialID.isEmpty,
              !trialID.utf8.contains(0),
              !requiredBoundaries.isEmpty else {
            throw StorageError.invalidInput
        }

        var reportsByBoundary: [ObservationBoundary: BoundaryObservationReport] = [:]
        for report in reports {
            guard reportsByBoundary.updateValue(report, forKey: report.boundary) == nil else {
                throw StorageError.invalidInput
            }
            for violation in report.violations {
                guard !violation.code.isEmpty,
                      !violation.detail.isEmpty,
                      !violation.detail.utf8.contains(0),
                      !containsSensitiveMarker(violation.detail) else {
                    throw StorageError.invalidInput
                }
            }
        }

        let uniqueRequired = Array(Set(requiredBoundaries)).sorted { $0.rawValue < $1.rawValue }
        var unknownBoundaries: [ObservationBoundary] = []
        var incompletenessReasons: [String] = []
        var allViolations: [ObservedPolicyViolation] = []

        for boundary in uniqueRequired {
            guard let report = reportsByBoundary[boundary] else {
                unknownBoundaries.append(boundary)
                incompletenessReasons.append("missing boundary \(boundary.rawValue)")
                continue
            }

            allViolations.append(contentsOf: report.violations)
            let issues = completenessIssues(for: report)
            if !issues.isEmpty {
                unknownBoundaries.append(boundary)
                incompletenessReasons.append(contentsOf: issues.map { "\(boundary.rawValue): \($0)" })
            }
        }

        let requiredSet = Set(uniqueRequired)
        for report in reports where !requiredSet.contains(report.boundary) {
            allViolations.append(contentsOf: report.violations)
        }

        let verdict: ObservationSafetyVerdict
        if !allViolations.isEmpty {
            verdict = .fail
        } else if !unknownBoundaries.isEmpty {
            verdict = .indeterminate
        } else {
            verdict = .completeNoViolations
        }

        let bundleDigestData = try canonicalSHA256(.object([
            ("domain", .string("oches.observation.bundle.v1")),
            ("trialID", .string(trialID)),
            ("verdict", .string(verdict.rawValue)),
            ("unknownBoundaries", .array(unknownBoundaries.map { .string($0.rawValue) })),
            ("incompletenessReasons", .array(incompletenessReasons.map(RawJSONValue.string))),
            ("violations", .array(allViolations.map {
                .object([
                    ("code", .string($0.code)),
                    ("boundary", .string($0.boundary.rawValue)),
                    ("detail", .string($0.detail)),
                ])
            })),
        ]))
        let bundleDigest = bundleDigestData.map { String(format: "%02x", $0) }.joined()

        return ObservationCompletenessReport(
            trialID: trialID,
            verdict: verdict,
            violations: allViolations,
            unknownBoundaries: unknownBoundaries,
            incompletenessReasons: incompletenessReasons,
            bundleDigest: bundleDigest
        )
    }

    private static func completenessIssues(for report: BoundaryObservationReport) -> [String] {
        var issues: [String] = []
        if report.observerID.isEmpty || report.observerID.utf8.elementsEqual(report.productSourceID.utf8) {
            issues.append("observer identity not independent from product source")
        }
        if !report.observerIsolated {
            issues.append("observer not isolated")
        }
        if !report.startMarkerRecorded {
            issues.append("missing start marker")
        }
        if !report.endMarkerRecorded {
            issues.append("missing end marker")
        }
        if !report.collectorHealthy {
            issues.append("collector unhealthy")
        }
        if report.samplingActive {
            issues.append("sampling active")
        }
        if report.droppedEventsCount != 0 {
            issues.append("dropped events (\(report.droppedEventsCount))")
        }
        if report.unobservedChildProcesses != 0 {
            issues.append("unobserved child processes (\(report.unobservedChildProcesses))")
        }
        if !report.observedSequences.isEmpty {
            let expected = (1...UInt64(report.observedSequences.count)).map { $0 }
            if report.observedSequences != expected {
                issues.append("sequence gap or duplicate")
            }
        }
        return issues
    }

    private static func containsSensitiveMarker(_ text: String) -> Bool {
        let lower = text.lowercased()
        for marker in forbiddenDetailMarkers {
            if lower.contains(marker.lowercased()) {
                return true
            }
        }
        return false
    }
}
