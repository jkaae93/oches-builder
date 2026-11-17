import XCTest
@testable import OchesCore

final class ProtocolNegotiationTests: XCTestCase {
    func testHighestCommonMinorAndCapabilityIntersection() throws {
        let local = ProtocolOffer(major: 1, minimumMinor: 0, maximumMinor: 4, capabilities: ["read", "write"])
        let remote = ProtocolOffer(major: 1, minimumMinor: 2, maximumMinor: 6, capabilities: ["read", "other"])
        let result = try negotiateProtocol(local: local, remote: remote)
        XCTAssertEqual(result.minor, 4)
        XCTAssertEqual(result.capabilities, ["read"])
    }

    func testIncompatibleAndInvalidRangesReject() {
        let base = ProtocolOffer(major: 1, minimumMinor: 1, maximumMinor: 2, capabilities: [])
        for remote in [
            ProtocolOffer(major: 2, minimumMinor: 1, maximumMinor: 2, capabilities: []),
            ProtocolOffer(major: 1, minimumMinor: 3, maximumMinor: 4, capabilities: []),
        ] {
            XCTAssertThrowsError(try negotiateProtocol(local: base, remote: remote)) {
                XCTAssertEqual($0 as? ProtocolNegotiationError, .versionUnsupported)
            }
        }
        let invalid = ProtocolOffer(major: 1, minimumMinor: 3, maximumMinor: 2, capabilities: [])
        XCTAssertThrowsError(try negotiateProtocol(local: base, remote: invalid)) {
            XCTAssertEqual($0 as? ProtocolNegotiationError, .invalidRange)
        }
    }
}
