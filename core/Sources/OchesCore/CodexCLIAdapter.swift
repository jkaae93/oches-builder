import Foundation

public enum CodexSandboxMode: String, Sendable, Equatable, Codable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
}

public struct CodexInvocationRequest: Sendable, Equatable {
    public let attemptID: String
    public let workspaceID: String
    public let workspacePath: String
    public let workspaceTrusted: Bool
    public let installation: ProviderInstallation
    public let account: AccountReference
    public let snapshot: CapabilitySnapshot
    public let requestedScope: CapabilityScope
    public let promptDigest: String
    public let promptText: String
    public let sandboxMode: CodexSandboxMode
    public let extraFlags: [String]
    public let maxBudgetMicroUSD: Int64?
    public let allowUnenforcedBudgetWithExplicitUserBounds: Bool
    public let resumeThreadID: String?
    public let previousAttemptState: ExecutionAttemptState?
    public let otherActiveAttemptCount: Int
    public let executionApprovalVerified: Bool
    public let transferApprovalVerified: Bool
    public let wallClockLimitSeconds: Int64

    public init(
        attemptID: String,
        workspaceID: String,
        workspacePath: String,
        workspaceTrusted: Bool,
        installation: ProviderInstallation,
        account: AccountReference,
        snapshot: CapabilitySnapshot,
        requestedScope: CapabilityScope,
        promptDigest: String,
        promptText: String,
        sandboxMode: CodexSandboxMode = .readOnly,
        extraFlags: [String] = [],
        maxBudgetMicroUSD: Int64? = nil,
        allowUnenforcedBudgetWithExplicitUserBounds: Bool = false,
        resumeThreadID: String? = nil,
        previousAttemptState: ExecutionAttemptState? = nil,
        otherActiveAttemptCount: Int = 0,
        executionApprovalVerified: Bool,
        transferApprovalVerified: Bool,
        wallClockLimitSeconds: Int64 = 1800
    ) {
        self.attemptID = attemptID
        self.workspaceID = workspaceID
        self.workspacePath = workspacePath
        self.workspaceTrusted = workspaceTrusted
        self.installation = installation
        self.account = account
        self.snapshot = snapshot
        self.requestedScope = requestedScope
        self.promptDigest = promptDigest
        self.promptText = promptText
        self.sandboxMode = sandboxMode
        self.extraFlags = extraFlags
        self.maxBudgetMicroUSD = maxBudgetMicroUSD
        self.allowUnenforcedBudgetWithExplicitUserBounds = allowUnenforcedBudgetWithExplicitUserBounds
        self.resumeThreadID = resumeThreadID
        self.previousAttemptState = previousAttemptState
        self.otherActiveAttemptCount = otherActiveAttemptCount
        self.executionApprovalVerified = executionApprovalVerified
        self.transferApprovalVerified = transferApprovalVerified
        self.wallClockLimitSeconds = wallClockLimitSeconds
    }
}

public struct CodexJSONLParseResult: Sendable, Equatable {
    public let threadID: String?
    public let model: String?
    public let events: [NormalizedProviderEvent]
    public let usageEvents: [UsageSampleEvent]
    public let turnCompleted: Bool
    public let turnFailed: Bool
    public let streamTruncated: Bool
    public let hasUnknownEvents: Bool
    public let parseErrors: [String]
    public let redactionApplied: Bool
}

public enum CodexCLIAdapter {
    public static let providerName = "codex"
    public static let adapterVersion = "0.1.0"
    public static let supportedCLIVersions: Set<String> = ["0.155.1", "0.169.0"]
    public static let maxWallClockSeconds: Int64 = 86_400

    private static let forbiddenTokens: Set<String> = [
        "--trust",
        "--dangerously-bypass-approvals-and-sandbox",
        "--dangerously-bypass-hook-trust",
        "--approve-for-me",
        "danger-full-access",
    ]

