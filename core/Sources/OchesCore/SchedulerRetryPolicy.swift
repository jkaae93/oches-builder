import Foundation

enum SchedulerRetryReason { case runtimeFailure, evaluationFailure, manualInterruptedRecovery }
enum SchedulerRetryDecision: Equatable {
    case blocked
    case exhausted
    case waitUntil(Int64)
    case eligible(requiresNewAttempt: Bool, requiresNewApproval: Bool)
}

enum SchedulerRetryPolicy {
    static func evaluate(lastAttempt: ExecutionAttemptState, reason: SchedulerRetryReason,
                         retriesAlreadyReserved: Int, failedAt: Int64, now: Int64) throws -> SchedulerRetryDecision {
        guard (0...3).contains(retriesAlreadyReserved), failedAt >= 0, now >= 0 else { throw StorageError.invalidInput }
        guard now >= failedAt else { return .blocked }
        let allowed: Bool
        switch reason {
        case .runtimeFailure: allowed = lastAttempt == .failed
        case .evaluationFailure: allowed = lastAttempt == .succeeded
        case .manualInterruptedRecovery: allowed = lastAttempt == .interrupted
        }
        guard allowed else { return .blocked }
        guard retriesAlreadyReserved < 3 else { return .exhausted }
        let delay = Int64(min(60, 1 << retriesAlreadyReserved))
        guard failedAt <= Int64.max - delay else { throw StorageError.invalidInput }
        let next = failedAt + delay
        guard now >= next else { return .waitUntil(next) }
        return .eligible(requiresNewAttempt: true, requiresNewApproval: true)
    }
}
