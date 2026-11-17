import Foundation
import XCTest
@testable import OchesCore

final class RawJSONKeyValidatorTests: XCTestCase {
    private func check(_ data: Data) throws {
        try validateUniqueJSONKeys(data, maximumBytes: 1024, maximumDepth: 3, maximumStringBytes: 64)
    }

    func testUnicodeSurrogatesAndStringLimits() throws {
        try check(Data(#"{"x":"\uD83D\uDE00"}"#.utf8))
        for text in [#"{"x":"\uD800"}"#, #"{"x":"\uDC00"}"#] {
            XCTAssertThrowsError(try check(Data(text.utf8)))
        }
        try validateUniqueJSONKeys(Data(#"{"abc":"xyz"}"#.utf8), maximumBytes: 100, maximumDepth: 2, maximumStringBytes: 3)
        XCTAssertThrowsError(try validateUniqueJSONKeys(Data(#"{"abc":"xyzz"}"#.utf8), maximumBytes: 100, maximumDepth: 2, maximumStringBytes: 3))
    }

    func testNumericSafeBoundaryAndExponent() throws {
        for token in ["9007199254740991", "-9007199254740991", "1.25", "1e3", "-0"] {
            try check(Data("{\"n\":\(token)}".utf8))
        }
        for token in ["9007199254740992", "9007199254740993", "-9007199254740992", "9.007199254740992e15", "1e400", "9007199254740991.000000000000000000000000000000000001"] {
            XCTAssertThrowsError(try check(Data("{\"n\":\(token)}".utf8))) { error in
                XCTAssertEqual(error as? RawJSONValidationError, .unsafeNumber)
            }
        }
    }

    func testRejectsLimitsBeforeParsing() throws {
        XCTAssertThrowsError(try validateUniqueJSONKeys(Data("{}".utf8), maximumBytes: 1, maximumDepth: 3, maximumStringBytes: 64))
        XCTAssertThrowsError(try check(Data(#"{"a":[[[0]]]}"#.utf8)))
        XCTAssertThrowsError(try validateUniqueJSONKeys(Data(#"{"abc":0}"#.utf8), maximumBytes: 100, maximumDepth: 3, maximumStringBytes: 2))
        try check(Data(#"{"a":[[0]]}"#.utf8))
    }

    func testUniqueNestedKeysAndDistinctUnicodeSequences() throws {
        try check(Data(#"{"a":{"x":1},"b":{"x":2}}"#.utf8))
        let value = try validateUniqueJSONKeys(Data(#"{"é":1,"e\u0301":2}"#.utf8), maximumBytes: 1024, maximumDepth: 3, maximumStringBytes: 64)
        guard case .object(let members) = value else { return XCTFail("expected object") }
        XCTAssertEqual(members.count, 2)
        XCTAssertNotEqual(Array(members[0].0.utf8), Array(members[1].0.utf8))
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
