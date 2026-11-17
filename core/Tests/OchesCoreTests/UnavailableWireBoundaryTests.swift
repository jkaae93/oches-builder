import Foundation
import XCTest
@testable import OchesCore

final class UnavailableWireBoundaryTests: XCTestCase {
    func testValidRequestsNeverBecomeSuccessWithoutService() {
        let request = Data(#"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"run","payload":{}}"#.utf8)
        let version = NegotiatedProtocol(major: 1, minor: 0, capabilities: [])
        let boundary = UnavailableWireBoundary()
        XCTAssertEqual(boundary.inspect(request, negotiated: version, maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024), .unavailable)
        XCTAssertEqual(boundary.inspect(request, negotiated: version, maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024), .unavailable)
    }

    func testRejectsDuplicateAndUnsupportedVersion() {
        let boundary = UnavailableWireBoundary()
        let version = NegotiatedProtocol(major: 1, minor: 0, capabilities: [])
        let duplicate = Data(#"{"protocolMajor":1,"protocolMajor":1}"#.utf8)
        XCTAssertEqual(boundary.inspect(duplicate, negotiated: version, maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024), .invalidInput)
        let mismatch = Data(#"{"protocolMajor":2,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"q","payload":{}}"#.utf8)
        XCTAssertEqual(boundary.inspect(mismatch, negotiated: version, maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024), .versionUnsupported)
    }
}
