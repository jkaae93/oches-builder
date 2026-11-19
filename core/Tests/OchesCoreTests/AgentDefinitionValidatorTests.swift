import Foundation
import XCTest
@testable import OchesCore

final class AgentDefinitionValidatorTests: XCTestCase {
    private let sample = #"{"schemaVersion":{"major":1,"minor":0},"definitionId":"agent-1","revision":1,"role":"reviewer","instructions":"Review only","inputs":[{"portId":"source","type":"text","required":true}],"outputs":[],"tools":[],"permissions":[],"resourceLimits":{"maxDurationSeconds":60,"maxAttempts":1}}"#

    func testValidDefinitionHasStableCanonicalDigest() throws {
        let first = try AgentDefinitionValidator.validate(Data(sample.utf8))
        let spaced = sample.replacingOccurrences(of: ":", with: " : ")
        let second = try AgentDefinitionValidator.validate(Data(spaced.utf8))
        XCTAssertEqual(first.definitionID, "agent-1")
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(first.digest, second.digest)
    }

    func testRejectsUnknownFieldsDuplicateKeysAndUnsupportedVersions() {
        let bad = [
            sample.replacingOccurrences(of: "\"role\":", with: "\"credential\":\"secret\",\"role\":"),
            sample.replacingOccurrences(of: "\"role\":", with: "\"role\":\"other\",\"role\":"),
            sample.replacingOccurrences(of: "\"major\":1", with: "\"major\":2"),
            sample.replacingOccurrences(of: "\"minor\":0", with: "\"minor\":1"),
            sample.replacingOccurrences(of: "\"revision\":1", with: "\"revision\":1.0"),
            sample.replacingOccurrences(of: "\"maxAttempts\":1", with: "\"maxAttempts\":0"),
            sample.replacingOccurrences(of: "\"maxDurationSeconds\":60", with: "\"maxDurationSeconds\":86401"),
            sample.replacingOccurrences(of: "\"type\":\"text\"", with: "\"type\":\"executable\""),
            sample.replacingOccurrences(of: "\"required\":true", with: "\"required\":1"),
        ]
        for input in bad { XCTAssertThrowsError(try AgentDefinitionValidator.validate(Data(input.utf8))) }
    }

    func testRejectsDuplicatePortsAndTools() {
        let port = #"{"portId":"source","type":"text","required":true}"#
        for input in [sample.replacingOccurrences(of: port, with: port + "," + port),
                      sample.replacingOccurrences(of: "\"tools\":[]", with: "\"tools\":[\"read\",\"read\"]")] {
            XCTAssertThrowsError(try AgentDefinitionValidator.validate(Data(input.utf8)))
        }
    }

    func testRejectsOversizedDocumentAndBlankInstructions() {
        XCTAssertThrowsError(try AgentDefinitionValidator.validate(Data(repeating: 32, count: 262_145)))
        XCTAssertThrowsError(try AgentDefinitionValidator.validate(Data(sample.replacingOccurrences(of: "Review only", with: "   ").utf8)))
    }
}
