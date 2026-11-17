import Foundation
import XCTest
@testable import OchesCore

final class ResponseEnvelopeTests: XCTestCase {
    func validate(_ text: String) throws -> ValidatedResponseEnvelope {
        let value = try validateUniqueJSONKeys(Data(text.utf8), maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024)
        return try validateResponseEnvelope(value)
    }
    func testSharedSchemaCases() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "response-cases", withExtension: "json", subdirectory: "Fixtures/envelopes"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let expected = try XCTUnwrap(item["valid"] as? Bool)
            let response = try XCTUnwrap(item["response"])
            let data = try JSONSerialization.data(withJSONObject: response)
            let value = try validateUniqueJSONKeys(data, maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024)
            if expected { XCTAssertNoThrow(try validateResponseEnvelope(value), name) }
            else { XCTAssertThrowsError(try validateResponseEnvelope(value), name) }
        }
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
