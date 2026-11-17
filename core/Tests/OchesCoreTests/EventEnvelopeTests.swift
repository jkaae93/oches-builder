import Foundation
import XCTest
@testable import OchesCore

final class EventEnvelopeTests: XCTestCase {
    func parse(_ text: String) throws -> ValidatedEventEnvelope {
        let value = try validateUniqueJSONKeys(Data(text.utf8), maximumBytes: 4096, maximumDepth: 8, maximumStringBytes: 1024)
        return try validateEventEnvelope(value)
    }

    func testPreservesSourceSequenceAndPayload() throws {
        let event = try parse(#"{"eventId":"e","sourceId":"s","sequence":"9007199254740993","kind":"k","payload":{"n":null}}"#)
        XCTAssertEqual(event.eventID, "e")
        XCTAssertEqual(event.sourceID, "s")
        XCTAssertEqual(event.sequence, "9007199254740993")
        XCTAssertEqual(String(decoding: try canonicalizeJSON(event.payload), as: UTF8.self), #"{"n":null}"#)
    }

    func testRejectsInvalidSequenceAndExtraFields() {
        let base = #"{"eventId":"e","sourceId":"s","sequence":"0","kind":"k","payload":{}}"#
        for invalid in [base.replacingOccurrences(of: #""sequence":"0""#, with: #""sequence":"01""#), base.replacingOccurrences(of: #""sequence":"0""#, with: #""sequence":null"#), String(base.dropLast()) + #","cursor":"c"}"#] {
            XCTAssertThrowsError(try parse(invalid))
        }
    }
}
