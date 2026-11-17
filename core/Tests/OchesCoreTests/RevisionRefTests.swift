import XCTest
@testable import OchesCore

final class RevisionRefTests: XCTestCase {
    func testAllComponentsAndUnicodeBytesMatter() {
        let base = RevisionRef(objectID: "é", storeGeneration: "g1", revision: "12")
        XCTAssertEqual(base, RevisionRef(objectID: "é", storeGeneration: "g1", revision: "12"))
        XCTAssertNotEqual(base, RevisionRef(objectID: "e\u{301}", storeGeneration: "g1", revision: "12"))
        XCTAssertNotEqual(base, RevisionRef(objectID: "é", storeGeneration: "g2", revision: "12"))
        XCTAssertNotEqual(base, RevisionRef(objectID: "é", storeGeneration: "g1", revision: "13"))
    }
}