    public static func buildInvocationPlan(_ request: CodexInvocationRequest) throws -> ProviderInvocationPlan {
        guard request.workspaceTrusted else {
            throw ProviderAdapterError.untrustedWorkspace
        }
        guard !request.attemptID.isEmpty,
              !request.workspaceID.isEmpty,
              !request.workspacePath.isEmpty,
              !request.promptDigest.isEmpty,
              !request.promptText.isEmpty,
              request.wallClockLimitSeconds > 0,
              request.wallClockLimitSeconds <= maxWallClockSeconds else {
            throw ProviderAdapterError.invalidInput("invalid codex invocation parameters or wallClockLimitSeconds")
        }
        guard request.installation.providerName == providerName,
              request.account.providerName == providerName,
              request.installation.installationID == request.requestedScope.installationID,
              request.installation.cliVersion == request.requestedScope.cliVersion,
              request.account.accountRef == request.requestedScope.accountRef,
              request.account.accountKind == request.requestedScope.accountType,
              request.workspaceID == request.requestedScope.workspaceID else {
            throw ProviderAdapterError.capabilityBlocked("codex installation/account/scope mismatch")
        }
        guard supportedCLIVersions.contains(request.installation.cliVersion) else {
            throw ProviderAdapterError.unsupportedCLIVersion(request.installation.cliVersion)
        }
        guard request.account.authState == .authenticated else {
            throw ProviderAdapterError.capabilityBlocked("codex account not authenticated (\(request.account.authState.rawValue))")
        }
        guard request.executionApprovalVerified else {
            throw ProviderAdapterError.approvalRequired([.execution])
        }
        guard request.transferApprovalVerified else {
            throw ProviderAdapterError.approvalRequired([.externalTransfer])
        }

        for flag in request.extraFlags {
            let token = flag.split(separator: "=", maxSplits: 1).first.map(String.init) ?? flag
            if forbiddenTokens.contains(token) || forbiddenTokens.contains(flag) || flag.contains("danger-full-access") {
                throw ProviderAdapterError.forbiddenBypassFlag(flag)
            }
        }

        var requiredCaps: [CapabilityID] = [.providerInstall, .authOfficial, .runStart]
        if let threadID = request.resumeThreadID {
            guard !threadID.isEmpty else {
                throw ProviderAdapterError.resumeRejected("empty resumeThreadID")
            }
            guard let prev = request.previousAttemptState, prev.isTerminal else {
                throw ProviderAdapterError.resumeRejected("resume only permitted from confirmed terminal attempt")
            }
            requiredCaps.append(.runResume)
        }

        let evaluator = CapabilityEvaluator()
        let gate = evaluator.evaluate(
            snapshot: request.snapshot,
            requestedScope: request.requestedScope,
            requiredCapabilities: requiredCaps
        )
        guard gate == .supported else {
            throw ProviderAdapterError.capabilityBlocked("capability gate blocked: \(gate)")
        }
        let isoGate = evaluator.evaluateConcurrentAccountIsolation(
            snapshot: request.snapshot,
            requestedScope: request.requestedScope,
            otherActiveAttemptCount: request.otherActiveAttemptCount
        )
        guard isoGate == .supported else {
            throw ProviderAdapterError.capabilityBlocked("concurrent account isolation blocked: \(isoGate)")
        }

        let budgetDecision = CostAccountingEngine.evaluateBudgetGate(
            accountKind: request.account.accountKind,
            maxBudgetMicroUSD: request.maxBudgetMicroUSD,
            providerSupportsHardBudgetCap: false,
            allowUnenforcedBudgetWithExplicitUserBounds: request.allowUnenforcedBudgetWithExplicitUserBounds
        )
        let budgetEnforcedByProvider: Bool
        switch budgetDecision {
        case .allow(let enforced, _):
            budgetEnforcedByProvider = enforced
        case .blocked(let reason):
            throw ProviderAdapterError.budgetBlocked(reason)
        }

        var args: [String]
        if let threadID = request.resumeThreadID {
            args = ["exec", "resume", threadID, "--json", "-C", request.workspacePath, "-s", request.sandboxMode.rawValue]
        } else {
            args = ["exec", "--json", "-C", request.workspacePath, "-s", request.sandboxMode.rawValue, "--ephemeral"]
        }
        args.append(contentsOf: request.extraFlags)

        return ProviderInvocationPlan(
            providerName: providerName,
            executablePath: request.installation.executablePath,
            arguments: args,
            workingDirectory: request.workspacePath,
            environmentAllowlist: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"],
            wallClockLimitSeconds: request.wallClockLimitSeconds,
            budgetEnforcedByProvider: budgetEnforcedByProvider,
            redactionIncompleteNotice: "normalized event masking is best-effort and does not guarantee complete secret detection (R8)"
        )
    }

