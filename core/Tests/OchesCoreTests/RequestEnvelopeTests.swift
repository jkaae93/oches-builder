import Foundation
import XCTest
@testable import OchesCore

final class RequestEnvelopeTests: XCTestCase {
    let version = NegotiatedProtocol(major: 1, minor: 0, capabilities: [])
    func validate(_ text: String) throws {
        let value = try validateUniqueJSONKeys(Data(text.utf8), maximumBytes: 4096, maximumDepth: 16, maximumStringBytes: 1024)
        try validateRequestEnvelope(value, negotiated: version)
    }
    func testValidAndOptionalRevision() throws {
        try validate(#"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"query","payload":{}}"#)
        try validate(#"{"protocolMajor":1,"protocolMinor":0,"clientId":"c","workspaceId":"w","requestId":"r","operation":"write","payload":{},"expectedRevision":{"objectId":"o","storeGeneration":"g","revision":"12"}}"#)
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
