import Foundation

public enum OracleCheckOutcome: Sendable, Equatable {
    case pass
    case fail(reason: String)
    case indeterminate(reason: String)
}

public struct EvaluationCriteriaSpec: Sendable, Equatable, Codable {
    public let criteriaID: String
    public let criteriaVersion: String
    public let evaluatorID: String
    public let evaluatorVersion: String
    public let policyVersion: UInt64
    public let requiredBoundaries: [ObservationBoundary]
    public let expectedArtifactDigests: [String: String]?
    public let requireHumanReview: Bool

    public init(
        criteriaID: String,
        criteriaVersion: String,
        evaluatorID: String,
        evaluatorVersion: String,
        policyVersion: UInt64,
        requiredBoundaries: [ObservationBoundary],
        expectedArtifactDigests: [String: String]? = nil,
        requireHumanReview: Bool = false
    ) {
        self.criteriaID = criteriaID
        self.criteriaVersion = criteriaVersion
        self.evaluatorID = evaluatorID
        self.evaluatorVersion = evaluatorVersion
        self.policyVersion = policyVersion
        self.requiredBoundaries = requiredBoundaries
        self.expectedArtifactDigests = expectedArtifactDigests
        self.requireHumanReview = requireHumanReview
    }
}

public struct EvaluationRunResult: Sendable, Equatable {
    public let record: EvaluationVerdictRecord
    public let observation: ObservationCompletenessReport
    public let manifestIntegrity: ManifestIntegrityResult
    public let humanReviewPending: Bool
    public let reasons: [String]
}

public enum TrialOutcomeStatus: String, Sendable, Equatable, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case indeterminate = "INDETERMINATE"
    case notRun = "NOT_RUN"
    case blocked = "BLOCKED"
}

public struct PairedTrialEntry: Sendable, Equatable, Codable {
    public let datasetVersion: String
    public let fixtureID: String
    public let repeatIndex: Int
    public let environmentDigest: String
    public let baselineStatus: TrialOutcomeStatus
    public let candidateStatus: TrialOutcomeStatus
    public let baselineViolations: Int
    public let candidateViolations: Int
    public let baselineObservationComplete: Bool
    public let candidateObservationComplete: Bool

    public init(
        datasetVersion: String,
        fixtureID: String,
        repeatIndex: Int,
        environmentDigest: String,
        baselineStatus: TrialOutcomeStatus,
        candidateStatus: TrialOutcomeStatus,
        baselineViolations: Int,
        candidateViolations: Int,
        baselineObservationComplete: Bool,
        candidateObservationComplete: Bool
    ) {
        self.datasetVersion = datasetVersion
        self.fixtureID = fixtureID
        self.repeatIndex = repeatIndex
        self.environmentDigest = environmentDigest
        self.baselineStatus = baselineStatus
        self.candidateStatus = candidateStatus
        self.baselineViolations = baselineViolations
        self.candidateViolations = candidateViolations
        self.baselineObservationComplete = baselineObservationComplete
        self.candidateObservationComplete = candidateObservationComplete
    }
}

public struct PairedComparisonSummary: Sendable, Equatable, Codable {
    public let datasetVersion: String
    public let totalScheduledPairs: Int
    public let bothPass: Int
    public let baselineOnlyPass: Int
    public let candidateOnlyPass: Int
    public let bothFail: Int
    public let incompletePairs: Int
    public let totalSafetyViolations: Int
    public let incompleteObservationTrials: Int
    public let validBatch: Bool
    public let invalidationReasons: [String]
}

public final class EvaluationEngine: @unchecked Sendable {
    public let store: SQLiteStore
    public let manifestStore: ArtifactManifestStore
    public let verdictStore: EvaluationVerdictStore
    public let gate: RuntimePrepareAndStartGate

    public init(
        store: SQLiteStore,
        manifestStore: ArtifactManifestStore,
        verdictStore: EvaluationVerdictStore,
        gate: RuntimePrepareAndStartGate
    ) {
        self.store = store
        self.manifestStore = manifestStore
        self.verdictStore = verdictStore
        self.gate = gate
    }

