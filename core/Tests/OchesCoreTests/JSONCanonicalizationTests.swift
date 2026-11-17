import Foundation
import XCTest
@testable import OchesCore

final class JSONCanonicalizationTests: XCTestCase {
    func parse(_ text: String) throws -> RawJSONValue {
        try validateUniqueJSONKeys(Data(text.utf8), maximumBytes: 4096, maximumDepth: 16, maximumStringBytes: 1024)
    }

    func testRFC8785Example() throws {
        let input = #"{"numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001],"string":"€$\u000f\nA'B\"\\\"/","literals":[null,true,false]}"#
        // The wire's provisional safe-number restriction rejects 1E30;
        // construct the RFC value directly to exercise serialization.
        _ = input
        let value: RawJSONValue = .object([
            ("numbers", .array([.number("333333333.33333329"), .number("1E30"), .number("4.50"), .number("2e-3"), .number("0.000000000000000000000000001")])),
            ("string", .string("€$\u{000f}\nA'B\"\\\"/")),
            ("literals", .array([.null, .bool(true), .bool(false)]))
        ])
        XCTAssertEqual(String(decoding: try canonicalizeJSON(value), as: UTF8.self), #"{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\"/"}"#)
    }

    func testUnicodeKeysRemainDistinctAndSortByUTF16() throws {
        let value = try parse(#"{"é":1,"e\u0301":2,"\uE000":3,"😀":4}"#)
        XCTAssertEqual(String(decoding: try canonicalizeJSON(value), as: UTF8.self), "{\"e\u{301}\":2,\"é\":1,\"😀\":4,\"\u{e000}\":3}")
    }

    func testNegativeZeroAndDigest() throws {
        let value = try parse(#"{"n":-0}"#)
        XCTAssertEqual(String(decoding: try canonicalizeJSON(value), as: UTF8.self), #"{"n":0}"#)
        XCTAssertEqual(try canonicalSHA256(value).map { String(format: "%02x", $0) }.joined(), "f3013f933b9fb80ab6d995e7ad9da36f683837ba1d81e950c943d40111eac2f0")
    }
}
