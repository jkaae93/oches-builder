import XCTest
@testable import OchesCore

final class SchedulerRetryPolicyTests: XCTestCase {
    func testBoundedBackoffAndNewAttemptApprovalRequirements() throws {
        for (count, delay) in [(0, 1), (1, 2), (2, 4)] {
            XCTAssertEqual(try SchedulerRetryPolicy.evaluate(lastAttempt: .failed, reason: .runtimeFailure,
                retriesAlreadyReserved: count, failedAt: 100, now: 100), .waitUntil(Int64(100 + delay)))
            XCTAssertEqual(try SchedulerRetryPolicy.evaluate(lastAttempt: .failed, reason: .runtimeFailure,
                retriesAlreadyReserved: count, failedAt: 100, now: Int64(100 + delay)),
                .eligible(requiresNewAttempt: true, requiresNewApproval: true))
        }
        XCTAssertEqual(try SchedulerRetryPolicy.evaluate(lastAttempt: .failed, reason: .runtimeFailure,
            retriesAlreadyReserved: 3, failedAt: 100, now: 200), .exhausted)
    }

    func testUncertainActiveAndCancelledAttemptsNeverBecomeAutomaticRetries() throws {
        for state in ExecutionAttemptState.allCases where state != .failed {
            XCTAssertEqual(try SchedulerRetryPolicy.evaluate(lastAttempt: state, reason: .runtimeFailure,
                retriesAlreadyReserved: 0, failedAt: 100, now: 200), .blocked)
        }
        XCTAssertEqual(try SchedulerRetryPolicy.evaluate(lastAttempt: .unknown, reason: .manualInterruptedRecovery,
            retriesAlreadyReserved: 0, failedAt: 100, now: 200), .blocked)
        XCTAssertEqual(try SchedulerRetryPolicy.evaluate(lastAttempt: .interrupted, reason: .manualInterruptedRecovery,
            retriesAlreadyReserved: 0, failedAt: 100, now: 200), .eligible(requiresNewAttempt: true, requiresNewApproval: true))
        XCTAssertEqual(try SchedulerRetryPolicy.evaluate(lastAttempt: .succeeded, reason: .evaluationFailure,
            retriesAlreadyReserved: 0, failedAt: 100, now: 200), .eligible(requiresNewAttempt: true, requiresNewApproval: true))
        XCTAssertEqual(try SchedulerRetryPolicy.evaluate(lastAttempt: .failed, reason: .runtimeFailure,
            retriesAlreadyReserved: 0, failedAt: 100, now: 99), .blocked)
        XCTAssertThrowsError(try SchedulerRetryPolicy.evaluate(lastAttempt: .failed, reason: .runtimeFailure,
            retriesAlreadyReserved: 4, failedAt: 100, now: 200))
        XCTAssertThrowsError(try SchedulerRetryPolicy.evaluate(lastAttempt: .failed, reason: .runtimeFailure,
            retriesAlreadyReserved: 0, failedAt: Int64.max, now: Int64.max))
    }
}
