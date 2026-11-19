import Foundation
import SQLite3

public enum CostMeasurementStatus: String, Sendable, Equatable, Codable {
    case authoritativeBilling = "AUTHORITATIVE_BILLING"
    case providerReportedEstimate = "PROVIDER_REPORTED_ESTIMATE"
    case rateTableEstimate = "RATE_TABLE_ESTIMATE"
    case subscriptionIncluded = "SUBSCRIPTION_INCLUDED"
    case unknown = "UNKNOWN"
}

public enum TokenInputSemantics: String, Sendable, Equatable, Codable {
    case cachedIncludedInTotalInput
    case cachedSeparateFromUncachedInput
    case unknown
}

public enum UsageReportingSemantics: String, Sendable, Equatable, Codable {
    case cumulative
    case incremental
    case unknown
}

public struct UsageSampleEvent: Sendable, Equatable, Codable {
    public let eventID: String?
    public let semantics: UsageReportingSemantics
    public let inputTokens: Int64
    public let cachedInputTokens: Int64
    public let outputTokens: Int64
    public let inputSemantics: TokenInputSemantics

    public init(
        eventID: String?,
        semantics: UsageReportingSemantics,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        outputTokens: Int64,
        inputSemantics: TokenInputSemantics
    ) {
        self.eventID = eventID
        self.semantics = semantics
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.inputSemantics = inputSemantics
    }
}

public struct VerifiedRateCard: Sendable, Equatable, Codable {
    public let providerName: String
    public let model: String
    public let currency: String
    public let effectiveAt: Int64
    public let rateCardVersion: String
    public let uncachedInputMicroUSDPerMillion: Int64
    public let cachedInputMicroUSDPerMillion: Int64
    public let outputMicroUSDPerMillion: Int64
    public let missingComponents: [String]

    public init(
        providerName: String,
        model: String,
        currency: String,
        effectiveAt: Int64,
        rateCardVersion: String,
        uncachedInputMicroUSDPerMillion: Int64,
        cachedInputMicroUSDPerMillion: Int64,
        outputMicroUSDPerMillion: Int64,
        missingComponents: [String] = []
    ) {
        self.providerName = providerName
        self.model = model
        self.currency = currency
        self.effectiveAt = effectiveAt
        self.rateCardVersion = rateCardVersion
        self.uncachedInputMicroUSDPerMillion = uncachedInputMicroUSDPerMillion
        self.cachedInputMicroUSDPerMillion = cachedInputMicroUSDPerMillion
        self.outputMicroUSDPerMillion = outputMicroUSDPerMillion
        self.missingComponents = missingComponents
    }
}

public struct AttemptCostRecord: Sendable, Equatable, Codable {
    public let recordID: String
    public let attemptID: String
    public let workspaceID: String
    public let providerName: String
    public let cliVersion: String
    public let adapterVersion: String
    public let model: String?
    public let accountKind: AccountKind
    public let status: CostMeasurementStatus
    public let currency: String?
    public let amountMicroUSD: Int64?
    public let uncachedInputTokens: Int64?
    public let cachedInputTokens: Int64?
    public let outputTokens: Int64?
    public let sourceBasis: String
    public let rateCardVersion: String?
    public let incompleteReasons: [String]
    public let attemptOutcome: ExecutionAttemptState
    public let observedAt: Int64
    public let revision: Int

    public init(
        recordID: String,
        attemptID: String,
        workspaceID: String,
        providerName: String,
        cliVersion: String,
        adapterVersion: String,
        model: String?,
        accountKind: AccountKind,
        status: CostMeasurementStatus,
        currency: String?,
        amountMicroUSD: Int64?,
        uncachedInputTokens: Int64?,
        cachedInputTokens: Int64?,
        outputTokens: Int64?,
        sourceBasis: String,
        rateCardVersion: String?,
        incompleteReasons: [String],
        attemptOutcome: ExecutionAttemptState,
        observedAt: Int64,
        revision: Int = 1
    ) {
        self.recordID = recordID
        self.attemptID = attemptID
        self.workspaceID = workspaceID
        self.providerName = providerName
        self.cliVersion = cliVersion
        self.adapterVersion = adapterVersion
        self.model = model
        self.accountKind = accountKind
        self.status = status
        self.currency = currency
        self.amountMicroUSD = amountMicroUSD
        self.uncachedInputTokens = uncachedInputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.sourceBasis = sourceBasis
        self.rateCardVersion = rateCardVersion
        self.incompleteReasons = incompleteReasons
        self.attemptOutcome = attemptOutcome
        self.observedAt = observedAt
        self.revision = revision
    }
}

