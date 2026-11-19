import Foundation

public enum ProviderExecutionMode: String, Sendable, Equatable, Codable {
    case mockFixture
    case controlledCLIFixture
    case liveExternalAPI
}

public struct ProviderComparisonEntry: Sendable, Equatable, Codable {
    public let providerName: String
    public let cliVersion: String
    public let adapterVersion: String
    public let executionMode: ProviderExecutionMode
    public let fixtureID: String
    public let attemptState: ExecutionAttemptState
    public let evaluationVerdict: EvaluationVerdict
    public let costRecord: AttemptCostRecord
    public let streamTruncated: Bool
    public let hasUnknownEvents: Bool

    public init(
        providerName: String,
        cliVersion: String,
        adapterVersion: String,
        executionMode: ProviderExecutionMode,
        fixtureID: String,
        attemptState: ExecutionAttemptState,
        evaluationVerdict: EvaluationVerdict,
        costRecord: AttemptCostRecord,
        streamTruncated: Bool,
        hasUnknownEvents: Bool
    ) {
        self.providerName = providerName
        self.cliVersion = cliVersion
        self.adapterVersion = adapterVersion
        self.executionMode = executionMode
        self.fixtureID = fixtureID
        self.attemptState = attemptState
        self.evaluationVerdict = evaluationVerdict
        self.costRecord = costRecord
        self.streamTruncated = streamTruncated
        self.hasUnknownEvents = hasUnknownEvents
    }
}

public struct CrossProviderComparisonReport: Sendable, Equatable, Codable {
    public let fixtureID: String
    public let entries: [ProviderComparisonEntry]
    public let costSummaryByProvider: [String: AggregatedCostSummary]
    public let liveProviderVerified: Bool
}

public enum ProviderComparisonHarness {
    public static func buildReport(
        fixtureID: String,
        entries: [ProviderComparisonEntry]
    ) -> CrossProviderComparisonReport {
        let grouped = Dictionary(grouping: entries, by: \.providerName)
        let summaries = grouped.mapValues { group in
            CostAccountingEngine.aggregate(records: group.map(\.costRecord))
        }
        let hasLiveRun = !entries.isEmpty && entries.allSatisfy { $0.executionMode == .liveExternalAPI }
        return CrossProviderComparisonReport(
            fixtureID: fixtureID,
            entries: entries,
            costSummaryByProvider: summaries,
            liveProviderVerified: hasLiveRun
        )
    }
}
