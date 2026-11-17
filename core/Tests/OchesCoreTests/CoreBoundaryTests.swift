import XCTest
@testable import OchesCore

final class CoreBoundaryTests: XCTestCase {
    func testUnconfiguredCoreIsUnavailable() {
        XCTAssertEqual(CoreBoundary().availability(), .unavailable)
    }
}