public struct AggregatedCostSummary: Sendable, Equatable, Codable {
    public let totalAttempts: Int
    public let confirmedTotalMicroUSD: Int64?
    public let knownSubtotalMicroUSD: Int64
    public let currency: String?
    public let currencyConflict: Bool
    public let unknownCount: Int
    public let subscriptionIncludedCount: Int
    public let estimateCount: Int
    public let authoritativeCount: Int
    public let hasIncompleteData: Bool
    public let notes: [String]
}

public enum BudgetGateDecision: Sendable, Equatable {
    case allow(enforcedByProvider: Bool, maxBudgetMicroUSD: Int64?)
    case blocked(reason: String)
}

public final class CostAccountingEngine: @unchecked Sendable {
    public let store: SQLiteStore

    public init(store: SQLiteStore) throws {
        self.store = store
        try initializeSchema()
    }

    private func initializeSchema() throws {
        try store.executeRawForTesting(
            """
            CREATE TABLE IF NOT EXISTS attempt_cost_records (
                attempt_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                workspace_id TEXT NOT NULL,
                record_id TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                observed_at INTEGER NOT NULL,
                PRIMARY KEY (attempt_id, revision)
            );
            """
        )
    }

    public static func consolidateUsage(
        _ events: [UsageSampleEvent]
    ) -> (uncachedInput: Int64, cachedInput: Int64, output: Int64)? {
        guard !events.isEmpty else { return nil }
        guard let firstSemantics = events.first?.semantics, firstSemantics != .unknown else { return nil }

        struct NormalizedSample: Equatable {
            let uncached: Int64
            let cached: Int64
            let output: Int64
        }

        var normalizedEvents: [(eventID: String?, sample: NormalizedSample)] = []
        for event in events {
            guard event.semantics == firstSemantics,
                  event.inputSemantics != .unknown,
                  event.inputTokens >= 0,
                  event.cachedInputTokens >= 0,
                  event.outputTokens >= 0 else {
                return nil
            }
            if events.count > 1 {
                guard let eid = event.eventID, !eid.isEmpty else { return nil }
            }
            let uncached: Int64
            switch event.inputSemantics {
            case .cachedIncludedInTotalInput:
                guard event.cachedInputTokens <= event.inputTokens else { return nil }
                uncached = event.inputTokens - event.cachedInputTokens
            case .cachedSeparateFromUncachedInput:
                uncached = event.inputTokens
            case .unknown:
                return nil
            }
            normalizedEvents.append((
                event.eventID,
                NormalizedSample(uncached: uncached, cached: event.cachedInputTokens, output: event.outputTokens)
            ))
        }

        var seenByID: [String: NormalizedSample] = [:]
        var uniqueSamples: [NormalizedSample] = []
        for (eventID, sample) in normalizedEvents {
            if let eventID, !eventID.isEmpty {
                if let existing = seenByID[eventID] {
                    guard existing == sample else { return nil }
                    continue
                }
                seenByID[eventID] = sample
            }
            uniqueSamples.append(sample)
        }

        switch firstSemantics {
        case .cumulative:
            var prevUncached: Int64 = 0
            var prevCached: Int64 = 0
            var prevOutput: Int64 = 0
            for sample in uniqueSamples {
                guard sample.uncached >= prevUncached,
                      sample.cached >= prevCached,
                      sample.output >= prevOutput else {
                    return nil
                }
                prevUncached = sample.uncached
                prevCached = sample.cached
                prevOutput = sample.output
            }
            return (prevUncached, prevCached, prevOutput)

        case .incremental:
            var totalUncached: Int64 = 0
            var totalCached: Int64 = 0
            var totalOutput: Int64 = 0
            for sample in uniqueSamples {
                let (u, uOv) = totalUncached.addingReportingOverflow(sample.uncached)
                let (c, cOv) = totalCached.addingReportingOverflow(sample.cached)
                let (o, oOv) = totalOutput.addingReportingOverflow(sample.output)
                guard !uOv && !cOv && !oOv else { return nil }
                totalUncached = u
                totalCached = c
                totalOutput = o
            }
            return (totalUncached, totalCached, totalOutput)

        case .unknown:
            return nil
        }
    }

