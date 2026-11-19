import Foundation
import XCTest
@testable import OchesCore

final class ReleaseGateEvaluatorTests: XCTestCase {
    func testDenominatorIntegrityRejectsFalsePassClaims() throws {
        let partialPass = VerificationEvidenceRecord(
            id: "V-01",
            category: "runtime",
            layer: .unitAndContractTest,
            status: .pass,
            version: "0.1.0",
            environment: "macOS arm64",
            repeats: 3,
            passedCount: 2,
            denominator: 3,
            evidencePath: "docs/imp-12-scheduler-evidence.md"
        )
        XCTAssertThrowsError(try partialPass.validateIntegrity()) { error in
            guard case .invalidEvidenceClaim = error as? ReleaseGateError else {
                return XCTFail("Expected invalidEvidenceClaim")
            }
        }

        let zeroDenomPass = VerificationEvidenceRecord(
            id: "PERF-01",
            category: "perf",
            layer: .productGate,
            status: .pass,
            version: "0.1.0",
            environment: "macOS arm64",
            repeats: 0,
            passedCount: 0,
            denominator: 0,
            evidencePath: "docs/imp-22-release-readiness.md"
        )
        XCTAssertThrowsError(try zeroDenomPass.validateIntegrity())

        let productWithResidual = VerificationEvidenceRecord(
            id: "R-04",
            category: "provider",
            layer: .productGate,
            status: .pass,
            version: "0.1.0",
            environment: "macOS arm64",
            repeats: 1,
            passedCount: 1,
            denominator: 1,
            evidencePath: "docs/imp-15-claude-evidence.md",
            residualLimits: "Live external Provider API NOT RUN"
        )
        XCTAssertThrowsError(try productWithResidual.validateIntegrity())
    }

    func testPhaseGatesStayBlockedWhenProductGatesAreNotRunAndFailWhenAnyCaseFails() throws {
        let unitPass = VerificationEvidenceRecord(
            id: "V-01",
            category: "scheduler",
            layer: .unitAndContractTest,
            status: .pass,
            version: "0.1.0",
            environment: "Swift 6 / macOS arm64",
            repeats: 1,
            passedCount: 16,
            denominator: 16,
            evidencePath: "docs/imp-12-scheduler-evidence.md"
        )
        let notRunProductGate = VerificationEvidenceRecord(
            id: "LIVE-PROVIDER",
            category: "provider",
            layer: .productGate,
            status: .notRun,
            version: "0.1.0",
            environment: "macOS arm64 + Claude 2.1.296 / Codex 0.169.0",
            repeats: 0,
            passedCount: 0,
            denominator: 3,
            evidencePath: "docs/imp-22-release-readiness.md",
            residualLimits: "Live billable API calls intentionally not executed"
        )

        let blockedDecision = try ReleaseGateEvaluator.evaluatePhaseGate(
            phase: .phase1LocalCoreDesktop,
            requiredCases: [unitPass, notRunProductGate]
        )
        XCTAssertEqual(blockedDecision.verdict, .blocked)
        XCTAssertEqual(blockedDecision.passingCount, 1)
        XCTAssertEqual(blockedDecision.notRunOrIndeterminateCount, 1)
        XCTAssertTrue(blockedDecision.blockedReasons.first?.contains("LIVE-PROVIDER: NOT RUN") == true)

        let failingGate = VerificationEvidenceRecord(
            id: "A11Y-01",
            category: "a11y",
            layer: .productGate,
            status: .fail,
            version: "0.1.0",
            environment: "macOS VoiceOver",
            repeats: 1,
            passedCount: 0,
            denominator: 1,
            evidencePath: "docs/imp-22-release-readiness.md",
            residualLimits: "Keyboard trap observed"
        )
        let failDecision = try ReleaseGateEvaluator.evaluatePhaseGate(
            phase: .phase2ExtensionsAndPackaging,
            requiredCases: [unitPass, notRunProductGate, failingGate]
        )
        XCTAssertEqual(failDecision.verdict, .fail)
        XCTAssertEqual(failDecision.failingCount, 1)

        // All passing when all required cases cleanly pass
        let passedProduct = VerificationEvidenceRecord(
            id: "R-05",
            category: "runtime",
            layer: .productGate,
            status: .pass,
            version: "0.1.0",
            environment: "macOS arm64",
            repeats: 3,
            passedCount: 3,
            denominator: 3,
            evidencePath: "docs/imp-22-release-readiness.md"
        )
        let fullPass = try ReleaseGateEvaluator.evaluatePhaseGate(
            phase: .phase1LocalCoreDesktop,
            requiredCases: [unitPass, passedProduct]
        )
        XCTAssertEqual(fullPass.verdict, .pass)
        XCTAssertTrue(fullPass.blockedReasons.isEmpty)
    }

