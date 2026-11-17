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

    func testStringLimitCountsRawEscapedBytes() throws {
        let input = Data(#"{"x":"\u0061"}"#.utf8)
        try validateUniqueJSONKeys(input, maximumBytes: 100, maximumDepth: 2, maximumStringBytes: 6)
        XCTAssertThrowsError(try validateUniqueJSONKeys(input, maximumBytes: 100, maximumDepth: 2, maximumStringBytes: 5)) {
            XCTAssertEqual($0 as? RawJSONValidationError, .limitExceeded)
        }
    }

    func testIndependentDecimalPolicyCases() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "numeric-cases", withExtension: "json", subdirectory: "Fixtures/envelopes"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(cases.count, 300)
        for item in cases {
            let token = try XCTUnwrap(item["token"] as? String)
            let expected = try XCTUnwrap(item["accepted"] as? Bool)
            let input = Data("{\"n\":\(token)}".utf8)
            if expected { XCTAssertNoThrow(try check(input), token) }
            else { XCTAssertThrowsError(try check(input), token) }
        }
    }

    func testNumericSafeBoundaryAndExponent() throws {
        for token in ["9007199254740991", "-9007199254740991", "1.25", "1e3", "-0", "5e-324", "1e-200", "9007199254740991.1"] {
            try check(Data("{\"n\":\(token)}".utf8))
        }
        for token in ["9007199254740992", "9007199254740993", "-9007199254740992", "9.007199254740992e15", "1e400", "1e-324", "-1e-324"] {
            XCTAssertThrowsError(try check(Data("{\"n\":\(token)}".utf8))) { error in
                XCTAssertEqual(error as? RawJSONValidationError, .unsafeNumber)
            }
        }
    }

    func testLongZeroExponentAndMalformedNumbers() throws {
        try check(Data(#"{"n":1e0000000000000000000000000000000000000000}"#.utf8))
        for token in ["01", "-01", "1.", ".1", "1e", "1e+", "--1", "1e2x", "+1"] {
            XCTAssertThrowsError(try check(Data("{\"n\":\(token)}".utf8)), token)
        }
    }

    func testRejectsUnboundedCallerLimits() {
        let input = Data("{}".utf8)
        XCTAssertThrowsError(try validateUniqueJSONKeys(input, maximumBytes: .max, maximumDepth: 8, maximumStringBytes: 64))
        XCTAssertThrowsError(try validateUniqueJSONKeys(input, maximumBytes: 1024, maximumDepth: .max, maximumStringBytes: 64))
        XCTAssertThrowsError(try validateUniqueJSONKeys(input, maximumBytes: 1024, maximumDepth: 8, maximumStringBytes: .max))
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

    func testIndependentInvalidJSONSuite() throws {
        let root = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/json-test-suite")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("n_") && $0.pathExtension == "json" }
        XCTAssertGreaterThan(files.count, 100)
        for file in files {
            var wrapped = Data(#"{"value":"#.utf8)
            wrapped.append(try Data(contentsOf: file))
            wrapped.append(Data("}".utf8))
            XCTAssertThrowsError(try validateUniqueJSONKeys(wrapped, maximumBytes: 1_048_576, maximumDepth: 128, maximumStringBytes: 262_144), file.lastPathComponent)
        }
    }

    func testRejectsMalformedJSONGrammar() {
        let malformed = [
            #"{"x":TRUE}"#, #"{"x":nul}"#, #"{"x":falsex}"#,
            #"{"x":1 "y":2}"#, #"{"x":1,,"y":2}"#,
            #"{"x":[,1]}"#, #"{"x":[1 2]}"#, #"{"x":{"a":1,}}"#,
            #"{"x":"\q"}"#, #"{"x":"\u12zz"}"#, #"{"x":"unterminated}"#,
            #"{"x":1} trailing"#, #"{"x":0x1}"#, #"{"x":NaN}"#
        ]
        for input in malformed { XCTAssertThrowsError(try check(Data(input.utf8)), input) }
    }

    func testRejectsMalformedAndNonObjectInput() {
        for data in [Data(#"{"a":}"#.utf8), Data(#"{"a":1,}"#.utf8), Data(#"{"a":[1,]}"#.utf8), Data(#"{"a":true false}"#.utf8), Data("[]".utf8), Data([0xff])] {
            XCTAssertThrowsError(try check(data))
        }
    }
}