    public static func computeRateTableEstimate(
        accountKind: AccountKind,
        events: [UsageSampleEvent],
        rateCard: VerifiedRateCard?
    ) -> (
        status: CostMeasurementStatus,
        amountMicroUSD: Int64?,
        currency: String?,
        uncachedInput: Int64?,
        cachedInput: Int64?,
        output: Int64?,
        incompleteReasons: [String]
    ) {
        let consolidated = consolidateUsage(events)
        if accountKind == .subscription {
            return (
                .subscriptionIncluded,
                nil,
                nil,
                consolidated?.uncachedInput,
                consolidated?.cachedInput,
                consolidated?.output,
                ["subscription included usage cannot be assumed to have zero incremental cost"]
            )
        }
        guard accountKind == .apiKey else {
            return (.unknown, nil, nil, nil, nil, nil, ["account kind unknown"])
        }
        guard let usage = consolidated else {
            return (.unknown, nil, nil, nil, nil, nil, ["usage tokens unavailable or inconsistent"])
        }
        guard let rateCard,
              !rateCard.currency.isEmpty,
              !rateCard.rateCardVersion.isEmpty,
              rateCard.uncachedInputMicroUSDPerMillion >= 0,
              rateCard.cachedInputMicroUSDPerMillion >= 0,
              rateCard.outputMicroUSDPerMillion >= 0 else {
            return (
                .unknown,
                nil,
                nil,
                usage.uncachedInput,
                usage.cachedInput,
                usage.output,
                ["verified rate card unavailable"]
            )
        }

        let (uCost, uOv) = usage.uncachedInput.multipliedReportingOverflow(by: rateCard.uncachedInputMicroUSDPerMillion)
        let (cCost, cOv) = usage.cachedInput.multipliedReportingOverflow(by: rateCard.cachedInputMicroUSDPerMillion)
        let (oCost, oOv) = usage.output.multipliedReportingOverflow(by: rateCard.outputMicroUSDPerMillion)
        guard !uOv && !cOv && !oOv else {
            return (.unknown, nil, nil, usage.uncachedInput, usage.cachedInput, usage.output, ["cost arithmetic overflow"])
        }
        let (sum1, s1Ov) = uCost.addingReportingOverflow(cCost)
        let (sum2, s2Ov) = sum1.addingReportingOverflow(oCost)
        guard !s1Ov && !s2Ov else {
            return (.unknown, nil, nil, usage.uncachedInput, usage.cachedInput, usage.output, ["cost arithmetic overflow"])
        }
        let microUSD = sum2 / 1_000_000
        return (
            .rateTableEstimate,
            microUSD,
            rateCard.currency,
            usage.uncachedInput,
            usage.cachedInput,
            usage.output,
            rateCard.missingComponents
        )
    }