    public static func parseJSONL(_ rawOutput: String, streamEndedCleanly: Bool) -> CodexJSONLParseResult {
        var threadID: String?
        var model: String?
        var events: [NormalizedProviderEvent] = []
        var usageEvents: [UsageSampleEvent] = []
        var turnCompleted = false
        var turnFailed = false
        var streamTruncated = !streamEndedCleanly
        var hasUnknownEvents = false
        var parseErrors: [String] = []
        var redactionApplied = false
        var seq: UInt64 = 0

        let lines = rawOutput.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (lineIndex, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            seq += 1
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                streamTruncated = true
                let msg = "malformed JSONL at line \(lineIndex + 1)"
                parseErrors.append(msg)
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .parseError,
                    rawType: "parse_error", summary: msg, redactionApplied: false
                ))
                continue
            }

            if let tid = obj["thread_id"] as? String, !tid.isEmpty {
                threadID = tid
            }
            if let mdl = obj["model"] as? String, !mdl.isEmpty {
                model = mdl
            }
            let eventID = (obj["id"] as? String) ?? "line-\(lineIndex + 1)"
            let rawType = (obj["type"] as? String) ?? ""

            switch rawType {
            case "thread.started", "turn.started":
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .sessionInit,
                    rawType: rawType, summary: rawType, redactionApplied: false
                ))

            case "item.started", "item.completed":
                let itemType = (obj["item"] as? [String: Any])?["type"] as? String ?? "item"
                let (summary, masked) = ClaudeCodeAdapter.redactSecrets("item:\(itemType)")
                redactionApplied = redactionApplied || masked
                let kind: NormalizedProviderEventKind = itemType == "agent_message" ? .assistantMessage : .toolActivity
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: kind,
                    rawType: rawType, summary: summary, redactionApplied: masked
                ))

            case "turn.completed":
                turnCompleted = true
                if let usageObj = obj["usage"] as? [String: Any],
                   let inTok = ClaudeCodeAdapter.parseNonNegativeInt64(usageObj["input_tokens"]),
                   let outTok = ClaudeCodeAdapter.parseNonNegativeInt64(usageObj["output_tokens"]) {
                    let cached = ClaudeCodeAdapter.parseNonNegativeInt64(usageObj["cached_input_tokens"]) ?? 0
                    usageEvents.append(UsageSampleEvent(
                        eventID: eventID,
                        semantics: .cumulative,
                        inputTokens: inTok,
                        cachedInputTokens: cached,
                        outputTokens: outTok,
                        inputSemantics: .cachedIncludedInTotalInput
                    ))
                }
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .resultCompleted,
                    rawType: rawType, summary: "turn.completed", redactionApplied: false
                ))

            case "turn.failed", "error":
                turnFailed = true
                let rawErr = (obj["message"] as? String) ?? rawType
                let (summary, masked) = ClaudeCodeAdapter.redactSecrets(rawErr)
                redactionApplied = redactionApplied || masked
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .resultError,
                    rawType: rawType, summary: summary, redactionApplied: masked
                ))

            default:
                hasUnknownEvents = true
                let (summary, masked) = ClaudeCodeAdapter.redactSecrets("unknown_event:\(rawType)")
                redactionApplied = redactionApplied || masked
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .unknownEvent,
                    rawType: rawType, summary: summary, redactionApplied: masked
                ))
            }
        }

        return CodexJSONLParseResult(
            threadID: threadID,
            model: model,
            events: events,
            usageEvents: usageEvents,
            turnCompleted: turnCompleted,
            turnFailed: turnFailed,
            streamTruncated: streamTruncated,
            hasUnknownEvents: hasUnknownEvents,
            parseErrors: parseErrors,
            redactionApplied: redactionApplied
        )
    }

    public static func reconcileOutcome(
        exitCode: Int32?,
        timedOut: Bool,
        cancelRequested: Bool,
        parseResult: CodexJSONLParseResult
    ) -> ExecutionAttemptState {
        if timedOut {
            return .interrupted
        }
        guard let exitCode else {
            return .unknown
        }
        let cleanTerminalSuccess = exitCode == 0
            && parseResult.turnCompleted
            && !parseResult.turnFailed
            && !parseResult.streamTruncated

        if cancelRequested {
            if cleanTerminalSuccess {
                return .succeeded
            }
            return exitCode != 0 ? .cancelled : .unknown
        }
        if exitCode != 0 || parseResult.turnFailed {
            return .failed
        }
        return cleanTerminalSuccess ? .succeeded : .unknown
    }

    public static func buildCostRecord(
        recordID: String,
        attemptID: String,
        workspaceID: String,
        cliVersion: String,
        accountKind: AccountKind,
        parseResult: CodexJSONLParseResult,
        attemptOutcome: ExecutionAttemptState,
        rateCard: VerifiedRateCard?,
        observedAt: Int64,
        revision: Int = 1
    ) -> AttemptCostRecord {
        let estimated = CostAccountingEngine.computeRateTableEstimate(
            accountKind: accountKind,
            events: parseResult.usageEvents,
            rateCard: rateCard
        )
        var reasons = estimated.incompleteReasons
        if parseResult.streamTruncated {
            reasons.append("stream truncated")
        }
        let sourceBasis: String
        switch estimated.status {
        case .subscriptionIncluded:
            sourceBasis = "codex exec --json subscription session"
        case .rateTableEstimate:
            sourceBasis = "codex usage + verified rate card estimate"
        case .unknown, .providerReportedEstimate, .authoritativeBilling:
            sourceBasis = "codex usage or rate card unavailable"
        }

        return AttemptCostRecord(
            recordID: recordID,
            attemptID: attemptID,
            workspaceID: workspaceID,
            providerName: providerName,
            cliVersion: cliVersion,
            adapterVersion: adapterVersion,
            model: parseResult.model,
            accountKind: accountKind,
            status: estimated.status,
            currency: estimated.currency,
            amountMicroUSD: estimated.amountMicroUSD,
            uncachedInputTokens: estimated.uncachedInput,
            cachedInputTokens: estimated.cachedInput,
            outputTokens: estimated.output,
            sourceBasis: sourceBasis,
            rateCardVersion: estimated.status == .rateTableEstimate ? rateCard?.rateCardVersion : nil,
            incompleteReasons: reasons,
            attemptOutcome: attemptOutcome,
            observedAt: observedAt,
            revision: revision
        )
    }
}
