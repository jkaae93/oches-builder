import Foundation

public enum UnavailableWireResult: Equatable, Sendable {
    case invalidInput
    case denied
    case versionUnsupported
    case unavailable
}

/// Validation-only scaffold. A syntactically valid request remains unavailable:
/// this boundary does not represent an authenticated session or dispatch work.
public struct UnavailableWireBoundary: Sendable {
    public init() {}

    public func inspect(_ data: Data, negotiated: NegotiatedProtocol, verifiedClientID: String? = nil, maximumBytes: Int, maximumDepth: Int, maximumStringBytes: Int) -> UnavailableWireResult {
        do {
            let value = try validateUniqueJSONKeys(data, maximumBytes: maximumBytes, maximumDepth: maximumDepth, maximumStringBytes: maximumStringBytes)
            try validateRequestEnvelope(value, negotiated: negotiated, verifiedClientID: verifiedClientID)
            return .unavailable
        } catch RequestEnvelopeError.versionUnsupported {
            return .versionUnsupported
        } catch RequestEnvelopeError.clientIdentityMismatch {
            return .denied
        } catch {
            return .invalidInput
        }
    }
}