    public func recordAttemptCost(_ record: AttemptCostRecord) throws {
        guard record.workspaceID.utf8.elementsEqual(store.workspaceID.utf8) else {
            throw StorageError.denied
        }
        guard !record.recordID.isEmpty,
              !record.attemptID.isEmpty,
              !record.providerName.isEmpty,
              !record.cliVersion.isEmpty,
              !record.adapterVersion.isEmpty,
              !record.sourceBasis.isEmpty,
              record.revision >= 1,
              record.observedAt >= 0 else {
            throw StorageError.invalidInput
        }
        try CredentialSanitizer.validateNoCredentials(record.recordID)
        try CredentialSanitizer.validateNoCredentials(record.attemptID)
        try CredentialSanitizer.validateNoCredentials(record.providerName)
        try CredentialSanitizer.validateNoCredentials(record.sourceBasis)
        for reason in record.incompleteReasons {
            try CredentialSanitizer.validateNoCredentials(reason)
        }
        if let model = record.model {
            try CredentialSanitizer.validateNoCredentials(model)
        }

        switch record.status {
        case .unknown, .subscriptionIncluded:
            guard record.amountMicroUSD == nil else {
                throw StorageError.invalidInput
            }
        case .authoritativeBilling, .providerReportedEstimate, .rateTableEstimate:
            guard let amt = record.amountMicroUSD, amt >= 0, let curr = record.currency, !curr.isEmpty else {
                throw StorageError.invalidInput
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadJSON = String(decoding: try encoder.encode(record), as: UTF8.self)

        try store.withConnectionLock { _ in
            try store.ensureAvailableForWrite()
            try store.execute("BEGIN IMMEDIATE")
            do {
                let stmt = try store.prepare(
                    """
                    INSERT INTO attempt_cost_records (
                        attempt_id, revision, workspace_id, record_id, payload_json, observed_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(stmt) }
                try store.bindText(stmt, index: 1, value: record.attemptID)
                sqlite3_bind_int(stmt, 2, Int32(record.revision))
                try store.bindText(stmt, index: 3, value: record.workspaceID)
                try store.bindText(stmt, index: 4, value: record.recordID)
                try store.bindText(stmt, index: 5, value: payloadJSON)
                sqlite3_bind_int64(stmt, 6, record.observedAt)
                let rc = sqlite3_step(stmt)
                if (rc & 0xff) == SQLITE_CONSTRAINT {
                    throw StorageError.versionConflict
                }
                guard rc == SQLITE_DONE else {
                    throw store.mapSQLiteError(rc)
                }
                try store.execute("COMMIT")
            } catch {
                _ = try? store.execute("ROLLBACK")
                throw error
            }
        }
    }

    public func listCostHistory(attemptID: String) throws -> [AttemptCostRecord] {
        guard !attemptID.isEmpty else { throw StorageError.invalidInput }
        return try store.withConnectionLock { _ in
            let stmt = try store.prepare(
                "SELECT payload_json FROM attempt_cost_records WHERE attempt_id = ? AND workspace_id = ? ORDER BY revision ASC"
            )
            defer { sqlite3_finalize(stmt) }
            try store.bindText(stmt, index: 1, value: attemptID)
            try store.bindText(stmt, index: 2, value: store.workspaceID)
            var out: [AttemptCostRecord] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw store.mapSQLiteError(rc) }
                let rec = try JSONDecoder().decode(AttemptCostRecord.self, from: Data(store.columnText(stmt, index: 0).utf8))
                out.append(rec)
            }
            return out
        }
    }

    public func latestCostRecord(attemptID: String) throws -> AttemptCostRecord? {
        try listCostHistory(attemptID: attemptID).last
    }

    public static func aggregate(records: [AttemptCostRecord]) -> AggregatedCostSummary {
        var currencies = Set<String>()
        var knownSubtotal: Int64 = 0
        var unknownCount = 0
        var subscriptionCount = 0
        var estimateCount = 0
        var authoritativeCount = 0
        var notes: [String] = []
        var overflowed = false

        for record in records {
            switch record.status {
            case .authoritativeBilling:
                authoritativeCount += 1
            case .providerReportedEstimate, .rateTableEstimate:
                estimateCount += 1
            case .subscriptionIncluded:
                subscriptionCount += 1
            case .unknown:
                unknownCount += 1
            }
            if !record.incompleteReasons.isEmpty {
                notes.append(contentsOf: record.incompleteReasons)
            }
            if let curr = record.currency, !curr.isEmpty {
                currencies.insert(curr)
            }
            if let amt = record.amountMicroUSD,
               record.status != .unknown,
               record.status != .subscriptionIncluded {
                let (next, ov) = knownSubtotal.addingReportingOverflow(amt)
                if ov {
                    overflowed = true
                } else {
                    knownSubtotal = next
                }
            }
        }

        let currencyConflict = currencies.count > 1 || overflowed
        if currencies.count > 1 {
            notes.append("currency mismatch across records: \(currencies.sorted().joined(separator: ", "))")
        }
        if overflowed {
            notes.append("cost total overflow")
        }
        let singleCurrency = currencies.count == 1 ? currencies.first : nil
        let allAuthoritative = !records.isEmpty
            && !currencyConflict
            && unknownCount == 0
            && subscriptionCount == 0
            && estimateCount == 0
        let confirmedTotal: Int64? = allAuthoritative ? knownSubtotal : nil
        let hasIncompleteData = records.isEmpty || currencyConflict || unknownCount > 0 || subscriptionCount > 0 || !notes.isEmpty

        return AggregatedCostSummary(
            totalAttempts: records.count,
            confirmedTotalMicroUSD: confirmedTotal,
            knownSubtotalMicroUSD: currencyConflict ? 0 : knownSubtotal,
            currency: currencyConflict ? nil : singleCurrency,
            currencyConflict: currencyConflict,
            unknownCount: unknownCount,
            subscriptionIncludedCount: subscriptionCount,
            estimateCount: estimateCount,
            authoritativeCount: authoritativeCount,
            hasIncompleteData: hasIncompleteData,
            notes: notes
        )
    }

    public static func evaluateBudgetGate(
        accountKind: AccountKind,
        maxBudgetMicroUSD: Int64?,
        providerSupportsHardBudgetCap: Bool,
        allowUnenforcedBudgetWithExplicitUserBounds: Bool
    ) -> BudgetGateDecision {
        if let limit = maxBudgetMicroUSD {
            guard limit > 0 else {
                return .blocked(reason: "budget limit must be positive")
            }
            if accountKind == .subscription {
                return .blocked(reason: "provider hard monetary budget cap is not enforced for subscription accounts")
            }
            guard accountKind == .apiKey, providerSupportsHardBudgetCap else {
                return .blocked(reason: "provider monetary budget enforcement unverified or unsupported")
            }
            return .allow(enforcedByProvider: true, maxBudgetMicroUSD: limit)
        }
        guard allowUnenforcedBudgetWithExplicitUserBounds else {
            return .blocked(reason: "budget policy not configured")
        }
        return .allow(enforcedByProvider: false, maxBudgetMicroUSD: nil)
    }
}
