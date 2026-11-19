import Foundation

struct RecommendationCandidateAssessment {
    let pattern: ArchitecturePattern
    let requirements: TemplateValidationResult
    let reasons: [String]
}
struct RecommendationEvaluation {
    let proposal: ArchitectureProposal
    let assessments: [RecommendationCandidateAssessment]
    let capabilityOutcome: CapabilityGateOutcome
    let evidenceRefs: [RevisionRef]
    let uncertainties: [String]
}

struct RecommendationService {
    let profiles: AnalyzerProfileRepository

    func propose(profileID: String, profileRevision: RevisionRef, snapshot: CapabilitySnapshot,
                 requestedScope: CapabilityScope, registryVersions: [RevisionRef], constraints: [RecommendationConstraint],
                 requiredCapabilities: [CapabilityID], now: Int64) throws -> RecommendationEvaluation {
        guard now >= 0, snapshot.observedAt >= 0, snapshot.observedAt <= now,
              Set(requiredCapabilities).count == requiredCapabilities.count else { throw RecommendationConstraintError.invalidInput }
        let profile = try profiles.load(profileID: profileID, revision: profileRevision)
        let pins = try RecommendationVersionPins.capture(profile: profile, profileRevision: profileRevision,
            snapshot: snapshot, registryVersions: registryVersions, constraints: constraints, requiredCapabilities: requiredCapabilities)
        let gate = CapabilityEvaluator().evaluate(snapshot: snapshot, requestedScope: requestedScope, requiredCapabilities: requiredCapabilities)
        let candidates = try ArchitectureCandidateGenerator.generate(constraints: constraints)
        let assessments = candidates.map { candidate -> RecommendationCandidateAssessment in
            var failures: [String] = []
            var unknowns: [String] = []
            if candidate.structuralSupport == .fail { failures.append("pattern_unsupported_in_v1") }
            for constraint in candidate.constraints {
                if constraint.result == .fail { failures.append("constraint_failed:" + constraint.constraintID) }
                if constraint.result == .unknown { unknowns.append("constraint_unknown:" + constraint.constraintID) }
            }
            switch gate {
            case .supported: break
            case .unsupported: failures.append("required_capability_unsupported")
            case .unknown: unknowns.append("required_capability_unknown")
            case .stale: unknowns.append("capability_scope_stale")
            }
            if profile.state != .complete { unknowns.append("profile_incomplete") }
            let result: TemplateValidationResult = !failures.isEmpty ? .fail : (!unknowns.isEmpty ? .unknown : .pass)
            return RecommendationCandidateAssessment(pattern: candidate.pattern, requirements: result, reasons: failures + unknowns)
        }
        return RecommendationEvaluation(proposal: ArchitectureProposal(pins: pins, createdAt: now, candidates: candidates),
            assessments: assessments, capabilityOutcome: gate, evidenceRefs: [profileRevision],
            uncertainties: profile.uncertainties + ["registry_reference_lookup_pending", "policy_and_approval_unverified", "execution_not_authorized"])
    }
}