    public func evaluateAndRecord(
        evaluationID: String,
        trialID: String,
        runID: String,
        taskID: String,
        runtimeTaskID: String,
        attemptID: String,
        taskRevision: RevisionRef,
        manifestID: String,
        criteria: EvaluationCriteriaSpec,
        observations: [BoundaryObservationReport],
        oracleOutcome: OracleCheckOutcome = .pass,
        evaluatedAt: Int64
    ) throws -> EvaluationRunResult {
        guard gate.store === store,
              manifestStore.store === store,
              verdictStore.store === store else {
            throw StorageError.invalidInput
        }

        var reasons: [String] = []
        var attemptReady = false
        if let attempt = try? gate.fetchAttempt(attemptID: attemptID) {
            if attempt.workspaceID.utf8.elementsEqual(store.workspaceID.utf8)
                && attempt.runID.utf8.elementsEqual(runID.utf8)
                && attempt.taskID.utf8.elementsEqual(runtimeTaskID.utf8)
                && attempt.taskRevision == taskRevision
                && attempt.state == .succeeded {
                attemptReady = true
            } else {
                reasons.append("attempt identity mismatch or runtime state not Succeeded (\(attempt.state.rawValue))")
            }
        } else {
            reasons.append("attempt not found")
        }

        let manifestIntegrity: ManifestIntegrityResult
        var manifestDigest = "invalid"
        var validManifest: ArtifactManifestRecord?
        do {
            let integrity = try manifestStore.verifyManifestIntegrity(manifestID: manifestID)
            manifestIntegrity = integrity
            switch integrity {
            case .valid(let manifest):
                if manifest.workspaceID.utf8.elementsEqual(store.workspaceID.utf8)
                    && manifest.runID.utf8.elementsEqual(runID.utf8)
                    && manifest.taskID.utf8.elementsEqual(taskID.utf8)
                    && manifest.attemptID.utf8.elementsEqual(attemptID.utf8)
                    && manifest.taskRevision == taskRevision {
                    manifestDigest = manifest.manifestDigest
                    validManifest = manifest
                } else {
                    reasons.append("manifest identity or taskRevision mismatch")
                }
            case .invalid(let reason):
                if let stored = try? manifestStore.fetchManifest(manifestID: manifestID) {
                    manifestDigest = stored.manifestDigest
                }
                reasons.append("manifest invalid: \(reason)")
            }
        } catch {
            manifestIntegrity = .invalid(reason: "manifest unavailable")
            reasons.append("manifest unavailable")
        }

        let obsReport = try IndependentObservationVerifier.verify(
            trialID: trialID,
            requiredBoundaries: criteria.requiredBoundaries,
            reports: observations
        )
        reasons.append(contentsOf: obsReport.incompletenessReasons)

        var expectedFail = false
        var expectedIndeterminate = false
        if let expectedDigests = criteria.expectedArtifactDigests {
            if let manifest = validManifest {
                let byPath = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.relativePath, $0) })
                for (path, expectedDigest) in expectedDigests.sorted(by: { $0.key < $1.key }) {
                    guard let entry = byPath[path], entry.accessStatus == .collected, let actual = entry.blobDigest else {
                        expectedIndeterminate = true
                        reasons.append("missing expected artifact \(path)")
                        continue
                    }
                    if actual != expectedDigest {
                        expectedFail = true
                        reasons.append("artifact digest mismatch for \(path)")
                    }
                }
            } else {
                expectedIndeterminate = true
            }
        }

        var oracleFail = false
        var oracleIndeterminate = false
        switch oracleOutcome {
        case .pass:
            break
        case .fail(let reason):
            oracleFail = true
            reasons.append("oracle fail: \(reason)")
        case .indeterminate(let reason):
            oracleIndeterminate = true
            reasons.append("oracle indeterminate: \(reason)")
        }

        let verdict: EvaluationVerdict
        if obsReport.verdict == .fail || oracleFail || expectedFail {
            verdict = .fail
        } else if obsReport.verdict == .indeterminate
            || !attemptReady
            || validManifest == nil
            || expectedIndeterminate
            || oracleIndeterminate
            || criteria.requireHumanReview {
            verdict = .indeterminate
            if criteria.requireHumanReview {
                reasons.append("AUTO_MATCH_HUMAN_PENDING requires human review")
            }
        } else {
            verdict = .pass
        }

        let record = EvaluationVerdictRecord(
            evaluationID: evaluationID,
            workspaceID: store.workspaceID,
            runID: runID,
            taskID: taskID,
            taskRevision: taskRevision,
            attemptID: attemptID,
            artifactManifestID: manifestID,
            artifactManifestDigest: manifestDigest,
            criteriaID: criteria.criteriaID,
            criteriaVersion: criteria.criteriaVersion,
            evaluatorID: criteria.evaluatorID,
            evaluatorVersion: criteria.evaluatorVersion,
            verdict: verdict,
            policyVersion: criteria.policyVersion,
            evaluatedAt: evaluatedAt
        )
        try verdictStore.record(record)
        return EvaluationRunResult(
            record: record,
            observation: obsReport,
            manifestIntegrity: manifestIntegrity,
            humanReviewPending: criteria.requireHumanReview,
            reasons: reasons
        )
    }

    func evaluateAndApplyToScheduler(
        evaluationID: String,
        trialID: String,
        runID: String,
        revision: RevisionRef,
        taskID: String,
        currentInputPins: Data,
        attemptID: String,
        taskRevision: RevisionRef,
        manifestID: String,
        criteria: EvaluationCriteriaSpec,
        observations: [BoundaryObservationReport],
        oracleOutcome: OracleCheckOutcome = .pass,
        actorID: String,
        requestID: String,
        now: Int64
    ) throws -> (evaluation: EvaluationRunResult, transition: TransitionResult) {
        let runtimeTaskID = SchedulerRunRepository.scopedRuntimeTaskID(runID: runID, taskID: taskID)
        let evalResult = try evaluateAndRecord(
            evaluationID: evaluationID,
            trialID: trialID,
            runID: runID,
            taskID: taskID,
            runtimeTaskID: runtimeTaskID,
            attemptID: attemptID,
            taskRevision: taskRevision,
            manifestID: manifestID,
            criteria: criteria,
            observations: observations,
            oracleOutcome: oracleOutcome,
            evaluatedAt: now
        )
        let repository = SchedulerRunRepository(store: store)
        let transition = try repository.applyEvaluation(
            runID: runID,
            revision: revision,
            taskID: taskID,
            currentInputPins: currentInputPins,
            evaluationID: evaluationID,
            artifactManifestID: manifestID,
            artifactManifestDigest: evalResult.record.artifactManifestDigest,
            criteriaID: criteria.criteriaID,
            criteriaVersion: criteria.criteriaVersion,
            policyVersion: criteria.policyVersion,
            expectedVerdict: evalResult.record.verdict,
            actorID: actorID,
            requestID: requestID,
            now: now
        )
        return (evalResult, transition)
    }

    public static func aggregatePairedComparisons(
        expectedDatasetVersion: String,
        entries: [PairedTrialEntry]
    ) -> PairedComparisonSummary {
        struct PairKey: Hashable {
            let fixtureID: String
            let repeatIndex: Int
        }

        var invalidationReasons: [String] = []
        var seen = Set<PairKey>()
        var expectedEnvDigest: String?
        var bothPass = 0
        var baselineOnlyPass = 0
        var candidateOnlyPass = 0
        var bothFail = 0
        var incompletePairs = 0
        var totalSafetyViolations = 0
        var incompleteObservationTrials = 0

        for entry in entries {
            if entry.datasetVersion != expectedDatasetVersion {
                invalidationReasons.append("datasetVersion mismatch for \(entry.fixtureID)#\(entry.repeatIndex)")
            }
            if let env = expectedEnvDigest {
                if env != entry.environmentDigest {
                    invalidationReasons.append("environmentDigest mismatch for \(entry.fixtureID)#\(entry.repeatIndex)")
                }
            } else {
                expectedEnvDigest = entry.environmentDigest
            }
            let key = PairKey(fixtureID: entry.fixtureID, repeatIndex: entry.repeatIndex)
            if !seen.insert(key).inserted {
                invalidationReasons.append("duplicate paired entry for \(entry.fixtureID)#\(entry.repeatIndex)")
            }
            if entry.baselineViolations < 0 || entry.candidateViolations < 0 {
                invalidationReasons.append("negative violation count for \(entry.fixtureID)#\(entry.repeatIndex)")
            } else {
                totalSafetyViolations += entry.baselineViolations + entry.candidateViolations
            }
            if !entry.baselineObservationComplete {
                incompleteObservationTrials += 1
            }
            if !entry.candidateObservationComplete {
                incompleteObservationTrials += 1
            }

            let baselineDecided = (entry.baselineStatus == .pass || entry.baselineStatus == .fail) && entry.baselineObservationComplete
            let candidateDecided = (entry.candidateStatus == .pass || entry.candidateStatus == .fail) && entry.candidateObservationComplete

            guard baselineDecided && candidateDecided else {
                incompletePairs += 1
                continue
            }

            switch (entry.baselineStatus, entry.candidateStatus) {
            case (.pass, .pass): bothPass += 1
            case (.pass, .fail): baselineOnlyPass += 1
            case (.fail, .pass): candidateOnlyPass += 1
            case (.fail, .fail): bothFail += 1
            default: incompletePairs += 1
            }
        }

        return PairedComparisonSummary(
            datasetVersion: expectedDatasetVersion,
            totalScheduledPairs: entries.count,
            bothPass: bothPass,
            baselineOnlyPass: baselineOnlyPass,
            candidateOnlyPass: candidateOnlyPass,
            bothFail: bothFail,
            incompletePairs: incompletePairs,
            totalSafetyViolations: totalSafetyViolations,
            incompleteObservationTrials: incompleteObservationTrials,
            validBatch: invalidationReasons.isEmpty && !entries.isEmpty,
            invalidationReasons: invalidationReasons
        )
    }
}
