import Foundation
import XCTest
@testable import OchesCore

final class MacOSXPCIdentityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTempDirectory("xpc-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func buildAdHocSignedBinary(name: String, identifier: String, sourceBody: String) throws -> URL {
        let srcURL = tempDir.appendingPathComponent("\(name).c")
        let binURL = tempDir.appendingPathComponent(name)
        try sourceBody.write(to: srcURL, atomically: true, encoding: .utf8)

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = [srcURL.path, "-o", binURL.path]
        let clangErr = Pipe()
        clang.standardError = clangErr
        try clang.run()
        clang.waitUntilExit()
        XCTAssertEqual(clang.terminationStatus, 0)

        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", identifier, binURL.path]
        sign.standardOutput = Pipe()
        sign.standardError = Pipe()
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        return binURL
    }

    func testRealMachOAdHocBinaryAndTamperedBinaryRejectedByDistributionRequirement() throws {
        let binA = try buildAdHocSignedBinary(
            name: "client_a",
            identifier: "com.oches.desktop",
            sourceBody: "#include <stdio.h>\nint main(void) { puts(\"OCHES_TEST_MARKER_TEXT_SECTION_PAYLOAD\"); return 0; }\n"
        )
        let inspector = MachOCodeSignatureInspector()
        let postureA = inspector.inspectBinary(at: binA)
        XCTAssertEqual(postureA, .adHoc(signingIdentifier: "com.oches.desktop"))

        let req = PeerIdentityRequirement(
            expectedTeamID: "TEAM123456",
            expectedSigningIdentifier: "com.oches.desktop"
        )
        // Apple-anchored distribution requirement rejects ad-hoc signed binary even with matching identifier
        XCTAssertFalse(inspector.satisfiesRequirement(req, binaryAt: binA))

        let guardA = XPCConnectionRequirementGuard(expectedLocalUID: getuid())
        try guardA.configurePeerRequirement(req)
        XCTAssertThrowsError(try guardA.evaluatePeer(.verifiedXPC(posture: postureA, effectiveUID: getuid()))) { error in
            XCTAssertEqual(error as? XPCIdentityError, .adHocSignatureRejected)
        }

        // Tamper the marker in the signed Mach-O __TEXT segment -> invalid signature rejected
        var bytes = try Data(contentsOf: binA)
        let marker = Data("OCHES_TEST_MARKER_TEXT_SECTION_PAYLOAD".utf8)
        let range = try XCTUnwrap(bytes.range(of: marker))
        bytes[range.lowerBound] ^= 0xff
        try bytes.write(to: binA)
        let tamperedPosture = inspector.inspectBinary(at: binA)
        guard case .invalid = tamperedPosture else {
            return XCTFail("Expected .invalid posture after tampering, got \(tamperedPosture)")
        }
        XCTAssertThrowsError(try guardA.evaluatePeer(.verifiedXPC(posture: tamperedPosture, effectiveUID: getuid()))) { error in
            guard case .invalidSignature = error as? XPCIdentityError else {
                return XCTFail("Expected .invalidSignature, got \(error)")
            }
        }
    }

    func testMutualTeamRequirementGuardRejectsWrongTeamWrongIdentifierDuplicatesAndDirectHost() throws {
        let req = PeerIdentityRequirement(
            expectedTeamID: "TEAM123456",
            expectedSigningIdentifier: "com.oches.desktop"
        )
        let guardConn = XPCConnectionRequirementGuard(expectedLocalUID: 501)

        // Evaluating before configuring requirement fails closed
        XCTAssertThrowsError(
            try guardConn.evaluatePeer(.verifiedXPC(posture: .distributionSigned(teamID: "TEAM123456", signingIdentifier: "com.oches.desktop"), effectiveUID: 501))
        ) { error in
            XCTAssertEqual(error as? XPCIdentityError, .missingRequirementConfiguration)
        }

        try guardConn.configurePeerRequirement(req)

        // Positive distribution control succeeds
        let verified = try guardConn.evaluatePeer(
            .verifiedXPC(posture: .distributionSigned(teamID: "TEAM123456", signingIdentifier: "com.oches.desktop"), effectiveUID: 501)
        )
        XCTAssertEqual(verified, req)

        // Different Team ID rejected
        XCTAssertThrowsError(
            try guardConn.evaluatePeer(.verifiedXPC(posture: .distributionSigned(teamID: "OTHER99999", signingIdentifier: "com.oches.desktop"), effectiveUID: 501))
        ) { error in
            XCTAssertEqual(error as? XPCIdentityError, .teamIDMismatch)
        }

        // Different signing identifier rejected
        XCTAssertThrowsError(
            try guardConn.evaluatePeer(.verifiedXPC(posture: .distributionSigned(teamID: "TEAM123456", signingIdentifier: "com.evil.desktop"), effectiveUID: 501))
        ) { error in
            XCTAssertEqual(error as? XPCIdentityError, .signingIdentifierMismatch)
        }

        // Different local UID rejected
        XCTAssertThrowsError(
            try guardConn.evaluatePeer(.verifiedXPC(posture: .distributionSigned(teamID: "TEAM123456", signingIdentifier: "com.oches.desktop"), effectiveUID: 502))
        ) { error in
            XCTAssertEqual(error as? XPCIdentityError, .teamIDMismatch)
        }

        // Direct Host invocation and UID/PID-only claims rejected
        XCTAssertThrowsError(try guardConn.evaluatePeer(.directHostInvocation(claimedOrigin: "chrome-extension://abc"))) { error in
            XCTAssertEqual(error as? XPCIdentityError, .directHostAccessRejected)
        }
        XCTAssertThrowsError(try guardConn.evaluatePeer(.uidOrPidOnly(effectiveUID: 501, pid: 1234))) { error in
            XCTAssertEqual(error as? XPCIdentityError, .uidOrPidOnlyClaimRejected)
        }

        // Configuring a second requirement fails closed and clears configured requirement
        XCTAssertThrowsError(try guardConn.configurePeerRequirement(req)) { error in
            XCTAssertEqual(error as? XPCIdentityError, .duplicateRequirementConfiguration)
        }
        XCTAssertThrowsError(
            try guardConn.evaluatePeer(.verifiedXPC(posture: .distributionSigned(teamID: "TEAM123456", signingIdentifier: "com.oches.desktop"), effectiveUID: 501))
        ) { error in
            XCTAssertEqual(error as? XPCIdentityError, .missingRequirementConfiguration)
        }
    }

    func testProtectedKeyStoreFailsClosedWithKeyUnavailableAndRevocation() throws {
        let store = ScopedProtectedKeyStore()
        let keyRec = try store.generateSigningKey(keyID: "k-sign-1")
        let payload = Data("hello-challenge".utf8)
        let sig = try store.sign(keyID: "k-sign-1", payload: payload)
        XCTAssertTrue(store.verify(publicKeyBytes: keyRec.publicKeyBytes, payload: payload, signature: sig))

        // Lock keychain -> fails with KEY_UNAVAILABLE (no plaintext fallback)
        store.setLocked(true)
        XCTAssertThrowsError(try store.sign(keyID: "k-sign-1", payload: payload)) { error in
            XCTAssertEqual((error as? KeyStoreError)?.safeWireError, SafeWireError(code: .unavailable, detail: "KEY_UNAVAILABLE"))
        }
        XCTAssertThrowsError(try store.generateNoiseStaticKey(keyID: "k-noise-1")) { error in
            XCTAssertEqual((error as? KeyStoreError)?.safeWireError, SafeWireError(code: .unavailable, detail: "KEY_UNAVAILABLE"))
        }

        // Unlock and revoke -> sign fails with keyRevoked
        store.setLocked(false)
        try store.revokeKey(keyID: "k-sign-1")
        XCTAssertThrowsError(try store.sign(keyID: "k-sign-1", payload: payload)) { error in
            XCTAssertEqual(error as? KeyStoreError, .keyRevoked)
        }
    }
}
