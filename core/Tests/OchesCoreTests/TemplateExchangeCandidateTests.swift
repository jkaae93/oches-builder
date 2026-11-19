import Foundation
import XCTest
@testable import OchesCore

final class TemplateExchangeCandidateTests: XCTestCase {
    private let sample = #"{"schemaVersion":{"major":1,"minor":0},"metadata":{"name":"fixture","description":"","tags":[],"useCases":[]},"nodes":[{}],"edges":[],"requirements":{"capabilities":[],"permissions":[]}}"#

    func testCanonicalEnvelopeDoesNotClaimNodeValidity() throws {
        let candidate = try TemplateExchangeCandidate.parse(Data(sample.utf8))
        XCTAssertEqual(candidate.nodes.count, 1)
        XCTAssertEqual(candidate.contentDigest, try TemplateExchangeCandidate.parse(Data(sample.replacingOccurrences(of: ":", with: " : ").utf8)).contentDigest)
    }

    func testUnknownFieldsDuplicateKeysVersionsAndSizeRejected() {
        for text in [sample.replacingOccurrences(of: "\"metadata\":", with: "\"credential\":\"fixture\",\"metadata\":"),
                     sample.replacingOccurrences(of: "\"major\":1", with: "\"major\":2"),
                     sample.replacingOccurrences(of: "\"major\":1", with: "\"major\":1.0"),
                     sample.replacingOccurrences(of: "\"edges\":[]", with: "\"edges\":[],\"edges\":[]"),
                     sample.replacingOccurrences(of: "\"nodes\":[{}]", with: "\"nodes\":[]")] {
            XCTAssertThrowsError(try TemplateExchangeCandidate.parse(Data(text.utf8)))
        }
        XCTAssertThrowsError(try TemplateExchangeCandidate.parse(Data(repeating: 32, count: 1_048_577)))
    }
}
