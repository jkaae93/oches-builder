import Foundation

struct ArchitectureCandidate {
    let pattern: ArchitecturePattern
    let tasks: [String]
    let dependencies: [TaskDependency]
    let facts: [String: ConstraintFact]
    let constraints: [ConstraintAssessment]
    let structuralSupport: TemplateValidationResult
    let claim: String
    let evidenceRefs: [String]
    let ruleVersion: String
    let alternatives: [ArchitecturePattern]
    let uncertainties: [String]
}

enum ArchitectureCandidateGenerator {
    static let version = "1"

    static func generate(constraints: [RecommendationConstraint]) throws -> [ArchitectureCandidate] {
        try ArchitecturePattern.allCases.map { pattern in
            let tasks: [String]
            let pairs: [(String, String)]
            let concurrency: Int64
            let claim: String
            let supported: Bool
            switch pattern {
            case .singleAgent:
                tasks = ["work"]; pairs = []; concurrency = 1
                claim = "Single Agent is the simplest baseline; task suitability is not yet established."
                supported = true
            case .chaining:
                tasks = ["first", "second"]; pairs = [("first", "second")]; concurrency = 1
                claim = "Two ordered stages expose an explicit intermediate dependency."
                supported = true
            case .routing:
                tasks = ["route", "branch-a", "branch-b"]; pairs = [("route", "branch-a"), ("route", "branch-b")]; concurrency = 1
                claim = "Routing requires verified conditional selection; this skeleton is not an executable route."
                supported = false
            case .parallelization:
                tasks = ["worker-a", "worker-b", "aggregate"]; pairs = [("worker-a", "aggregate"), ("worker-b", "aggregate")]; concurrency = 2
                claim = "Two bounded workers precede aggregation; independence and isolation require evidence."
                supported = true
            case .orchestratorWorkers:
                tasks = ["coordinate", "worker-a", "worker-b", "aggregate"]
                pairs = [("coordinate", "worker-a"), ("coordinate", "worker-b"), ("worker-a", "aggregate"), ("worker-b", "aggregate")]
                concurrency = 2
                claim = "Coordination precedes bounded workers, followed by aggregation."
                supported = true
            case .evaluatorOptimizer:
                tasks = ["draft", "evaluate", "revise"]; pairs = [("draft", "evaluate"), ("evaluate", "revise")]; concurrency = 1
                claim = "The shown pass requires a separately verified bounded optimization-loop contract."
                supported = false
            }
            let dependencies = pairs.map { TaskDependency(predecessor: $0.0, successor: $0.1) }
            _ = try TaskDependencyValidator.validate(tasks: tasks, dependencies: dependencies, dataFlows: [])
            let facts: [String: ConstraintFact] = ["taskCount": .integer(Int64(tasks.count)),
                "maxConcurrency": .integer(concurrency), "pattern": .text(pattern.rawValue),
                "conditional": .boolean(pattern == .routing), "optimizationLoop": .boolean(pattern == .evaluatorOptimizer)]
            let results = try RecommendationConstraintEvaluator.evaluate(constraints, facts: facts)
            var uncertainties = ["profile_suitability_unknown", "capability_support_unknown", "policy_and_approval_unverified",
                "cost_unknown", "latency_unknown", "quality_unknown", "candidate_not_executable"]
            if !supported { uncertainties.append("v1_condition_or_loop_unsupported") }
            return ArchitectureCandidate(pattern: pattern, tasks: tasks, dependencies: dependencies, facts: facts,
                constraints: results, structuralSupport: supported ? .pass : .fail, claim: claim,
                evidenceRefs: ["rule:architecture-patterns:1", "ARC-03", "DESIGN_FINALIZATION:E1"], ruleVersion: version,
                alternatives: pattern == .singleAgent ? [] : [.singleAgent], uncertainties: uncertainties)
        }
    }
}
