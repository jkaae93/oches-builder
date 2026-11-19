import Foundation
import XCTest
@testable import OchesCore

final class ProviderAdaptersAndCostTests: XCTestCase {
    private func makeSnapshotAndScope(
        provider: String,
        installationID: String,
        cliVersion: String,
        accountRef: String,
        accountType: AccountKind,
        isolation: CapabilityStatus = .supported,
        resumeStatus: CapabilityStatus = .supported,
        basis: CapabilityEvidenceBasis = .verifiedInOches
    ) -> (CapabilitySnapshot, CapabilityScope) {
        let scope = CapabilityScope(
            installationID: installationID,
            executableIdentity: "sha256:\(provider)",
            cliVersion: cliVersion,
            adapterVersion: "0.1.0",
            osVersionArch: "macOS-26.4-arm64",
            accountRef: accountRef,
            accountType: accountType,
            workspaceID: "ws",
            workspaceLocationAuthority: "local",
            workspaceTrust: true,
            clientID: "desktop-1",
            clientKind: "desktop",
            negotiatedProtocolMajorMinor: "1.0",
            policyVersion: 1
        )
        let entries = CapabilityID.allCases.map { cap -> CapabilityEntry in
            let status: CapabilityStatus
            switch cap {
            case .authAccountIsolation: status = isolation
            case .runResume: status = resumeStatus
            default: status = .supported
            }
            return CapabilityEntry(capabilityID: cap, status: status, basis: basis, evidenceRef: "test", observedAt: 100)
        }
        return (CapabilitySnapshot(snapshotID: "snap-\(provider)", scope: scope, entries: entries, observedAt: 100), scope)
    }

