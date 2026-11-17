import CryptoKit
import Foundation
import SQLite3

public enum ExecutionAttemptState: String, Sendable, Equatable, Codable, CaseIterable {
    case prepared = "Prepared"
    case starting = "Starting"
    case running = "Running"
    case cancelRequested = "CancelRequested"
    case succeeded = "Succeeded"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case interrupted = "Interrupted"
    case unknown = "Unknown"

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted:
            return true
        case .prepared, .starting, .running, .cancelRequested, .unknown:
            return false
        }
    }

    public var isActiveOrUncertain: Bool {
        switch self {
        case .starting, .running, .cancelRequested, .unknown:
            return true
        case .prepared, .succeeded, .failed, .cancelled, .interrupted:
            return false
        }
    }
}

public enum TaskLifecycleState: String, Sendable, Equatable, Codable {
    case ready = "Ready"
    case prepared = "Prepared"
    case running = "Running"
    case evaluating = "Evaluating"
    case succeeded = "Succeeded"
    case failed = "Failed"
    case cancelled = "Cancelled"
    case blocked = "Blocked"
}

public enum RuntimeObservationEvent: String, Sendable, Equatable, CaseIterable {
    case startRecorded = "start_recorded"
    case cancelBeforeSpawn = "cancel_before_spawn"
    case cancelRequested = "cancel_requested"
    case spawnConfirmed = "spawn_confirmed"
    case startFailureConfirmed = "start_failure_confirmed"
    case spawnOutcomeUnknown = "spawn_outcome_unknown"
    case normalExitConfirmed = "normal_exit_confirmed"
    case failureConfirmed = "failure_confirmed"
    case outcomeUnknown = "outcome_unknown"
    case interruptionConfirmed = "interruption_confirmed"
    case cancelExitConfirmed = "cancel_exit_confirmed"
    case liveProcessIdentityConfirmed = "live_process_identity_confirmed"
    case retry
    case appExit = "app_exit"
    case successAssumed = "success_assumed"
    case storageFailedStartAnyway = "storage_failed_start_anyway"
}

public enum RuntimeLifecycleError: Error, Sendable, Equatable {
    case illegalTransition(from: ExecutionAttemptState, event: RuntimeObservationEvent)
    case permissionDenied(String)
    case capabilityBlocked(String)
    case approvalRequired([ApprovalKind])
    case invalidState(String)
    case storageFailure(String)
    case resumeUnsupported(String)

    public var safeWireError: SafeWireError {
        switch self {
        case .illegalTransition, .invalidState:
            return SafeWireError(code: .conflict, detail: nil)
        case .permissionDenied:
            return SafeWireError(code: .denied, detail: nil)
        case .capabilityBlocked:
            return SafeWireError(code: .unknown, detail: nil)
        case .approvalRequired:
            return SafeWireError(code: .approvalRequired, detail: nil)
        case .storageFailure:
            return SafeWireError(code: .unavailable, detail: nil)
        case .resumeUnsupported:
            return SafeWireError(code: .unsupported, detail: nil)
        }
    }
}

/// Exact attempt state transition table matching `ARC-06.md` and `test_runtime_lifecycle.py`.
public func transitionAttemptState(
    from state: ExecutionAttemptState,
    event: RuntimeObservationEvent
) throws -> ExecutionAttemptState {
    switch (state, event) {
    case (.prepared, .startRecorded): return .starting
    case (.prepared, .cancelBeforeSpawn): return .cancelled
    case (.starting, .cancelRequested): return .cancelRequested
    case (.starting, .spawnConfirmed): return .running
    case (.starting, .startFailureConfirmed): return .failed
    case (.starting, .spawnOutcomeUnknown): return .unknown
    case (.running, .cancelRequested): return .cancelRequested
    case (.running, .normalExitConfirmed): return .succeeded
    case (.running, .failureConfirmed): return .failed
    case (.running, .outcomeUnknown): return .unknown
    case (.running, .interruptionConfirmed): return .interrupted
    case (.cancelRequested, .spawnConfirmed): return .cancelRequested
    case (.cancelRequested, .cancelExitConfirmed): return .cancelled
    case (.cancelRequested, .normalExitConfirmed): return .succeeded
    case (.cancelRequested, .failureConfirmed): return .failed
    case (.cancelRequested, .interruptionConfirmed): return .interrupted
    case (.cancelRequested, .outcomeUnknown): return .unknown
    case (.unknown, .liveProcessIdentityConfirmed): return .running
    case (.unknown, .normalExitConfirmed): return .succeeded
    case (.unknown, .failureConfirmed): return .failed
    case (.unknown, .cancelExitConfirmed): return .cancelled
    case (.unknown, .interruptionConfirmed): return .interrupted
    default:
        throw RuntimeLifecycleError.illegalTransition(from: state, event: event)
    }
}

