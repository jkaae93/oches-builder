import Foundation
import XCTest
@testable import OchesCore

final class RequestEnvelopeTests: XCTestCase {
    let version = NegotiatedProtocol(major: 1, minor: 0, capabilities: [])
    func validate(_ text: String) throws {
        let value = try validateUniqueJSONKeys(Data(text.utf8), maximumBytes: 4096, maximumDepth: 16, maximumStringBytes: 1024)
        try validateRequestEnvelope(value, negotiated: version)
    }
    func testSharedSchemaCases() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "request-cases", withExtension: "json", subdirectory: "Fixtures/envelopes"))
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let expected = try XCTUnwrap(item["valid"] as? Bool)
            let request = try XCTUnwrap(item["request"])
            let data = try JSONSerialization.data(withJSONObject: request)
            let value = try validateUniqueJSONKeys(data, maximumBytes: 4096, maximumDepth: 16, maximumStringBytes: 1024)
            if expected {
                XCTAssertNoThrow(try validateRequestEnvelope(value, negotiated: version), name)
            } else {
                XCTAssertThrowsError(try validateRequestEnvelope(value, negotiated: version), name)
            }
        }
    }

    func testValidAndOptionalRevision() throws {
        try validate(#"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"query","payload":{}}"#)
        try validate(#"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"write","payload":{},"expectedRevision":{"objectId":"o","storeGeneration":"g","revision":"12"}}"#)
    }
    func testValidatedRevisionIncludesGeneration() throws {
        let request = #"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"write","payload":{},"expectedRevision":{"objectId":"o","storeGeneration":"g1","revision":"12"}}"#
        func reference(_ text: String) throws -> RevisionRef? {
            let value = try validateUniqueJSONKeys(Data(text.utf8), maximumBytes: 4096, maximumDepth: 16, maximumStringBytes: 1024)
            return try validateRequestEnvelope(value, negotiated: version)
        }
        XCTAssertEqual(try reference(request), RevisionRef(objectID: "o", storeGeneration: "g1", revision: "12"))
        XCTAssertNotEqual(try reference(request), try reference(request.replacingOccurrences(of: "g1", with: "g2")))
    }

    func testRevisionRequiresCanonicalDecimalString() throws {
        let base = #"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"write","payload":{},"expectedRevision":{"objectId":"o","storeGeneration":"g","revision":"0"}}"#
        try validate(base)
        for revision in ["00", "-1", "1\\n", "1a"] {
            XCTAssertThrowsError(try validate(base.replacingOccurrences(of: #""revision":"0""#, with: "\"revision\":\"\(revision)\"")))
        }
    }

    func testVersionCannotRoundFractionToInteger() throws {
        let base = #"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"q","payload":{}}"#
        try validate(base.replacingOccurrences(of: #""protocolMajor":1"#, with: #""protocolMajor":1.0"#))
        XCTAssertThrowsError(try validate(base.replacingOccurrences(of: #""protocolMajor":1"#, with: #""protocolMajor":1.00000000000000000001"#)))
        XCTAssertThrowsError(try validate(base.replacingOccurrences(of: #""protocolMinor":0"#, with: #""protocolMinor":0.00000000000000000001"#)))
        XCTAssertThrowsError(try validate(base.replacingOccurrences(of: #""protocolMajor":1"#, with: #""protocolMajor":1.0000000000000000000000000000000000000001"#)))
    }

    func testNullOmissionUnknownAndVersionMismatch() {
        let base = #"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"q","payload":{}}"#
        for invalid in [base.replacingOccurrences(of: #","requestId":"r""#, with: ""), base.replacingOccurrences(of: #""payload":{}"#, with: #""payload":null"#), String(base.dropLast()) + #","unknown":true}"#] {
            XCTAssertThrowsError(try validate(invalid))
        }
        XCTAssertThrowsError(try validate(base.replacingOccurrences(of: #""protocolMajor":1"#, with: #""protocolMajor":2"#))) {
            XCTAssertEqual($0 as? RequestEnvelopeError, .versionUnsupported)
        }
    }
}
