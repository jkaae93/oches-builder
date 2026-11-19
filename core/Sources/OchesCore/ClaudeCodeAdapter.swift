import Foundation

public enum ProviderAdapterError: Error, Sendable, Equatable {
    case unsupportedCLIVersion(String)
    case forbiddenBypassFlag(String)
    case capabilityBlocked(String)
    case budgetBlocked(String)
    case approvalRequired([ApprovalKind])
    case resumeRejected(String)
    case untrustedWorkspace
    case invalidInput(String)
}

public enum NormalizedProviderEventKind: String, Sendable, Equatable, Codable {
    case sessionInit
    case assistantMessage
    case toolActivity
    case backgroundTaskStarted
    case resultCompleted
    case resultError
    case usageReported
    case unknownEvent
    case parseError
}

public struct NormalizedProviderEvent: Sendable, Equatable, Codable {
    public let sequence: UInt64
    public let providerName: String
    public let kind: NormalizedProviderEventKind
    public let rawType: String
    public let summary: String
    public let redactionApplied: Bool
}

public struct ProviderInvocationPlan: Sendable, Equatable {
    public let providerName: String
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environmentAllowlist: [String: String]
    public let wallClockLimitSeconds: Int64
    public let budgetEnforcedByProvider: Bool
    public let redactionIncompleteNotice: String
}

public struct ClaudeInvocationRequest: Sendable, Equatable {
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
    public let allowedTools: [String]
    public let disallowedTools: [String]
    public let extraFlags: [String]
    public let maxBudgetMicroUSD: Int64?
    public let allowUnenforcedBudgetWithExplicitUserBounds: Bool
    public let resumeSessionID: String?
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
        allowedTools: [String] = [],
        disallowedTools: [String] = [],
        extraFlags: [String] = [],
        maxBudgetMicroUSD: Int64? = nil,
        allowUnenforcedBudgetWithExplicitUserBounds: Bool = false,
        resumeSessionID: String? = nil,
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
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.extraFlags = extraFlags
        self.maxBudgetMicroUSD = maxBudgetMicroUSD
        self.allowUnenforcedBudgetWithExplicitUserBounds = allowUnenforcedBudgetWithExplicitUserBounds
        self.resumeSessionID = resumeSessionID
        self.previousAttemptState = previousAttemptState
        self.otherActiveAttemptCount = otherActiveAttemptCount
        self.executionApprovalVerified = executionApprovalVerified
        self.transferApprovalVerified = transferApprovalVerified
        self.wallClockLimitSeconds = wallClockLimitSeconds
    }
}

public struct ClaudeStreamParseResult: Sendable, Equatable {
    public let sessionID: String?
    public let model: String?
    public let events: [NormalizedProviderEvent]
    public let usageEvents: [UsageSampleEvent]
    public let providerReportedCostMicroUSD: Int64?
    public let terminalResultReceived: Bool
    public let terminalResultIsError: Bool
    public let backgroundTasksPending: Bool
    public let streamTruncated: Bool
    public let hasUnknownEvents: Bool
    public let parseErrors: [String]
    public let redactionApplied: Bool
}

public enum ClaudeCodeAdapter {
    public static let providerName = "claude"
    public static let adapterVersion = "0.1.0"
    public static let supportedCLIVersions: Set<String> = ["2.1.296"]
    public static let maxWallClockSeconds: Int64 = 86_400

    private static let forbiddenFlags: Set<String> = [
        "--dangerously-skip-permissions",
        "--allow-dangerously-skip-permissions",
        "--bg",
        "--background",
    ]

