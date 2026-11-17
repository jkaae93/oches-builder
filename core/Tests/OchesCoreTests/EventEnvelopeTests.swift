import Foundation
import XCTest
@testable import OchesCore

final class EventEnvelopeTests: XCTestCase {
    func parse(_ text: String) throws -> ValidatedEventEnvelope {
        let value = try validateUniqueJSONKeys(Data(text.utf8), maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024)
        return try validateEventEnvelope(value)
    }

    func testSharedSchemaCases() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "event-cases", withExtension: "json", subdirectory: "Fixtures/envelopes"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let expected = try XCTUnwrap(item["valid"] as? Bool)
            let event = try XCTUnwrap(item["event"])
            let data = try JSONSerialization.data(withJSONObject: event)
            let value = try validateUniqueJSONKeys(data, maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024)
            if expected { XCTAssertNoThrow(try validateEventEnvelope(value), name) }
            else { XCTAssertThrowsError(try validateEventEnvelope(value), name) }
        }
    }

    func testPreservesSourceSequenceAndPayload() throws {
        let event = try parse(#"{"eventId":"e","sourceId":"s","sequence":"9007199254740993","kind":"k","payload":{"n":null}}"#)
        XCTAssertEqual(event.eventID, "e")
        XCTAssertEqual(event.sourceID, "s")
        XCTAssertEqual(event.sequence, "9007199254740993")
        XCTAssertEqual(String(decoding: try canonicalizeJSON(event.payload), as: UTF8.self), #"{"n":null}"#)
        XCTAssertEqual(String(decoding: try canonicalizeJSON(event.original), as: UTF8.self), #"{"eventId":"e","kind":"k","payload":{"n":null},"sequence":"9007199254740993","sourceId":"s"}"#)
    }

    func testRejectsInvalidSequenceAndExtraFields() {
        let base = #"{"eventId":"e","sourceId":"s","sequence":"0","kind":"k","payload":{}}"#
        for invalid in [base.replacingOccurrences(of: #""sequence":"0""#, with: #""sequence":"01""#), base.replacingOccurrences(of: #""sequence":"0""#, with: #""sequence":null"#), String(base.dropLast()) + #","cursor":"c"}"#] {
            XCTAssertThrowsError(try parse(invalid))
        }
    }
}
