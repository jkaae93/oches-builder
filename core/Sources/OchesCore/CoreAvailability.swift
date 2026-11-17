/// The scaffold has no authenticated transport or operational service.
public enum CoreAvailability: Sendable, Equatable {
    case unavailable
}

public struct CoreBoundary: Sendable {
    public init() {}

    public func availability() -> CoreAvailability {
        .unavailable
    }
}