    public static func buildInvocationPlan(_ request: ClaudeInvocationRequest) throws -> ProviderInvocationPlan {
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
            throw ProviderAdapterError.invalidInput("invalid invocation parameters or wallClockLimitSeconds")
        }
        guard request.installation.providerName == providerName,
              request.account.providerName == providerName,
              request.installation.installationID == request.requestedScope.installationID,
              request.installation.cliVersion == request.requestedScope.cliVersion,
              request.account.accountRef == request.requestedScope.accountRef,
              request.account.accountKind == request.requestedScope.accountType,
              request.workspaceID == request.requestedScope.workspaceID else {
            throw ProviderAdapterError.capabilityBlocked("provider installation/account/scope mismatch")
        }
        guard supportedCLIVersions.contains(request.installation.cliVersion) else {
            throw ProviderAdapterError.unsupportedCLIVersion(request.installation.cliVersion)
        }
        guard request.account.authState == .authenticated else {
            throw ProviderAdapterError.capabilityBlocked("provider account not authenticated (\(request.account.authState.rawValue))")
        }
        guard request.executionApprovalVerified else {
            throw ProviderAdapterError.approvalRequired([.execution])
        }
        guard request.transferApprovalVerified else {
            throw ProviderAdapterError.approvalRequired([.externalTransfer])
        }

        for flag in request.extraFlags {
            let token = flag.split(separator: "=", maxSplits: 1).first.map(String.init) ?? flag
            if forbiddenFlags.contains(token) {
                throw ProviderAdapterError.forbiddenBypassFlag(token)
            }
        }

        var requiredCaps: [CapabilityID] = [.providerInstall, .authOfficial, .runStart]
        if let resumeID = request.resumeSessionID {
            guard !resumeID.isEmpty else {
                throw ProviderAdapterError.resumeRejected("empty resumeSessionID")
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
            providerSupportsHardBudgetCap: request.account.accountKind == .apiKey,
            allowUnenforcedBudgetWithExplicitUserBounds: request.allowUnenforcedBudgetWithExplicitUserBounds
        )
        let budgetEnforcedByProvider: Bool
        switch budgetDecision {
        case .allow(let enforced, _):
            budgetEnforcedByProvider = enforced
        case .blocked(let reason):
            throw ProviderAdapterError.budgetBlocked(reason)
        }

        var args: [String] = ["-p", "--output-format", "stream-json", "--verbose"]
        if let maxBudget = request.maxBudgetMicroUSD, budgetEnforcedByProvider {
            args.append(contentsOf: ["--max-budget-usd", formatUSDFromMicroUSD(maxBudget)])
        }
        if !request.allowedTools.isEmpty {
            args.append("--allowedTools")
            args.append(contentsOf: request.allowedTools)
        }
        if !request.disallowedTools.isEmpty {
            args.append("--disallowedTools")
            args.append(contentsOf: request.disallowedTools)
        }
        if let resumeID = request.resumeSessionID {
            args.append(contentsOf: ["--resume", resumeID])
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

    public static func parseStreamJSON(_ rawOutput: String, streamEndedCleanly: Bool) -> ClaudeStreamParseResult {
        var sessionID: String?
        var model: String?
        var events: [NormalizedProviderEvent] = []
        var usageEvents: [UsageSampleEvent] = []
        var providerCostMicroUSD: Int64?
        var terminalResultReceived = false
        var terminalResultIsError = false
        var backgroundTasksPending = false
        var streamTruncated = !streamEndedCleanly
        var hasUnknownEvents = false
        var parseErrors: [String] = []
        var redactionApplied = false
        var seq: UInt64 = 0

        let lines = rawOutput.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (lineIndex, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            seq += 1
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                streamTruncated = true
                let msg = "malformed JSON at line \(lineIndex + 1)"
                parseErrors.append(msg)
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .parseError,
                    rawType: "parse_error", summary: msg, redactionApplied: false
                ))
                continue
            }

            if let sid = obj["session_id"] as? String, !sid.isEmpty {
                sessionID = sid
            }
            if let mdl = obj["model"] as? String, !mdl.isEmpty {
                model = mdl
            }
            let eventID = (obj["uuid"] as? String) ?? (obj["id"] as? String) ?? "line-\(lineIndex + 1)"
            let rawType = (obj["type"] as? String) ?? ""

            switch rawType {
            case "system":
                let subtype = (obj["subtype"] as? String) ?? "system"
                let (summary, masked) = redactSecrets("system:\(subtype)")
                redactionApplied = redactionApplied || masked
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .sessionInit,
                    rawType: rawType, summary: summary, redactionApplied: masked
                ))