    func testPairedMockClaudeCodexComparisonPreservesRepeatDenominatorsAndUnknownCosts() throws {
        var entries: [ProviderComparisonEntry] = []
        for repeatIdx in 1...3 {
            entries.append(ProviderComparisonEntry(
                providerName: "mock",
                cliVersion: "mock-1.0",
                adapterVersion: "0.1.0",
                executionMode: .mockFixture,
                fixtureID: "RWT-01",
                attemptState: .succeeded,
                evaluationVerdict: .pass,
                costRecord: AttemptCostRecord(
                    recordID: "rec-mock-\(repeatIdx)",
                    attemptID: "mock-\(repeatIdx)",
                    workspaceID: "ws-comp",
                    providerName: "mock",
                    cliVersion: "mock-1.0",
                    adapterVersion: "0.1.0",
                    model: nil,
                    accountKind: .unknown,
                    status: .unknown,
                    currency: nil,
                    amountMicroUSD: nil,
                    uncachedInputTokens: nil,
                    cachedInputTokens: nil,
                    outputTokens: nil,
                    sourceBasis: "fixture",
                    rateCardVersion: nil,
                    incompleteReasons: ["mock fixture has no billing"],
                    attemptOutcome: .succeeded,
                    observedAt: Int64(1_000 + repeatIdx)
                ),
                streamTruncated: false,
                hasUnknownEvents: false
            ))
            entries.append(ProviderComparisonEntry(
                providerName: "claude",
                cliVersion: "2.1.296",
                adapterVersion: "0.1.0",
                executionMode: .controlledCLIFixture,
                fixtureID: "RWT-01",
                attemptState: .succeeded,
                evaluationVerdict: .pass,
                costRecord: AttemptCostRecord(
                    recordID: "rec-claude-\(repeatIdx)",
                    attemptID: "claude-\(repeatIdx)",
                    workspaceID: "ws-comp",
                    providerName: "claude",
                    cliVersion: "2.1.296",
                    adapterVersion: "0.1.0",
                    model: "claude-sonnet",
                    accountKind: .subscription,
                    status: .subscriptionIncluded,
                    currency: "USD",
                    amountMicroUSD: nil,
                    uncachedInputTokens: 120,
                    cachedInputTokens: 0,
                    outputTokens: 60,
                    sourceBasis: "claude-stream-fixture",
                    rateCardVersion: nil,
                    incompleteReasons: [],
                    attemptOutcome: .succeeded,
                    observedAt: Int64(2_000 + repeatIdx)
                ),
                streamTruncated: false,
                hasUnknownEvents: false
            ))
            entries.append(ProviderComparisonEntry(
                providerName: "codex",
                cliVersion: "0.169.0",
                adapterVersion: "0.1.0",
                executionMode: .controlledCLIFixture,
                fixtureID: "RWT-01",
                attemptState: .succeeded,
                evaluationVerdict: repeatIdx == 3 ? .fail : .pass,
                costRecord: AttemptCostRecord(
                    recordID: "rec-codex-\(repeatIdx)",
                    attemptID: "codex-\(repeatIdx)",
                    workspaceID: "ws-comp",
                    providerName: "codex",
                    cliVersion: "0.169.0",
                    adapterVersion: "0.1.0",
                    model: "gpt-5-codex",
                    accountKind: .unknown,
                    status: .unknown,
                    currency: nil,
                    amountMicroUSD: nil,
                    uncachedInputTokens: 100,
                    cachedInputTokens: 0,
                    outputTokens: 50,
                    sourceBasis: "codex-jsonl-fixture",
                    rateCardVersion: nil,
                    incompleteReasons: ["usage cost omitted by fixture"],
                    attemptOutcome: .succeeded,
                    observedAt: Int64(3_000 + repeatIdx)
                ),
                streamTruncated: false,
                hasUnknownEvents: false
            ))
        }

        let rows = ReleaseGateEvaluator.summarizePairedComparison(fixtureID: "RWT-01", entries: entries)
        XCTAssertEqual(rows.count, 3)

        let claude = try XCTUnwrap(rows.first { $0.providerName == "claude" })
        XCTAssertEqual(claude.repeats, 3)
        XCTAssertEqual(claude.passedCount, 3)
        XCTAssertEqual(claude.subscriptionIncludedCount, 3)
        XCTAssertFalse(claude.liveProviderVerified)

        let codex = try XCTUnwrap(rows.first { $0.providerName == "codex" })
        XCTAssertEqual(codex.repeats, 3)
        XCTAssertEqual(codex.passedCount, 2)
        XCTAssertEqual(codex.failedCount, 1)
        XCTAssertEqual(codex.costUnavailableCount, 3)
        XCTAssertNil(codex.confirmedTotalMicroUSD)
        XCTAssertFalse(codex.liveProviderVerified)
    }
}
