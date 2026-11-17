import Foundation
import XCTest
@testable import OchesCore

final class RawJSONKeyValidatorTests: XCTestCase {
    func testUniqueNestedKeysAndDistinctUnicodeSequences() throws {
        try validateUniqueJSONKeys(Data(#"{"a":{"x":1},"b":{"x":2},"é":1,"e\u0301":2}"#.utf8))
    }

    func testRejectsDuplicateAndEscapedDuplicateAtAnyDepth() {
        for text in [#"{"a":1,"a":2}"#, #"{"nested":{"a":1,"\u0061":2}}"#] {
            XCTAssertThrowsError(try validateUniqueJSONKeys(Data(text.utf8))) {
                XCTAssertEqual($0 as? RawJSONValidationError, .duplicateKey)
            }
        }
    }

    func testRejectsMalformedAndNonObjectInput() {
        for data in [Data(#"{"a":}"#.utf8), Data("[]".utf8), Data([0xff])] {
            XCTAssertThrowsError(try validateUniqueJSONKeys(data))
        }
    }
}