            case "assistant", "user":
                if let message = obj["message"] as? [String: Any], let mdl = message["model"] as? String, !mdl.isEmpty {
                    model = mdl
                }
                let rawSummary = (obj["summary"] as? String) ?? rawType
                let (summary, masked) = redactSecrets(rawSummary)
                redactionApplied = redactionApplied || masked
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .assistantMessage,
                    rawType: rawType, summary: summary, redactionApplied: masked
                ))

            case "tool_use", "tool_result":
                let name = (obj["name"] as? String) ?? rawType
                let (summary, masked) = redactSecrets("tool:\(name)")
                redactionApplied = redactionApplied || masked
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .toolActivity,
                    rawType: rawType, summary: summary, redactionApplied: masked
                ))

            case "background_task":
                let status = (obj["status"] as? String)?.lowercased() ?? "running"
                if status != "completed" && status != "cancelled" && status != "failed" {
                    backgroundTasksPending = true
                }
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .backgroundTaskStarted,
                    rawType: rawType, summary: "background_task:\(status)", redactionApplied: false
                ))

            case "result":
                terminalResultReceived = true
                if let isErr = obj["is_error"] as? Bool {
                    terminalResultIsError = isErr
                } else if (obj["subtype"] as? String) == "error" {
                    terminalResultIsError = true
                }
                if let costVal = parseFiniteNonNegativeDouble(obj["total_cost_usd"]) {
                    providerCostMicroUSD = Int64((costVal * 1_000_000.0).rounded())
                }
                if let usageObj = obj["usage"] as? [String: Any],
                   let inTok = parseNonNegativeInt64(usageObj["input_tokens"]),
                   let outTok = parseNonNegativeInt64(usageObj["output_tokens"]) {
                    let cached = parseNonNegativeInt64(usageObj["cache_read_input_tokens"]) ?? 0
                    usageEvents.append(UsageSampleEvent(
                        eventID: eventID,
                        semantics: .cumulative,
                        inputTokens: inTok,
                        cachedInputTokens: cached,
                        outputTokens: outTok,
                        inputSemantics: .cachedSeparateFromUncachedInput
                    ))
                }
                let (summary, masked) = redactSecrets("result:error=\(terminalResultIsError)")
                redactionApplied = redactionApplied || masked
                events.append(NormalizedProviderEvent(
                    sequence: seq,
                    providerName: providerName,
                    kind: terminalResultIsError ? .resultError : .resultCompleted,
                    rawType: rawType,
                    summary: summary,
                    redactionApplied: masked
                ))

            default:
                hasUnknownEvents = true
                let (summary, masked) = redactSecrets("unknown_event:\(rawType)")
                redactionApplied = redactionApplied || masked
                events.append(NormalizedProviderEvent(
                    sequence: seq, providerName: providerName, kind: .unknownEvent,
                    rawType: rawType, summary: summary, redactionApplied: masked
                ))
            }
        }

        return ClaudeStreamParseResult(
            sessionID: sessionID,
            model: model,
            events: events,
            usageEvents: usageEvents,
            providerReportedCostMicroUSD: providerCostMicroUSD,
            terminalResultReceived: terminalResultReceived,
            terminalResultIsError: terminalResultIsError,
            backgroundTasksPending: backgroundTasksPending,
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
        parseResult: ClaudeStreamParseResult
    ) -> ExecutionAttemptState {
        if timedOut {
            return .interrupted
        }
        guard let exitCode else {
            return .unknown
        }
        let cleanTerminalSuccess = exitCode == 0
            && parseResult.terminalResultReceived
            && !parseResult.terminalResultIsError
            && !parseResult.streamTruncated
            && !parseResult.backgroundTasksPending

        if cancelRequested {
            if cleanTerminalSuccess {
                return .succeeded
            }
            return exitCode != 0 ? .cancelled : .unknown
        }
        if exitCode != 0 || parseResult.terminalResultIsError {
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
        parseResult: ClaudeStreamParseResult,
        attemptOutcome: ExecutionAttemptState,
        rateCard: VerifiedRateCard?,
        observedAt: Int64,
        revision: Int = 1
    ) -> AttemptCostRecord {
        let consolidated = CostAccountingEngine.consolidateUsage(parseResult.usageEvents)
        if accountKind == .subscription {
            return AttemptCostRecord(
                recordID: recordID,
                attemptID: attemptID,
                workspaceID: workspaceID,
                providerName: providerName,
                cliVersion: cliVersion,
                adapterVersion: adapterVersion,
                model: parseResult.model,
                accountKind: accountKind,
                status: .subscriptionIncluded,
                currency: nil,
                amountMicroUSD: nil,
                uncachedInputTokens: consolidated?.uncachedInput,
                cachedInputTokens: consolidated?.cachedInput,
                outputTokens: consolidated?.output,
                sourceBasis: "claude stream-json subscription session",
                rateCardVersion: nil,
                incompleteReasons: ["subscription included usage cannot be assumed to have zero incremental cost"],
                attemptOutcome: attemptOutcome,
                observedAt: observedAt,
                revision: revision
            )
        }
        if accountKind == .apiKey, let reported = parseResult.providerReportedCostMicroUSD {
            return AttemptCostRecord(
                recordID: recordID,
                attemptID: attemptID,
                workspaceID: workspaceID,
                providerName: providerName,
                cliVersion: cliVersion,
                adapterVersion: adapterVersion,
                model: parseResult.model,
                accountKind: accountKind,
                status: .providerReportedEstimate,
                currency: "USD",
                amountMicroUSD: reported,
                uncachedInputTokens: consolidated?.uncachedInput,
                cachedInputTokens: consolidated?.cachedInput,
                outputTokens: consolidated?.output,
                sourceBasis: "claude stream-json result.total_cost_usd (session estimate, not authoritative billing)",
                rateCardVersion: nil,
                incompleteReasons: parseResult.streamTruncated ? ["stream truncated"] : [],
                attemptOutcome: attemptOutcome,
                observedAt: observedAt,
                revision: revision
            )
        }

        let estimated = CostAccountingEngine.computeRateTableEstimate(
            accountKind: accountKind,
            events: parseResult.usageEvents,
            rateCard: rateCard
        )
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
            sourceBasis: estimated.status == .rateTableEstimate ? "verified rate card estimate" : "claude usage/cost unavailable",
            rateCardVersion: estimated.status == .rateTableEstimate ? rateCard?.rateCardVersion : nil,
            incompleteReasons: estimated.incompleteReasons,
            attemptOutcome: attemptOutcome,
            observedAt: observedAt,
            revision: revision
        )
    }

    public static func runControlledSubprocess(
        plan: ProviderInvocationPlan,
        stdinText: String? = nil
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
        process.environment = plan.environmentAllowlist

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let stdinText {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(Data(stdinText.utf8))
            try stdinPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }

    static func redactSecrets(_ text: String) -> (redacted: String, changed: Bool) {
        let patterns = [
            "sk-[A-Za-z0-9._-]+",
            "Bearer\\s+[A-Za-z0-9._-]+",
            "(?i)(api[_-]?key|token|cookie)\\s*[:=]\\s*[^\\s\"']+",
        ]
        var result = text
        var changed = false
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                let replaced = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED]")
                if replaced != result {
                    changed = true
                    result = replaced
                }
            }
        }
        return (result, changed)
    }

    static func parseNonNegativeInt64(_ raw: Any?) -> Int64? {
        guard let num = raw as? NSNumber else { return nil }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        let val = num.int64Value
        return val >= 0 ? val : nil
    }

    static func parseFiniteNonNegativeDouble(_ raw: Any?) -> Double? {
        guard let num = raw as? NSNumber else { return nil }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        let val = num.doubleValue
        guard val.isFinite, val >= 0, val <= 1_000_000.0 else { return nil }
        return val
    }

    private static func formatUSDFromMicroUSD(_ microUSD: Int64) -> String {
        let whole = microUSD / 1_000_000
        let frac = microUSD % 1_000_000
        if frac == 0 { return "\(whole).00" }
        var fracStr = String(format: "%06lld", frac)
        while fracStr.count > 2 && fracStr.hasSuffix("0") {
            fracStr.removeLast()
        }
        return "\(whole).\(fracStr)"
    }
}
