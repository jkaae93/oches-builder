import Foundation
import XCTest
@testable import OchesCore

final class ResponseEnvelopeTests: XCTestCase {
    func validate(_ text: String) throws -> ValidatedResponseEnvelope {
        let value = try validateUniqueJSONKeys(Data(text.utf8), maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024)
        return try validateResponseEnvelope(value)
    }
    func testSuccessAndError() throws {
        let ok = try validate(#"{"requestId":"r","result":{"ok":{}},"revision":{"objectId":"o","storeGeneration":"g","revision":"4"}}"#)
        XCTAssertEqual(ok.requestID, "r")
        XCTAssertEqual(ok.revision, RevisionRef(objectID: "o", storeGeneration: "g", revision: "4"))
        _ = try validate(#"{"requestId":"r","result":{"error":{"code":"UNAVAILABLE","message":"","action":""}}}"#)
    }
    func testRejectsAmbiguityAndInvalidFields() {
        for text in [#"{"requestId":"r","result":{}}"#, #"{"requestId":"r","result":{"ok":{},"error":{}}}"#, #"{"requestId":"r","result":{"error":{"code":"MYSTERY","message":"","action":""}}}"#, #"{"requestId":"r","result":{"ok":{}},"revision":null}"#] {
            XCTAssertThrowsError(try validate(text), text)
        }
    }
}
