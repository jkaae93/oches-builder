import Foundation
import XCTest
@testable import OchesCore

final class RawJSONKeyValidatorTests: XCTestCase {
    private func check(_ data: Data) throws {
        try validateUniqueJSONKeys(data, maximumBytes: 1024, maximumDepth: 3, maximumStringBytes: 64)
    }

    func testRejectsLimitsBeforeParsing() throws {
        XCTAssertThrowsError(try validateUniqueJSONKeys(Data("{}".utf8), maximumBytes: 1, maximumDepth: 3, maximumStringBytes: 64))
        XCTAssertThrowsError(try check(Data(#"{"a":[[[0]]]}"#.utf8)))
        XCTAssertThrowsError(try validateUniqueJSONKeys(Data(#"{"abc":0}"#.utf8), maximumBytes: 100, maximumDepth: 3, maximumStringBytes: 2))
        try check(Data(#"{"a":[[0]]}"#.utf8))
    }

    func testUniqueNestedKeysAndDistinctUnicodeSequences() throws {
        try check(Data(#"{"a":{"x":1},"b":{"x":2},"é":1,"e\u0301":2}"#.utf8))
    }

    func testRejectsDuplicateAndEscapedDuplicateAtAnyDepth() {
        for text in [#"{"a":1,"a":2}"#, #"{"nested":{"a":1,"\u0061":2}}"#] {
            XCTAssertThrowsError(try check(Data(text.utf8))) {
                XCTAssertEqual($0 as? RawJSONValidationError, .duplicateKey)
            }
        }
    }

    func testRejectsMalformedAndNonObjectInput() {
        for data in [Data(#"{"a":}"#.utf8), Data("[]".utf8), Data([0xff])] {
            XCTAssertThrowsError(try check(data))
        }
    }
}
