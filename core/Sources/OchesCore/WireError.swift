/// Logical error classes. Transport-specific disclosure and operation-specific
/// actions remain subject to authorization and the owning contract.
public enum WireErrorCode: String, Sendable {
    case invalidInput = "INVALID_INPUT"
    case denied = "DENIED"
    case approvalRequired = "APPROVAL_REQUIRED"
    case conflict = "CONFLICT"
    case stale = "STALE"
    case unsupported = "UNSUPPORTED"
    case unknown = "UNKNOWN"
    case indeterminate = "INDETERMINATE"
    case unavailable = "UNAVAILABLE"
    case cursorExpired = "CURSOR_EXPIRED"
    case idempotencyExpired = "IDEMPOTENCY_EXPIRED"
}

public struct SafeWireError: Equatable, Sendable {
    public let code: WireErrorCode
    public let detail: String?
}

public extension UnavailableWireResult {
    /// Fixed category only: never reflects untrusted input or exception text.
    var safeError: SafeWireError {
        switch self {
        case .invalidInput: return SafeWireError(code: .invalidInput, detail: nil)
        case .denied: return SafeWireError(code: .denied, detail: nil)
        case .versionUnsupported: return SafeWireError(code: .unsupported, detail: "VERSION_UNSUPPORTED")
        case .unavailable: return SafeWireError(code: .unavailable, detail: nil)
        }
    }
}
