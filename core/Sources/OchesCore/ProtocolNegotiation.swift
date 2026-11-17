/// A peer's supported minor range for one protocol major.
public struct ProtocolOffer: Sendable, Equatable {
    public let major: UInt32
    public let minimumMinor: UInt32
    public let maximumMinor: UInt32
    public let capabilities: Set<String>

    public init(major: UInt32, minimumMinor: UInt32, maximumMinor: UInt32, capabilities: Set<String>) {
        self.major = major
        self.minimumMinor = minimumMinor
        self.maximumMinor = maximumMinor
        self.capabilities = capabilities
    }
}

public struct NegotiatedProtocol: Sendable, Equatable {
    public let major: UInt32
    public let minor: UInt32
    public let capabilities: Set<String>
}

public enum ProtocolNegotiationError: Error, Equatable {
    case invalidRange
    case versionUnsupported
}

/// Call only after a transport has authenticated the peer.
public func negotiateProtocol(local: ProtocolOffer, remote: ProtocolOffer) throws -> NegotiatedProtocol {
    guard local.minimumMinor <= local.maximumMinor, remote.minimumMinor <= remote.maximumMinor else {
        throw ProtocolNegotiationError.invalidRange
    }
    guard local.major == remote.major else { throw ProtocolNegotiationError.versionUnsupported }
    let lower = max(local.minimumMinor, remote.minimumMinor)
    let upper = min(local.maximumMinor, remote.maximumMinor)
    guard lower <= upper else { throw ProtocolNegotiationError.versionUnsupported }
    return NegotiatedProtocol(major: local.major, minor: upper, capabilities: local.capabilities.intersection(remote.capabilities))
}
