import Foundation

enum ArchitecturePattern: String, CaseIterable {
    case singleAgent, chaining, routing, parallelization, orchestratorWorkers, evaluatorOptimizer
}

enum ConstraintFact: Equatable {
    case boolean(Bool), integer(Int64), text(String)

    static func == (lhs: ConstraintFact, rhs: ConstraintFact) -> Bool {
        switch (lhs, rhs) {
        case (.boolean(let left), .boolean(let right)): return left == right
        case (.integer(let left), .integer(let right)): return left == right
        case (.text(let left), .text(let right)): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }
}

enum ConstraintPredicate: String { case equals, notEquals, atMost, atLeast }
struct RecommendationConstraint {
    let constraintID: String
    let subject: String
    let predicate: ConstraintPredicate
    let value: ConstraintFact
    let version: String
}
struct ConstraintAssessment {
    let constraintID: String
    let version: String
    let result: TemplateValidationResult
}
enum RecommendationConstraintError: Error { case invalidInput }

enum RecommendationConstraintEvaluator {
    static func evaluate(_ constraints: [RecommendationConstraint], facts: [String: ConstraintFact]) throws -> [ConstraintAssessment] {
        guard constraints.count <= 256, facts.count <= 1024 else { throw RecommendationConstraintError.invalidInput }
        func valid(_ value: String) -> Bool {
            value.utf8.count <= 128 && value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:-]*\z"#, options: .regularExpression) != nil
        }
        var seen = Set<Data>()
        for constraint in constraints {
            guard valid(constraint.constraintID), valid(constraint.subject), valid(constraint.version),
                  seen.insert(Data(constraint.constraintID.utf8)).inserted else { throw RecommendationConstraintError.invalidInput }
        }
        guard facts.keys.allSatisfy(valid) else { throw RecommendationConstraintError.invalidInput }
        return constraints.map { constraint in
            let result: TemplateValidationResult
            if let actual = facts[constraint.subject] {
                switch (constraint.predicate, actual, constraint.value) {
                case (.atMost, .integer(let value), .integer(let limit)): result = value <= limit ? .pass : .fail
                case (.atLeast, .integer(let value), .integer(let limit)): result = value >= limit ? .pass : .fail
                case (.equals, .boolean, .boolean), (.equals, .integer, .integer), (.equals, .text, .text):
                    result = actual == constraint.value ? .pass : .fail
                case (.notEquals, .boolean, .boolean), (.notEquals, .integer, .integer), (.notEquals, .text, .text):
                    result = actual != constraint.value ? .pass : .fail
                default: result = .unknown
                }
            } else { result = .unknown }
            return ConstraintAssessment(constraintID: constraint.constraintID, version: constraint.version, result: result)
        }
    }
}