    private func makeTempStubExecutable(dir: URL, name: String, scriptBody: String) throws -> URL {
        let scriptURL = dir.appendingPathComponent(name)
        try Data(scriptBody.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    func testCostAccountingFiveStatesCacheOverlapDeduplicationMultiCurrencyAndRevisionsV20() throws {
        let dir = try makeTempDirectory("cost-v20-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let engine = try CostAccountingEngine(store: store)

        let rateCard = VerifiedRateCard(
            providerName: "codex", model: "gpt-5", currency: "USD", effectiveAt: 100, rateCardVersion: "rc-1",
            uncachedInputMicroUSDPerMillion: 2_000_000, cachedInputMicroUSDPerMillion: 500_000, outputMicroUSDPerMillion: 10_000_000,
            missingComponents: ["toolCostsNotIncluded"]
        )

        // 1. Cache included vs separate vs invalid cached > total
        let includedUsage = CostAccountingEngine.consolidateUsage([
            UsageSampleEvent(eventID: "e1", semantics: .cumulative, inputTokens: 1_000_000, cachedInputTokens: 400_000, outputTokens: 100_000, inputSemantics: .cachedIncludedInTotalInput),
            UsageSampleEvent(eventID: "e1", semantics: .cumulative, inputTokens: 1_000_000, cachedInputTokens: 400_000, outputTokens: 100_000, inputSemantics: .cachedIncludedInTotalInput),
        ])
        XCTAssertEqual(includedUsage?.uncachedInput, 600_000)
        XCTAssertEqual(includedUsage?.cachedInput, 400_000)
        XCTAssertEqual(includedUsage?.output, 100_000)

        let separateUsage = CostAccountingEngine.consolidateUsage([
            UsageSampleEvent(eventID: "i1", semantics: .incremental, inputTokens: 200_000, cachedInputTokens: 100_000, outputTokens: 50_000, inputSemantics: .cachedSeparateFromUncachedInput),
            UsageSampleEvent(eventID: "i2", semantics: .incremental, inputTokens: 300_000, cachedInputTokens: 50_000, outputTokens: 25_000, inputSemantics: .cachedSeparateFromUncachedInput),
            UsageSampleEvent(eventID: "i2", semantics: .incremental, inputTokens: 300_000, cachedInputTokens: 50_000, outputTokens: 25_000, inputSemantics: .cachedSeparateFromUncachedInput),
        ])
        XCTAssertEqual(separateUsage?.uncachedInput, 500_000)
        XCTAssertEqual(separateUsage?.cachedInput, 150_000)
        XCTAssertEqual(separateUsage?.output, 75_000)

        // Impossible cached > total -> nil (-> UNKNOWN)
        XCTAssertNil(CostAccountingEngine.consolidateUsage([
            UsageSampleEvent(eventID: "bad", semantics: .cumulative, inputTokens: 100, cachedInputTokens: 150, outputTokens: 10, inputSemantics: .cachedIncludedInTotalInput),
        ]))

        // Conflicting duplicate eventID or mixed cumulative/incremental -> nil
        XCTAssertNil(CostAccountingEngine.consolidateUsage([
            UsageSampleEvent(eventID: "dup", semantics: .incremental, inputTokens: 100, cachedInputTokens: 0, outputTokens: 10, inputSemantics: .cachedSeparateFromUncachedInput),
            UsageSampleEvent(eventID: "dup", semantics: .incremental, inputTokens: 200, cachedInputTokens: 0, outputTokens: 10, inputSemantics: .cachedSeparateFromUncachedInput),
        ]))
        XCTAssertNil(CostAccountingEngine.consolidateUsage([
            UsageSampleEvent(eventID: "m1", semantics: .cumulative, inputTokens: 100, cachedInputTokens: 0, outputTokens: 10, inputSemantics: .cachedIncludedInTotalInput),
            UsageSampleEvent(eventID: "m2", semantics: .incremental, inputTokens: 100, cachedInputTokens: 0, outputTokens: 10, inputSemantics: .cachedIncludedInTotalInput),
        ]))

        // 2. Rate-table calculation: (600k * $2 + 400k * $0.5 + 100k * $10) = $1.2 + $0.2 + $1.0 = $2.40 = 2_400_000 microUSD
        let est = CostAccountingEngine.computeRateTableEstimate(
            accountKind: .apiKey,
            events: [UsageSampleEvent(eventID: "e1", semantics: .cumulative, inputTokens: 1_000_000, cachedInputTokens: 400_000, outputTokens: 100_000, inputSemantics: .cachedIncludedInTotalInput)],
            rateCard: rateCard
        )
        XCTAssertEqual(est.status, .rateTableEstimate)
        XCTAssertEqual(est.amountMicroUSD, 2_400_000)
        XCTAssertEqual(est.incompleteReasons, ["toolCostsNotIncluded"])

        // Subscription NEVER coerces to 0
        let subEst = CostAccountingEngine.computeRateTableEstimate(
            accountKind: .subscription,
            events: [UsageSampleEvent(eventID: "e1", semantics: .cumulative, inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 100_000, inputSemantics: .cachedIncludedInTotalInput)],
            rateCard: rateCard
        )
        XCTAssertEqual(subEst.status, .subscriptionIncluded)
        XCTAssertNil(subEst.amountMicroUSD)

        // 3. Persistence forbids setting numeric 0 for UNKNOWN or SUBSCRIPTION_INCLUDED
        let badZeroUnknown = AttemptCostRecord(
            recordID: "rec-bad", attemptID: "att-bad", workspaceID: "ws", providerName: "claude",
            cliVersion: "2.1.296", adapterVersion: "0.1.0", model: nil, accountKind: .apiKey,
            status: .unknown, currency: "USD", amountMicroUSD: 0,
            uncachedInputTokens: nil, cachedInputTokens: nil, outputTokens: nil,
            sourceBasis: "bad", rateCardVersion: nil, incompleteReasons: ["missing"], attemptOutcome: .failed, observedAt: 100
        )
        XCTAssertThrowsError(try engine.recordAttemptCost(badZeroUnknown)) { XCTAssertEqual($0 as? StorageError, .invalidInput) }

        // 4. Immutable revision append for post-hoc billing adjustment
        let rev1 = AttemptCostRecord(
            recordID: "rec-1", attemptID: "att-1", workspaceID: "ws", providerName: "claude",
            cliVersion: "2.1.296", adapterVersion: "0.1.0", model: "claude-sonnet", accountKind: .apiKey,
            status: .providerReportedEstimate, currency: "USD", amountMicroUSD: 1_500_000,
            uncachedInputTokens: 1000, cachedInputTokens: 0, outputTokens: 500,
            sourceBasis: "stream-json estimate", rateCardVersion: nil, incompleteReasons: [], attemptOutcome: .succeeded, observedAt: 100, revision: 1
        )
        let rev2 = AttemptCostRecord(
            recordID: "rec-2", attemptID: "att-1", workspaceID: "ws", providerName: "claude",
            cliVersion: "2.1.296", adapterVersion: "0.1.0", model: "claude-sonnet", accountKind: .apiKey,
            status: .authoritativeBilling, currency: "USD", amountMicroUSD: 1_550_000,
            uncachedInputTokens: 1000, cachedInputTokens: 0, outputTokens: 500,
            sourceBasis: "official invoice", rateCardVersion: nil, incompleteReasons: [], attemptOutcome: .succeeded, observedAt: 200, revision: 2
        )
        try engine.recordAttemptCost(rev1)
        try engine.recordAttemptCost(rev2)
        XCTAssertEqual(try engine.listCostHistory(attemptID: "att-1").map(\.revision), [1, 2])
        XCTAssertEqual(try engine.latestCostRecord(attemptID: "att-1")?.status, .authoritativeBilling)
        XCTAssertEqual(try engine.latestCostRecord(attemptID: "att-1")?.amountMicroUSD, 1_550_000)

        // 5. Aggregation across currencies & missing usage
        let eurRecord = AttemptCostRecord(
            recordID: "rec-eur", attemptID: "att-eur", workspaceID: "ws", providerName: "codex",
            cliVersion: "0.169.0", adapterVersion: "0.1.0", model: "gpt-5", accountKind: .apiKey,
            status: .authoritativeBilling, currency: "EUR", amountMicroUSD: 500_000,
            uncachedInputTokens: 100, cachedInputTokens: 0, outputTokens: 50,
            sourceBasis: "invoice", rateCardVersion: nil, incompleteReasons: [], attemptOutcome: .succeeded, observedAt: 201, revision: 1
        )
        let unknownFailed = AttemptCostRecord(
            recordID: "rec-unk", attemptID: "att-unk", workspaceID: "ws", providerName: "claude",
            cliVersion: "2.1.296", adapterVersion: "0.1.0", model: nil, accountKind: .apiKey,
            status: .unknown, currency: nil, amountMicroUSD: nil,
            uncachedInputTokens: nil, cachedInputTokens: nil, outputTokens: nil,
            sourceBasis: "failed before usage", rateCardVersion: nil, incompleteReasons: ["usage omitted on failure"], attemptOutcome: .failed, observedAt: 202, revision: 1
        )
        let multiCurr = CostAccountingEngine.aggregate(records: [rev2, eurRecord])
        XCTAssertTrue(multiCurr.currencyConflict)
        XCTAssertNil(multiCurr.confirmedTotalMicroUSD)

        let withUnknown = CostAccountingEngine.aggregate(records: [rev2, unknownFailed])
        XCTAssertFalse(withUnknown.currencyConflict)
        XCTAssertEqual(withUnknown.unknownCount, 1)
        XCTAssertNil(withUnknown.confirmedTotalMicroUSD)
        XCTAssertEqual(withUnknown.knownSubtotalMicroUSD, 1_550_000)

        let allAuthoritative = CostAccountingEngine.aggregate(records: [rev2])
        XCTAssertEqual(allAuthoritative.confirmedTotalMicroUSD, 1_550_000)

        // 6. Fail-closed budget gate (E4)
        XCTAssertEqual(
            CostAccountingEngine.evaluateBudgetGate(accountKind: .subscription, maxBudgetMicroUSD: 5_000_000, providerSupportsHardBudgetCap: false, allowUnenforcedBudgetWithExplicitUserBounds: true),
            .blocked(reason: "provider hard monetary budget cap is not enforced for subscription accounts")
        )
        XCTAssertEqual(
            CostAccountingEngine.evaluateBudgetGate(accountKind: .apiKey, maxBudgetMicroUSD: 5_000_000, providerSupportsHardBudgetCap: true, allowUnenforcedBudgetWithExplicitUserBounds: false),
            .allow(enforcedByProvider: true, maxBudgetMicroUSD: 5_000_000)
        )
    }

    func testClaudeCodeAdapterGatesStreamJSONParsingBackgroundExitAndControlledSubprocess() throws {
        let dir = try makeTempDirectory("claude-adapter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stubScript = try makeTempStubExecutable(
            dir: dir,
            name: "claude-stub.sh",
            scriptBody: """
            #!/bin/sh
            echo '{"type":"system","subtype":"init","session_id":"sess-stub-1"}'
            echo '{"type":"assistant","message":{"model":"claude-sonnet-4"},"summary":"ok token sk-ant-secret123"}'
            echo '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-stub-1","total_cost_usd":0.42,"usage":{"input_tokens":1200,"cache_read_input_tokens":300,"output_tokens":450}}'
            exit 0
            """
        )

        let installation = ProviderInstallation(
            installationID: "inst-claude", providerName: "claude",
            executablePath: stubScript.path, executableSHA256: try ProviderRegistryStore.computeExecutableSHA256(at: stubScript),
            cliVersion: "2.1.296", detectedAt: 100, sourceBasis: "stub"
        )
        let apiAccount = AccountReference(
            accountRef: "acct-api", providerName: "claude", installationID: "inst-claude",
            accountKind: .apiKey, authState: .authenticated, observedAt: 100
        )
        let subAccount = AccountReference(
            accountRef: "acct-sub", providerName: "claude", installationID: "inst-claude",
            accountKind: .subscription, authState: .authenticated, observedAt: 100
        )
        let (snapAPI, scopeAPI) = makeSnapshotAndScope(
            provider: "claude", installationID: "inst-claude", cliVersion: "2.1.296",
            accountRef: "acct-api", accountType: .apiKey
        )
        let (snapSub, scopeSub) = makeSnapshotAndScope(
            provider: "claude", installationID: "inst-claude", cliVersion: "2.1.296",
            accountRef: "acct-sub", accountType: .subscription
        )

        // 1. Forbidden flag, untrusted workspace, unsupported CLI, documented-only cap, missing approvals, isolation, resume from Unknown, subscription cap
        XCTAssertThrowsError(try ClaudeCodeAdapter.buildInvocationPlan(ClaudeInvocationRequest(
            attemptID: "a1", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: false,
            installation: installation, account: apiAccount, snapshot: snapAPI, requestedScope: scopeAPI,
            promptDigest: "d", promptText: "hi", maxBudgetMicroUSD: 1_000_000,
            executionApprovalVerified: true, transferApprovalVerified: true
        ))) { XCTAssertEqual($0 as? ProviderAdapterError, .untrustedWorkspace) }

        XCTAssertThrowsError(try ClaudeCodeAdapter.buildInvocationPlan(ClaudeInvocationRequest(
            attemptID: "a1", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: true,
            installation: installation, account: apiAccount, snapshot: snapAPI, requestedScope: scopeAPI,
            promptDigest: "d", promptText: "hi", extraFlags: ["--dangerously-skip-permissions"], maxBudgetMicroUSD: 1_000_000,
            executionApprovalVerified: true, transferApprovalVerified: true
        ))) { XCTAssertEqual($0 as? ProviderAdapterError, .forbiddenBypassFlag("--dangerously-skip-permissions")) }

        XCTAssertThrowsError(try ClaudeCodeAdapter.buildInvocationPlan(ClaudeInvocationRequest(
            attemptID: "a1", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: true,
            installation: installation, account: apiAccount, snapshot: snapAPI, requestedScope: scopeAPI,
            promptDigest: "d", promptText: "hi", maxBudgetMicroUSD: 1_000_000,
            resumeSessionID: "sess-1", previousAttemptState: .unknown,
            executionApprovalVerified: true, transferApprovalVerified: true
        ))) {
            guard case .resumeRejected = $0 as? ProviderAdapterError else { return XCTFail("Expected resumeRejected") }
        }

        XCTAssertThrowsError(try ClaudeCodeAdapter.buildInvocationPlan(ClaudeInvocationRequest(
            attemptID: "a1", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: true,
            installation: installation, account: subAccount, snapshot: snapSub, requestedScope: scopeSub,
            promptDigest: "d", promptText: "hi", maxBudgetMicroUSD: 1_000_000,
            executionApprovalVerified: true, transferApprovalVerified: true
        ))) {
            guard case .budgetBlocked = $0 as? ProviderAdapterError else { return XCTFail("Expected budgetBlocked for subscription cap") }
        }

        let (docSnap, docScope) = makeSnapshotAndScope(
            provider: "claude", installationID: "inst-claude", cliVersion: "2.1.296",
            accountRef: "acct-api", accountType: .apiKey, basis: .documented
        )
        XCTAssertThrowsError(try ClaudeCodeAdapter.buildInvocationPlan(ClaudeInvocationRequest(
            attemptID: "a1", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: true,
            installation: installation, account: apiAccount, snapshot: docSnap, requestedScope: docScope,
            promptDigest: "d", promptText: "hi", maxBudgetMicroUSD: 1_000_000,
            executionApprovalVerified: true, transferApprovalVerified: true
        ))) {
            guard case .capabilityBlocked = $0 as? ProviderAdapterError else { return XCTFail("Expected capabilityBlocked for documented-only") }
        }

        // 2. Valid invocation plan -> controlled stub subprocess execution -> parse & reconcile
        let plan = try ClaudeCodeAdapter.buildInvocationPlan(ClaudeInvocationRequest(
            attemptID: "att-claude-1", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: true,
            installation: installation, account: apiAccount, snapshot: snapAPI, requestedScope: scopeAPI,
            promptDigest: "dig-1", promptText: "analyze", allowedTools: ["Read"], maxBudgetMicroUSD: 1_500_000,
            executionApprovalVerified: true, transferApprovalVerified: true
        ))
        XCTAssertTrue(plan.arguments.contains("--max-budget-usd"))
        XCTAssertTrue(plan.arguments.contains("1.50"))
        XCTAssertTrue(plan.budgetEnforcedByProvider)

        let proc = try ClaudeCodeAdapter.runControlledSubprocess(plan: plan)
        XCTAssertEqual(proc.exitCode, 0)
        let parsed = ClaudeCodeAdapter.parseStreamJSON(proc.stdout, streamEndedCleanly: true)
        XCTAssertEqual(parsed.sessionID, "sess-stub-1")
        XCTAssertEqual(parsed.model, "claude-sonnet-4")
        XCTAssertEqual(parsed.providerReportedCostMicroUSD, 420_000)
        XCTAssertTrue(parsed.redactionApplied)
        XCTAssertFalse(parsed.events.map(\.summary).joined().contains("sk-ant-secret123"))

        let outcome = ClaudeCodeAdapter.reconcileOutcome(exitCode: proc.exitCode, timedOut: false, cancelRequested: false, parseResult: parsed)
        XCTAssertEqual(outcome, .succeeded)

        let costRec = ClaudeCodeAdapter.buildCostRecord(
            recordID: "c-1", attemptID: "att-claude-1", workspaceID: "ws", cliVersion: "2.1.296",
            accountKind: .apiKey, parseResult: parsed, attemptOutcome: outcome, rateCard: nil, observedAt: 100
        )
        XCTAssertEqual(costRec.status, .providerReportedEstimate)
        XCTAssertEqual(costRec.amountMicroUSD, 420_000)

        // 3. V-06: exit 0 with truncated stream, missing terminal result, or active background task NEVER becomes Succeeded
        let missingResult = ClaudeCodeAdapter.parseStreamJSON("{\"type\":\"system\",\"subtype\":\"init\"}\n", streamEndedCleanly: true)
        XCTAssertEqual(ClaudeCodeAdapter.reconcileOutcome(exitCode: 0, timedOut: false, cancelRequested: false, parseResult: missingResult), .unknown)

        let truncated = ClaudeCodeAdapter.parseStreamJSON("{\"type\":\"result\",\"is_error\":false}\n{\"broken", streamEndedCleanly: false)
        XCTAssertTrue(truncated.streamTruncated)
        XCTAssertEqual(ClaudeCodeAdapter.reconcileOutcome(exitCode: 0, timedOut: false, cancelRequested: false, parseResult: truncated), .unknown)

        let bgPending = ClaudeCodeAdapter.parseStreamJSON("{\"type\":\"background_task\",\"status\":\"running\"}\n{\"type\":\"result\",\"is_error\":false}\n", streamEndedCleanly: true)
        XCTAssertTrue(bgPending.backgroundTasksPending)
        XCTAssertEqual(ClaudeCodeAdapter.reconcileOutcome(exitCode: 0, timedOut: false, cancelRequested: false, parseResult: bgPending), .unknown)

        let unknownEvt = ClaudeCodeAdapter.parseStreamJSON("{\"type\":\"future_vendor_event\"}\n{\"type\":\"result\",\"is_error\":false}\n", streamEndedCleanly: true)
        XCTAssertTrue(unknownEvt.hasUnknownEvents)
    }

    func testCodexCLIAdapterForbidsTrustFlagsParsesJSONLAndComparesWithMockAndClaude() throws {
        let dir = try makeTempDirectory("codex-adapter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stubScript = try makeTempStubExecutable(
            dir: dir,
            name: "codex-stub.sh",
            scriptBody: """
            #!/bin/sh
            echo '{"type":"thread.started","thread_id":"th-1"}'
            echo '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
            echo '{"type":"turn.completed","model":"gpt-5","usage":{"input_tokens":100000,"cached_input_tokens":20000,"output_tokens":10000}}'
            exit 0
            """
        )

        let installation = ProviderInstallation(
            installationID: "inst-codex", providerName: "codex",
            executablePath: stubScript.path, executableSHA256: try ProviderRegistryStore.computeExecutableSHA256(at: stubScript),
            cliVersion: "0.169.0", detectedAt: 100, sourceBasis: "stub"
        )
        let apiAccount = AccountReference(
            accountRef: "acct-codex-api", providerName: "codex", installationID: "inst-codex",
            accountKind: .apiKey, authState: .authenticated, observedAt: 100
        )
        let (snap, scope) = makeSnapshotAndScope(
            provider: "codex", installationID: "inst-codex", cliVersion: "0.169.0",
            accountRef: "acct-codex-api", accountType: .apiKey
        )

        // 1. Forbidden --trust and bypass flags
        for forbidden in ["--trust", "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust", "--approve-for-me", "-s=danger-full-access"] {
            XCTAssertThrowsError(try CodexCLIAdapter.buildInvocationPlan(CodexInvocationRequest(
                attemptID: "cx-bad", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: true,
                installation: installation, account: apiAccount, snapshot: snap, requestedScope: scope,
                promptDigest: "d", promptText: "hi", extraFlags: [forbidden],
                allowUnenforcedBudgetWithExplicitUserBounds: true,
                executionApprovalVerified: true, transferApprovalVerified: true
            ))) {
                guard case .forbiddenBypassFlag = $0 as? ProviderAdapterError else {
                    return XCTFail("Expected forbiddenBypassFlag for \(forbidden)")
                }
            }
        }

        // Requesting monetary spend cap on codex exec fails closed (no hard cap enforcement)
        XCTAssertThrowsError(try CodexCLIAdapter.buildInvocationPlan(CodexInvocationRequest(
            attemptID: "cx-cap", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: true,
            installation: installation, account: apiAccount, snapshot: snap, requestedScope: scope,
            promptDigest: "d", promptText: "hi", maxBudgetMicroUSD: 1_000_000,
            executionApprovalVerified: true, transferApprovalVerified: true
        ))) {
            guard case .budgetBlocked = $0 as? ProviderAdapterError else { return XCTFail("Expected budgetBlocked") }
        }

        // 2. Valid Codex plan -> controlled stub execution -> JSONL parse & rate-table cost
        let plan = try CodexCLIAdapter.buildInvocationPlan(CodexInvocationRequest(
            attemptID: "att-codex-1", workspaceID: "ws", workspacePath: dir.path, workspaceTrusted: true,
            installation: installation, account: apiAccount, snapshot: snap, requestedScope: scope,
            promptDigest: "dig-1", promptText: "analyze", sandboxMode: .readOnly,
            allowUnenforcedBudgetWithExplicitUserBounds: true,
            executionApprovalVerified: true, transferApprovalVerified: true
        ))
        XCTAssertFalse(plan.arguments.contains("--trust"))
        XCTAssertTrue(plan.arguments.contains("--ephemeral"))
        XCTAssertFalse(plan.budgetEnforcedByProvider)

        let proc = try ClaudeCodeAdapter.runControlledSubprocess(plan: plan)
        XCTAssertEqual(proc.exitCode, 0)
        let parsed = CodexCLIAdapter.parseJSONL(proc.stdout, streamEndedCleanly: true)
        XCTAssertEqual(parsed.threadID, "th-1")
        XCTAssertTrue(parsed.turnCompleted)

        let outcome = CodexCLIAdapter.reconcileOutcome(exitCode: proc.exitCode, timedOut: false, cancelRequested: false, parseResult: parsed)
        XCTAssertEqual(outcome, .succeeded)

        // Without rate card -> UNKNOWN (amountMicroUSD == nil)
        let noRateCost = CodexCLIAdapter.buildCostRecord(
            recordID: "cx-unk", attemptID: "att-codex-1", workspaceID: "ws", cliVersion: "0.169.0",
            accountKind: .apiKey, parseResult: parsed, attemptOutcome: outcome, rateCard: nil, observedAt: 100
        )
        XCTAssertEqual(noRateCost.status, .unknown)
        XCTAssertNil(noRateCost.amountMicroUSD)

        // With verified rate card -> RATE_TABLE_ESTIMATE: uncached 80k * $2 + cached 20k * $0.5 + output 10k * $10 = 160k + 10k + 100k = 270_000 microUSD
        let rateCard = VerifiedRateCard(
            providerName: "codex", model: "gpt-5", currency: "USD", effectiveAt: 100, rateCardVersion: "rc-codex-1",
            uncachedInputMicroUSDPerMillion: 2_000_000, cachedInputMicroUSDPerMillion: 500_000, outputMicroUSDPerMillion: 10_000_000
        )
        let codexCost = CodexCLIAdapter.buildCostRecord(
            recordID: "cx-est", attemptID: "att-codex-1", workspaceID: "ws", cliVersion: "0.169.0",
            accountKind: .apiKey, parseResult: parsed, attemptOutcome: outcome, rateCard: rateCard, observedAt: 100
        )
        XCTAssertEqual(codexCost.status, .rateTableEstimate)
        XCTAssertEqual(codexCost.amountMicroUSD, 270_000)

        // Truncated JSONL or missing turn.completed with exit 0 -> Unknown
        let missingTurn = CodexCLIAdapter.parseJSONL("{\"type\":\"thread.started\",\"thread_id\":\"th-2\"}\n", streamEndedCleanly: true)
        XCTAssertEqual(CodexCLIAdapter.reconcileOutcome(exitCode: 0, timedOut: false, cancelRequested: false, parseResult: missingTurn), .unknown)

        // 3. Cross-provider comparison harness (Mock + Claude + Codex) explicitly keeps liveProviderVerified == false
        let mockCost = AttemptCostRecord(
            recordID: "mock-cost", attemptID: "att-mock", workspaceID: "ws", providerName: "mock",
            cliVersion: "1.0.0", adapterVersion: "0.1.0", model: nil, accountKind: .unknown,
            status: .unknown, currency: nil, amountMicroUSD: nil,
            uncachedInputTokens: nil, cachedInputTokens: nil, outputTokens: nil,
            sourceBasis: "mock fixture", rateCardVersion: nil, incompleteReasons: ["mock adapter"], attemptOutcome: .succeeded, observedAt: 100
        )
        let claudeSampleCost = AttemptCostRecord(
            recordID: "cl-cost", attemptID: "att-claude", workspaceID: "ws", providerName: "claude",
            cliVersion: "2.1.296", adapterVersion: "0.1.0", model: "claude-sonnet-4", accountKind: .apiKey,
            status: .providerReportedEstimate, currency: "USD", amountMicroUSD: 420_000,
            uncachedInputTokens: 1200, cachedInputTokens: 300, outputTokens: 450,
            sourceBasis: "claude stub", rateCardVersion: nil, incompleteReasons: [], attemptOutcome: .succeeded, observedAt: 100
        )
        let report = ProviderComparisonHarness.buildReport(fixtureID: "RWT-01", entries: [
            ProviderComparisonEntry(providerName: "mock", cliVersion: "1.0.0", adapterVersion: "0.1.0", executionMode: .mockFixture, fixtureID: "RWT-01", attemptState: .succeeded, evaluationVerdict: .pass, costRecord: mockCost, streamTruncated: false, hasUnknownEvents: false),
            ProviderComparisonEntry(providerName: "claude", cliVersion: "2.1.296", adapterVersion: "0.1.0", executionMode: .controlledCLIFixture, fixtureID: "RWT-01", attemptState: .succeeded, evaluationVerdict: .pass, costRecord: claudeSampleCost, streamTruncated: false, hasUnknownEvents: false),
            ProviderComparisonEntry(providerName: "codex", cliVersion: "0.169.0", adapterVersion: "0.1.0", executionMode: .controlledCLIFixture, fixtureID: "RWT-01", attemptState: outcome, evaluationVerdict: .pass, costRecord: codexCost, streamTruncated: parsed.streamTruncated, hasUnknownEvents: parsed.hasUnknownEvents),
        ])
        XCTAssertFalse(report.liveProviderVerified)
        XCTAssertEqual(report.costSummaryByProvider["claude"]?.knownSubtotalMicroUSD, 420_000)
        XCTAssertEqual(report.costSummaryByProvider["codex"]?.knownSubtotalMicroUSD, 270_000)
        XCTAssertEqual(report.costSummaryByProvider["mock"]?.unknownCount, 1)
    }
}