public func derivedTaskState(for attemptState: ExecutionAttemptState) -> TaskLifecycleState {
    switch attemptState {
    case .prepared: return .prepared
    case .starting, .running, .cancelRequested: return .running
    case .succeeded: return .evaluating
    case .failed: return .failed
    case .cancelled: return .cancelled
    case .interrupted, .unknown: return .blocked
    }
}

public struct ExecutionAttemptRecord: Sendable, Equatable {
    public let attemptID: String
    public let workspaceID: String
    public let runID: String
    public let taskID: String
    public let taskRevision: RevisionRef
    public let instanceRevision: RevisionRef
    public let installationID: String
    public let accountRef: String
    public let bindingDigest: String
    public let executionRequestDigest: String
    public let snapshotID: String
    public let state: ExecutionAttemptState
    public let pid: Int32?
    public let processStartToken: String?
    public let startRequestID: String?
    public let outputTruncated: Bool
    public let droppedEventsCount: Int

    public init(
        attemptID: String,
        workspaceID: String,
        runID: String,
        taskID: String,
        taskRevision: RevisionRef,
        instanceRevision: RevisionRef,
        installationID: String,
        accountRef: String,
        bindingDigest: String,
        executionRequestDigest: String,
        snapshotID: String,
        state: ExecutionAttemptState,
        pid: Int32? = nil,
        processStartToken: String? = nil,
        startRequestID: String? = nil,
        outputTruncated: Bool = false,
        droppedEventsCount: Int = 0
    ) {
        self.attemptID = attemptID
        self.workspaceID = workspaceID
        self.runID = runID
        self.taskID = taskID
        self.taskRevision = taskRevision
        self.instanceRevision = instanceRevision
        self.installationID = installationID
        self.accountRef = accountRef
        self.bindingDigest = bindingDigest
        self.executionRequestDigest = executionRequestDigest
        self.snapshotID = snapshotID
        self.state = state
        self.pid = pid
        self.processStartToken = processStartToken
        self.startRequestID = startRequestID
        self.outputTruncated = outputTruncated
        self.droppedEventsCount = droppedEventsCount
    }
}

public struct PrepareAttemptInput: Sendable, Equatable {
    public let attemptID: String
    public let workspaceID: String
    public let runID: String
    public let taskID: String
    public let taskRevision: RevisionRef
    public let instanceRevision: RevisionRef
    public let installationID: String
    public let accountRef: String
    public let bindingDigest: String
    public let executionRequestDigest: String
    public let callerScopes: Set<PermissionScope>
    public let snapshot: CapabilitySnapshot
    public let requestedScope: CapabilityScope

    public init(
        attemptID: String = UUID().uuidString.lowercased(),
        workspaceID: String,
        runID: String,
        taskID: String,
        taskRevision: RevisionRef,
        instanceRevision: RevisionRef,
        installationID: String,
        accountRef: String,
        bindingDigest: String,
        executionRequestDigest: String,
        callerScopes: Set<PermissionScope>,
        snapshot: CapabilitySnapshot,
        requestedScope: CapabilityScope
    ) {
        self.attemptID = attemptID
        self.workspaceID = workspaceID
        self.runID = runID
        self.taskID = taskID
        self.taskRevision = taskRevision
        self.instanceRevision = instanceRevision
        self.installationID = installationID
        self.accountRef = accountRef
        self.bindingDigest = bindingDigest
        self.executionRequestDigest = executionRequestDigest
        self.callerScopes = callerScopes
        self.snapshot = snapshot
        self.requestedScope = requestedScope
    }
}

public struct StartAttemptInput: Sendable, Equatable {
    public let attemptID: String
    public let requestID: String
    public let actorID: String
    public let clientID: String
    public let executionApprovalID: String
    public let transferApprovalID: String?
    public let requiresExternalTransfer: Bool
    public let snapshot: CapabilitySnapshot
    public let requestedScope: CapabilityScope
    public let nowEpochSeconds: Int64

    public init(
        attemptID: String,
        requestID: String,
        actorID: String,
        clientID: String,
        executionApprovalID: String,
        transferApprovalID: String? = nil,
        requiresExternalTransfer: Bool = false,
        snapshot: CapabilitySnapshot,
        requestedScope: CapabilityScope,
        nowEpochSeconds: Int64
    ) {
        self.attemptID = attemptID
        self.requestID = requestID
        self.actorID = actorID
        self.clientID = clientID
        self.executionApprovalID = executionApprovalID
        self.transferApprovalID = transferApprovalID
        self.requiresExternalTransfer = requiresExternalTransfer
        self.snapshot = snapshot
        self.requestedScope = requestedScope
        self.nowEpochSeconds = nowEpochSeconds
    }
}
