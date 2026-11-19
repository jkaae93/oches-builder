import CryptoKit
import Foundation
import XCTest
@testable import OchesCore

final class NoiseIKChannelTests: XCTestCase {
    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func dataFromHex(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            bytes.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        return Data(bytes)
    }

    func testCrossImplementationNoiseIKVectorsSwiftCryptoKitMatchesNodeOpenSSL() throws {
        let iStatic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let iEphem = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let rStatic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x33, count: 32))
        let rEphem = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x44, count: 32))

        let prologue = try NoisePrologueInput(
            protocolMajor: 1,
            coreID: "core-macos-1",
            clientID: "chrome-ext-1",
            enrollmentGeneration: 1,
            clientRole: "chrome_mv3"
        ).computePrologueHash()

        let initiator = try NoiseIKHandshakeInitiator(
            localStatic: iStatic,
            remoteStaticPublic: rStatic.publicKey,
            prologueHash: prologue,
            ephemeralOverride: iEphem
        )
        let responder = try NoiseIKHandshakeResponder(
            localStatic: rStatic,
            prologueHash: prologue,
            ephemeralOverride: rEphem
        )

        let msg1 = try initiator.writeMessage1()
        let decodedStatic = try responder.readMessage1(msg1) { rs in
            guard rs == iStatic.publicKey.rawRepresentation else { throw NoiseChannelError.staticKeyMismatch }
        }
        XCTAssertEqual(decodedStatic, iStatic.publicKey.rawRepresentation)

        let (msg2, respSession) = try responder.writeMessage2()
        let initSession = try initiator.readMessage2(msg2)
        XCTAssertEqual(initSession.handshakeHash, respSession.handshakeHash)

        let plaintext = Data("oches-noise-ik-cross-vector-v1".utf8)
        let swiftFrames = try initSession.sendLogicalMessage(plaintext, logicalMessageID: 1, padTo4KiB: true)
        XCTAssertEqual(swiftFrames.count, 1)

        // Compare byte-for-byte with independent Node.js OpenSSL reference implementation
        let scriptPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/noise_ik_reference.mjs")
            .path

        let payload: [String: String] = [
            "initiatorStaticPrivHex": hexString(iStatic.rawRepresentation),
            "initiatorEphemPrivHex": hexString(iEphem.rawRepresentation),
            "responderStaticPrivHex": hexString(rStatic.rawRepresentation),
            "responderEphemPrivHex": hexString(rEphem.rawRepresentation),
            "prologueHashHex": hexString(prologue),
            "plaintextHex": hexString(plaintext),
            "externalFrameHex": hexString(swiftFrames[0]),
        ]
        let inputData = try JSONSerialization.data(withJSONObject: payload)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", scriptPath, "--stdin-json"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        try process.run()
        stdinPipe.fileHandleForWriting.write(inputData)
        try stdinPipe.fileHandleForWriting.close()
        let nodeOutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let nodeJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: nodeOutData) as? [String: String])
        XCTAssertEqual(hexString(msg1), nodeJSON["msg1Hex"])
        XCTAssertEqual(hexString(msg2), nodeJSON["msg2Hex"])
        XCTAssertEqual(hexString(initSession.handshakeHash), nodeJSON["handshakeHashHex"])
        XCTAssertEqual(hexString(swiftFrames[0]), nodeJSON["frame0Hex"])
        XCTAssertEqual(nodeJSON["externalDecryptedHex"], hexString(plaintext))

        // Swift decrypts Node-produced encrypted frame cleanly
        let nodeFrame = dataFromHex(try XCTUnwrap(nodeJSON["frame0Hex"]))
        let received = try respSession.receiveFrame(nodeFrame, require4KiBPadding: true)
        XCTAssertEqual(received?.logicalMessageID, 1)
        XCTAssertEqual(received?.completeBody, plaintext)
    }

    func testNoiseIKRejects0RTTWrongKeysTamperedPrologueBadChunksAndOver256KiB() throws {
        let iStatic = Curve25519.KeyAgreement.PrivateKey()
        let rStatic = Curve25519.KeyAgreement.PrivateKey()
        let wrongStatic = Curve25519.KeyAgreement.PrivateKey()

        let prologue = try NoisePrologueInput(
            protocolMajor: 1, coreID: "core-1", clientID: "client-1", enrollmentGeneration: 1, clientRole: "vscode"
        ).computePrologueHash()
        let badPrologue = try NoisePrologueInput(
            protocolMajor: 1, coreID: "core-1", clientID: "client-1", enrollmentGeneration: 2, clientRole: "vscode"
        ).computePrologueHash()

        // 1. 0-RTT payload injected into msg1 -> zeroRTTForbidden
        let init0 = try NoiseIKHandshakeInitiator(localStatic: iStatic, remoteStaticPublic: rStatic.publicKey, prologueHash: prologue)
        let msg1With0RTT = try init0.writeMessage1() + Data([0x01])
        let resp0 = try NoiseIKHandshakeResponder(localStatic: rStatic, prologueHash: prologue)
        XCTAssertThrowsError(try resp0.readMessage1(msg1With0RTT) { _ in }) {
            XCTAssertEqual($0 as? NoiseChannelError, .zeroRTTForbidden)
        }

        // 2. Wrong static key or tampered prologue fails handshake
        let initBadPrologue = try NoiseIKHandshakeInitiator(localStatic: iStatic, remoteStaticPublic: rStatic.publicKey, prologueHash: badPrologue)
        let msg1BadPrologue = try initBadPrologue.writeMessage1()
        let respGood = try NoiseIKHandshakeResponder(localStatic: rStatic, prologueHash: prologue)
        XCTAssertThrowsError(try respGood.readMessage1(msg1BadPrologue) { _ in })

        let initWrongStatic = try NoiseIKHandshakeInitiator(localStatic: wrongStatic, remoteStaticPublic: rStatic.publicKey, prologueHash: prologue)
        let msg1WrongStatic = try initWrongStatic.writeMessage1()
        let respExpected = try NoiseIKHandshakeResponder(localStatic: rStatic, prologueHash: prologue)
        XCTAssertThrowsError(try respExpected.readMessage1(msg1WrongStatic) { rs in
            guard rs == iStatic.publicKey.rawRepresentation else { throw NoiseChannelError.staticKeyMismatch }
        }) { XCTAssertEqual($0 as? NoiseChannelError, .staticKeyMismatch) }

        // 3. Multi-chunk 130 KiB payload splits into 3 chunks <= 60 KiB plaintext and reassembles cleanly
        let init1 = try NoiseIKHandshakeInitiator(localStatic: iStatic, remoteStaticPublic: rStatic.publicKey, prologueHash: prologue)
        let resp1 = try NoiseIKHandshakeResponder(localStatic: rStatic, prologueHash: prologue)
        let m1 = try init1.writeMessage1()
        _ = try resp1.readMessage1(m1) { _ in }
        let (m2, sResp) = try resp1.writeMessage2()
        let sInit = try init1.readMessage2(m2)

        let largePayload = Data(repeating: 0x4b, count: 130_000)
        let frames = try sInit.sendLogicalMessage(largePayload, logicalMessageID: 42, padTo4KiB: true)
        XCTAssertEqual(frames.count, 3)
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.count, NoiseIKProtocol.maxNoiseFrameBytes)
        }
        XCTAssertNil(try sResp.receiveFrame(frames[0], require4KiBPadding: true))
        XCTAssertNil(try sResp.receiveFrame(frames[1], require4KiBPadding: true))
        let reassembled = try sResp.receiveFrame(frames[2], require4KiBPadding: true)
        XCTAssertEqual(reassembled?.logicalMessageID, 42)
        XCTAssertEqual(reassembled?.completeBody, largePayload)

        // Over 256 KiB rejected
        XCTAssertThrowsError(try sInit.sendLogicalMessage(Data(repeating: 1, count: NoiseIKProtocol.maxLogicalMessageBytes + 1), logicalMessageID: 43, padTo4KiB: false)) {
            XCTAssertEqual($0 as? NoiseChannelError, .messageTooLarge)
        }

        // 4. Wire frame reordering fails AEAD & closes channel; logical chunk interleaving fails chunkOrderMismatch & closes channel
        let c0 = try sInit.sendSingleChunkForTesting(logicalMessageID: 44, chunkIndex: 0, isFinal: false, body: Data("part0".utf8))
        let badOrder = try sInit.sendSingleChunkForTesting(logicalMessageID: 44, chunkIndex: 2, isFinal: true, body: Data("part2".utf8))
        XCTAssertNil(try sResp.receiveFrame(c0))
        XCTAssertThrowsError(try sResp.receiveFrame(badOrder)) {
            XCTAssertEqual($0 as? NoiseChannelError, .chunkOrderMismatch)
        }
        XCTAssertTrue(sResp.isClosed)
        XCTAssertThrowsError(try sResp.receiveFrame(c0)) {
            XCTAssertEqual($0 as? NoiseChannelError, .channelClosed)
        }
    }

    func testEnrolledKeyLifecycleComparisonLimitKeyUnavailableAndDesktopPerRequestApproval() throws {
        let dir = try makeTempDirectory("enrolled-noise-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try SQLiteStore(path: dir.appendingPathComponent("db").path, workspaceID: "ws", initialStoreGeneration: "gen")
        let enforcer = try AuthorizationEnforcer(store: store)
        let authority = try EnrolledKeyChannelAuthority(store: store, coreID: "core-macos-1")

        let clientSigningKey = Curve25519.Signing.PrivateKey()
        let clientNoiseKey = Curve25519.KeyAgreement.PrivateKey()
        let coreNoisePubB64 = authority.coreNoiseStaticPrivateKey.publicKey.rawRepresentation.base64EncodedString()

        // 1. Key vault unavailable fails closed (0 plaintext fallback)
        let unavailableVault = InMemorySecureKeyVault(available: false)
        XCTAssertThrowsError(try unavailableVault.storeKeyMaterial(keyID: "k1", bytes: clientNoiseKey.rawRepresentation)) {
            XCTAssertEqual($0 as? NoiseChannelError, .keyUnavailable)
        }

        // 2. T7 5-attempt comparison code lockout
        try authority.startEnrollmentChallenge(challengeID: "chal-lock", clientID: "ext-lock", comparisonCode: "123456", nowEpochSeconds: 100)
        let lockTranscript = EnrollmentTranscript(
            coreID: "core-macos-1", coreNoiseStaticPublicKeyBase64: coreNoisePubB64,
            clientID: "ext-lock", clientRole: "chrome_mv3", workspaceID: "ws",
            clientSigningKeyID: "sig-lock", clientSigningPublicKeyBase64: clientSigningKey.publicKey.rawRepresentation.base64EncodedString(),
            clientNoiseStaticKeyID: "noise-lock", clientNoiseStaticPublicKeyBase64: clientNoiseKey.publicKey.rawRepresentation.base64EncodedString(),
            permissions: [.workspaceRead], enrollmentGeneration: 1, nonce: "n-lock"
        )
        var popPayload = try lockTranscript.computeDigest()
        popPayload.append(Data("n-lock".utf8))
        let lockPop = try clientSigningKey.signature(for: popPayload).base64EncodedString()

        for attempt in 1...4 {
            XCTAssertThrowsError(try authority.completeEnrollment(
                challengeID: "chal-lock", presentedComparisonCode: "wrong-\(attempt)",
                transcript: lockTranscript, clientProofSignatureBase64: lockPop,
                desktopTrustedUIConfirmed: true, nowEpochSeconds: 101
            )) { XCTAssertEqual($0 as? NoiseChannelError, .denied("comparison code mismatch")) }
        }
        XCTAssertThrowsError(try authority.completeEnrollment(
            challengeID: "chal-lock", presentedComparisonCode: "wrong-5",
            transcript: lockTranscript, clientProofSignatureBase64: lockPop,
            desktopTrustedUIConfirmed: true, nowEpochSeconds: 102
        )) { XCTAssertEqual($0 as? NoiseChannelError, .comparisonAttemptsExceeded) }
        // Even correct code is locked out after 5 attempts
        XCTAssertThrowsError(try authority.completeEnrollment(
            challengeID: "chal-lock", presentedComparisonCode: "123456",
            transcript: lockTranscript, clientProofSignatureBase64: lockPop,
            desktopTrustedUIConfirmed: true, nowEpochSeconds: 103
        )) { XCTAssertEqual($0 as? NoiseChannelError, .comparisonAttemptsExceeded) }

        // 3. Valid enrollment (USER_ENROLLED_KEY, separated keys) + Noise handshake + Desktop per-request approval
        try authority.startEnrollmentChallenge(challengeID: "chal-ok", clientID: "ext-1", comparisonCode: "654321", nowEpochSeconds: 200)
        let transcript = EnrollmentTranscript(
            coreID: "core-macos-1", coreNoiseStaticPublicKeyBase64: coreNoisePubB64,
            clientID: "ext-1", clientRole: "chrome_mv3", workspaceID: "ws",
            clientSigningKeyID: "sig-1", clientSigningPublicKeyBase64: clientSigningKey.publicKey.rawRepresentation.base64EncodedString(),
            clientNoiseStaticKeyID: "noise-1", clientNoiseStaticPublicKeyBase64: clientNoiseKey.publicKey.rawRepresentation.base64EncodedString(),
            permissions: [.workspaceRead, .runRequest], enrollmentGeneration: 1, nonce: "n-enroll"
        )
        var okPop = try transcript.computeDigest()
        okPop.append(Data("n-enroll".utf8))
        let receipt = try authority.completeEnrollment(
            challengeID: "chal-ok", presentedComparisonCode: "654321",
            transcript: transcript, clientProofSignatureBase64: try clientSigningKey.signature(for: okPop).base64EncodedString(),
            desktopTrustedUIConfirmed: true, nowEpochSeconds: 201
        )
        XCTAssertEqual(receipt.record.trustLevel, .userEnrolledKey)
        XCTAssertEqual(receipt.record.enrollmentGeneration, 1)

        let prologue1 = try NoisePrologueInput(
            protocolMajor: 1, coreID: "core-macos-1", clientID: "ext-1", enrollmentGeneration: 1, clientRole: "chrome_mv3"
        ).computePrologueHash()
        let cliInit = try NoiseIKHandshakeInitiator(
            localStatic: clientNoiseKey,
            remoteStaticPublic: authority.coreNoiseStaticPrivateKey.publicKey,
            prologueHash: prologue1
        )
        let (msg2, coreSession) = try authority.acceptNoiseHandshake(
            clientID: "ext-1", protocolMajor: 1, message1: try cliInit.writeMessage1(), nowEpochSeconds: 210
        )
        let cliSession = try cliInit.readMessage2(msg2)
        XCTAssertEqual(cliSession.handshakeHash, coreSession.handshakeHash)

        let commandPayload: RawJSONValue = .object([("action", .string("run.start")), ("taskID", .string("t1"))])
        let tamperedPayload: RawJSONValue = .object([("action", .string("run.start")), ("taskID", .string("t2"))])
        let cmdDigestHex = try canonicalSHA256(.object([
            ("domain", .string("oches.noise.command.v1")),
            ("clientID", .string("ext-1")),
            ("workspaceID", .string("ws")),
            ("scope", .string(PermissionScope.runRequest.rawValue)),
            ("command", commandPayload),
        ])).map { String(format: "%02x", $0) }.joined()

        try enforcer.issueNonce(nonceID: "nc-missing", clientID: "ext-1", keyID: "sig-1", workspaceID: "ws", purpose: "cmd", expiresAt: 500)
        XCTAssertThrowsError(try authority.authorizeDecryptedCommand(
            clientID: "ext-1", session: coreSession, commandScope: .runRequest, workspaceID: "ws",
            commandPayload: commandPayload, nonceID: "nc-missing", desktopApprovalID: nil, nowEpochSeconds: 220
        )) { XCTAssertEqual($0 as? NoiseChannelError, .approvalRequired([.execution])) }

        // Approval bound to commandPayload digest rejects tampered command (V-22)
        let rev = RevisionRef(objectID: "task-1", storeGeneration: "gen", revision: "1")
        try enforcer.recordApproval(ApprovalRecord(
            approvalID: "app-cmd-1", kind: .execution, subjectClientID: "ext-1", decidedByActorID: "user-1",
            workspaceID: "ws", normalizedTarget: cmdDigestHex, allowedScopes: [.runRequest],
            binding: ApprovalBinding(
                runID: "r1", taskRevision: rev, preparedAttemptID: "att-1", instanceRevision: rev,
                bindingDigest: "bind", capabilitySnapshotID: "snap", executionRequestDigest: cmdDigestHex
            ),
            policyVersion: 1, issuedAt: 200, expiresAt: 500, status: .approved
        ), decidedByTrustedUI: true)

        try enforcer.issueNonce(nonceID: "nc-tamper", clientID: "ext-1", keyID: "sig-1", workspaceID: "ws", purpose: "cmd", expiresAt: 500)
        XCTAssertThrowsError(try authority.authorizeDecryptedCommand(
            clientID: "ext-1", session: coreSession, commandScope: .runRequest, workspaceID: "ws",
            commandPayload: tamperedPayload, nonceID: "nc-tamper", desktopApprovalID: "app-cmd-1", nowEpochSeconds: 221
        )) { XCTAssertEqual($0 as? NoiseChannelError, .denied("Desktop approval mismatch or expired")) }

        // Valid nonce + matching command succeeds once; replay fails
        try enforcer.issueNonce(nonceID: "nc-ok", clientID: "ext-1", keyID: "sig-1", workspaceID: "ws", purpose: "cmd", expiresAt: 500)
        _ = try authority.authorizeDecryptedCommand(
            clientID: "ext-1", session: coreSession, commandScope: .runRequest, workspaceID: "ws",
            commandPayload: commandPayload, nonceID: "nc-ok", desktopApprovalID: "app-cmd-1", nowEpochSeconds: 222
        )
        XCTAssertThrowsError(try authority.authorizeDecryptedCommand(
            clientID: "ext-1", session: coreSession, commandScope: .runRequest, workspaceID: "ws",
            commandPayload: commandPayload, nonceID: "nc-ok", desktopApprovalID: "app-cmd-1", nowEpochSeconds: 223
        ))

        // 4. Rotation rejects old Noise static key immediately; revocation rejects new and active channels
        let newSigKey = Curve25519.Signing.PrivateKey()
        let newNoiseKey = Curve25519.KeyAgreement.PrivateKey()
        let rotDigest = try canonicalSHA256(.object([
            ("domain", .string("oches.enrollment.rotate.v1")),
            ("clientID", .string("ext-1")),
            ("generation", .number("2")),
            ("signingPublicKeyBase64", .string(newSigKey.publicKey.rawRepresentation.base64EncodedString())),
            ("noiseStaticPublicKeyBase64", .string(newNoiseKey.publicKey.rawRepresentation.base64EncodedString())),
        ]))
        let rotated = try authority.rotateEnrolledKeys(
            clientID: "ext-1",
            newSigningKeyID: "sig-2",
            newSigningPublicKeyBase64: newSigKey.publicKey.rawRepresentation.base64EncodedString(),
            newNoiseStaticKeyID: "noise-2",
            newNoiseStaticPublicKeyBase64: newNoiseKey.publicKey.rawRepresentation.base64EncodedString(),
            newKeyProofSignatureBase64: try newSigKey.signature(for: rotDigest).base64EncodedString(),
            desktopTrustedUIConfirmed: true,
            nowEpochSeconds: 230
        )
        XCTAssertEqual(rotated.enrollmentGeneration, 2)

        let prologue2 = try NoisePrologueInput(
            protocolMajor: 1, coreID: "core-macos-1", clientID: "ext-1", enrollmentGeneration: 2, clientRole: "chrome_mv3"
        ).computePrologueHash()
        let oldKeyInit = try NoiseIKHandshakeInitiator(
            localStatic: clientNoiseKey,
            remoteStaticPublic: authority.coreNoiseStaticPrivateKey.publicKey,
            prologueHash: prologue2
        )
        XCTAssertThrowsError(try authority.acceptNoiseHandshake(
            clientID: "ext-1", protocolMajor: 1, message1: try oldKeyInit.writeMessage1(), nowEpochSeconds: 231
        )) { XCTAssertEqual($0 as? NoiseChannelError, .staticKeyMismatch) }

        _ = try authority.revokeClient(clientID: "ext-1")
        try enforcer.issueNonce(nonceID: "nc-rev", clientID: "ext-1", keyID: "sig-2", workspaceID: "ws", purpose: "read", expiresAt: 500)
        XCTAssertThrowsError(try authority.authorizeDecryptedCommand(
            clientID: "ext-1", session: coreSession, commandScope: .workspaceRead, workspaceID: "ws",
            commandPayload: commandPayload, nonceID: "nc-rev", desktopApprovalID: nil, nowEpochSeconds: 232
        )) { XCTAssertEqual($0 as? NoiseChannelError, .clientRevoked) }
    }
}
