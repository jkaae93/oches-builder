import Foundation
import XCTest
@testable import OchesCore

final class NativeMessagingHostGateTests: XCTestCase {
    private let validOrigin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"

    func testManifestValidationRejectsWildcardsAndInvalidOriginsAndUnknownFields() throws {
        let validManifest = NativeMessagingManifestSpec(
            name: "com.oches.builder.host",
            description: "Oches Native Messaging Host",
            path: "/Applications/Oches.app/Contents/Helpers/oches-native-host",
            type: "stdio",
            allowedOrigins: [validOrigin]
        )
        let data = try validManifest.encodeCanonicalJSON()
        let decoded = try NativeMessagingManifestSpec.parseAndValidate(jsonData: data)
        XCTAssertEqual(decoded, validManifest)

        let wildcardJSON = Data("""
        {
          "name": "com.oches.builder.host",
          "description": "Host",
          "path": "/Applications/Oches.app/Contents/Helpers/oches-native-host",
          "type": "stdio",
          "allowed_origins": ["chrome-extension://*/"]
        }
        """.utf8)
        XCTAssertThrowsError(try NativeMessagingManifestSpec.parseAndValidate(jsonData: wildcardJSON))

        let extraKeyJSON = Data("""
        {
          "name": "com.oches.builder.host",
          "description": "Host",
          "path": "/Applications/Oches.app/Contents/Helpers/oches-native-host",
          "type": "stdio",
          "allowed_origins": ["\(validOrigin)"],
          "unexpected": true
        }
        """.utf8)
        XCTAssertThrowsError(try NativeMessagingManifestSpec.parseAndValidate(jsonData: extraKeyJSON)) { error in
            XCTAssertEqual(error as? NativeMessagingError, .unknownField("unexpected"))
        }
    }

    func testNativeFramingEnforcesW1P7LimitAndPartialStreaming() throws {
        let smallPayload = Data("{\"op\":\"ping\"}".utf8)
        let framed = try NativeMessagingFraming.encodeFrame(smallPayload)

        var buffer = Data(framed.prefix(3))
        XCTAssertNil(try NativeMessagingFraming.decodeNextFrame(from: &buffer))
        buffer.append(framed.dropFirst(3))
        let out = try NativeMessagingFraming.decodeNextFrame(from: &buffer)
        XCTAssertEqual(out, smallPayload)
        XCTAssertTrue(buffer.isEmpty)

        // Exact 256 KiB succeeds
        let maxPayload = Data(repeating: 0x61, count: NativeMessagingFraming.maxPayloadBytes)
        let maxFramed = try NativeMessagingFraming.encodeFrame(maxPayload)
        var maxBuf = maxFramed
        XCTAssertEqual(try NativeMessagingFraming.decodeNextFrame(from: &maxBuf)?.count, 262_144)

        // 256 KiB + 1 byte is rejected
        let oversized = Data(repeating: 0x61, count: NativeMessagingFraming.maxPayloadBytes + 1)
        XCTAssertThrowsError(try NativeMessagingFraming.encodeFrame(oversized)) { error in
            XCTAssertEqual(error as? NativeMessagingError, .frameTooLarge(262_145))
        }

        // Crafted oversized length prefix fails BEFORE waiting for payload bytes
        var rawHeader = UInt32(262_145).littleEndian
        var crafted = Data(bytes: &rawHeader, count: 4)
        crafted.append(Data("short".utf8))
        XCTAssertThrowsError(try NativeMessagingFraming.decodeNextFrame(from: &crafted)) { error in
            XCTAssertEqual(error as? NativeMessagingError, .frameTooLarge(262_145))
        }
    }

    func testCallerGateAndHostBridgeRejectSpoofedOriginShellOpsAndClearOnDisconnect() throws {
        let manifest = NativeMessagingManifestSpec(
            name: "com.oches.builder.host",
            description: "Oches Native Messaging Host",
            path: "/usr/local/bin/oches-native-host",
            allowedOrigins: [validOrigin]
        )
        let bridge = try NativeMessagingHostBridge(manifest: manifest)

        // Missing or disallowed argv[1] origin fails
        XCTAssertThrowsError(try bridge.openPort(arguments: ["/usr/local/bin/oches-native-host"])) { error in
            XCTAssertEqual(error as? NativeMessagingError, .missingOriginArgument)
        }
        XCTAssertThrowsError(
            try bridge.openPort(arguments: ["/usr/local/bin/oches-native-host", "chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/"])
        )

        let verification = try bridge.openPort(arguments: ["/usr/local/bin/oches-native-host", validOrigin])
        // Never promoted to platformBound even when argv[1] matches allowed_origins (ADR-017)
        XCTAssertEqual(verification.trustLevel, .userEnrolledKey)
        XCTAssertTrue(verification.unprovenAgainstDirectHostExecution)

        // Body cannot override argv[1] origin
        let spoofedFrame = try NativeMessagingFraming.encodeFrame(
            Data("{\"op\":\"ping\",\"callerOrigin\":\"chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/\"}".utf8)
        )
        XCTAssertThrowsError(try bridge.receiveChunk(spoofedFrame)) { error in
            XCTAssertEqual(
                error as? NativeMessagingError,
                .originMismatch(argv: validOrigin, reported: "chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/")
            )
        }

        // Arbitrary shell operation rejected
        let shellFrame = try NativeMessagingFraming.encodeFrame(
            Data("{\"op\":\"exec_shell\",\"cmd\":\"rm -rf /\"}".utf8)
        )
        XCTAssertThrowsError(try bridge.receiveChunk(shellFrame)) { error in
            XCTAssertEqual(error as? NativeMessagingError, .unsupportedEnvelopeOperation("exec_shell"))
        }

        // Valid ping accepted; disconnect closes port and clears session
        let validFrame = try NativeMessagingFraming.encodeFrame(Data("{\"op\":\"ping\"}".utf8))
        let accepted = try bridge.receiveChunk(validFrame)
        XCTAssertEqual(accepted.count, 1)

        bridge.closePort()
        XCTAssertFalse(bridge.isPortOpen)
        XCTAssertThrowsError(try bridge.receiveChunk(validFrame)) { error in
            XCTAssertEqual(error as? NativeMessagingError, .portClosed)
        }
    }
}
