import CryptoKit
import Foundation

public enum NoiseChannelError: Error, Sendable, Equatable {
    case invalidPrologue
    case zeroRTTForbidden
    case staticKeyMismatch
    case decryptionFailed
    case channelClosed
    case handshakeIncomplete
    case messageTooLarge
    case invalidChunkHeader
    case chunkOrderMismatch
    case invalidPadding
    case nonceExhausted
    case keyUnavailable
    case clientRevoked
    case approvalRequired([ApprovalKind])
    case denied(String)
    case comparisonAttemptsExceeded
}

public struct NoisePrologueInput: Sendable, Equatable, Codable {
    public let protocolMajor: Int
    public let coreID: String
    public let clientID: String
    public let enrollmentGeneration: UInt64
    public let clientRole: String

    public init(
        protocolMajor: Int,
        coreID: String,
        clientID: String,
        enrollmentGeneration: UInt64,
        clientRole: String
    ) {
        self.protocolMajor = protocolMajor
        self.coreID = coreID
        self.clientID = clientID
        self.enrollmentGeneration = enrollmentGeneration
        self.clientRole = clientRole
    }

    public func computePrologueHash() throws -> Data {
        guard protocolMajor > 0,
              !coreID.isEmpty,
              !clientID.isEmpty,
              !clientRole.isEmpty else {
            throw NoiseChannelError.invalidPrologue
        }
        return try canonicalSHA256(.array([
            .number(String(protocolMajor)),
            .string(NoiseIKProtocol.protocolName),
            .string(coreID),
            .string(clientID),
            .number(String(enrollmentGeneration)),
            .string(clientRole),
        ]))
    }
}

public enum NoiseIKProtocol {
    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    public static let maxLogicalMessageBytes = 262_144
    public static let maxNoiseFrameBytes = 65_535
    public static let paddingBucketBytes = 4_096
    public static let chunkHeaderBytes = 21
    public static let maxChunkPlaintextBytes = 61_440
    public static let maxChunkBodyBytes = maxChunkPlaintextBytes - chunkHeaderBytes
}

public struct NoiseCipherState: Sendable {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0

    public init(key: SymmetricKey? = nil) {
        self.key = key
    }

    public var hasKey: Bool { key != nil }

    public mutating func initializeKey(_ rawKey: Data) {
        key = SymmetricKey(data: rawKey)
        nonce = 0
    }

    public mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        guard nonce < UInt64.max else { throw NoiseChannelError.nonceExhausted }
        let chachaNonce = try makeNoiseNonce(nonce)
        nonce += 1
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: chachaNonce, authenticating: ad)
        return sealed.ciphertext + sealed.tag
    }

    public mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce < UInt64.max else { throw NoiseChannelError.nonceExhausted }
        guard ciphertext.count >= 16 else { throw NoiseChannelError.decryptionFailed }
        let chachaNonce = try makeNoiseNonce(nonce)
        nonce += 1
        let ct = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: chachaNonce, ciphertext: ct, tag: tag)
            return try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw NoiseChannelError.decryptionFailed
        }
    }

    private func makeNoiseNonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        var le = n.littleEndian
        bytes.append(Data(bytes: &le, count: 8))
        return try ChaChaPoly.Nonce(data: bytes)
    }
}

public struct NoiseSymmetricState: Sendable {
    private var ck: Data
    public private(set) var h: Data
    private var cipher = NoiseCipherState()

    public init(protocolName: String = NoiseIKProtocol.protocolName) {
        let nameBytes = Data(protocolName.utf8)
        let initial = nameBytes.count <= 32
            ? nameBytes + Data(repeating: 0, count: 32 - nameBytes.count)
            : Data(SHA256.hash(data: nameBytes))
        self.h = initial
        self.ck = initial
    }

    public mutating func mixHash(_ data: Data) {
        var hasher = SHA256()
        hasher.update(data: h)
        hasher.update(data: data)
        h = Data(hasher.finalize())
    }

    public mutating func mixKey(_ inputKeyMaterial: Data) {
        let (nextCK, tempK) = Self.hkdfTwo(chainingKey: ck, inputKeyMaterial: inputKeyMaterial)
        ck = nextCK
        cipher.initializeKey(tempK)
    }

    public mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: h, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    public mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: h, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    public func split() -> (NoiseCipherState, NoiseCipherState) {
        let (k1, k2) = Self.hkdfTwo(chainingKey: ck, inputKeyMaterial: Data())
        return (NoiseCipherState(key: SymmetricKey(data: k1)), NoiseCipherState(key: SymmetricKey(data: k2)))
    }

    static func hkdfTwo(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let ckKey = SymmetricKey(data: chainingKey)
        let tempKeyBytes = Data(HMAC<SHA256>.authenticationCode(for: inputKeyMaterial, using: ckKey))
        let tempKey = SymmetricKey(data: tempKeyBytes)
        let out1 = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: tempKey))
        var out2Input = out1
        out2Input.append(0x02)
        let out2 = Data(HMAC<SHA256>.authenticationCode(for: out2Input, using: tempKey))
        return (out1, out2)
    }
}

public final class NoiseIKHandshakeInitiator {
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private let remoteStaticPublic: Curve25519.KeyAgreement.PublicKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var symmetric: NoiseSymmetricState
    private var sentMessage1 = false

    public init(
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        remoteStaticPublic: Curve25519.KeyAgreement.PublicKey,
        prologueHash: Data,
        ephemeralOverride: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws {
        guard prologueHash.count == 32 else { throw NoiseChannelError.invalidPrologue }
        self.localStatic = localStatic
        self.remoteStaticPublic = remoteStaticPublic
        self.ephemeral = ephemeralOverride ?? Curve25519.KeyAgreement.PrivateKey()
        self.symmetric = NoiseSymmetricState()
        self.symmetric.mixHash(prologueHash)
        self.symmetric.mixHash(remoteStaticPublic.rawRepresentation)
    }

    public func writeMessage1() throws -> Data {
        guard !sentMessage1 else { throw NoiseChannelError.handshakeIncomplete }
        sentMessage1 = true

        let ePub = ephemeral.publicKey.rawRepresentation
        symmetric.mixHash(ePub)

        let esShared = try ephemeral.sharedSecretFromKeyAgreement(with: remoteStaticPublic)
        symmetric.mixKey(esShared.withUnsafeBytes { Data($0) })

        let encS = try symmetric.encryptAndHash(localStatic.publicKey.rawRepresentation)

        let ssShared = try localStatic.sharedSecretFromKeyAgreement(with: remoteStaticPublic)
        symmetric.mixKey(ssShared.withUnsafeBytes { Data($0) })

        let encEmpty = try symmetric.encryptAndHash(Data())
        return ePub + encS + encEmpty
    }

    public func readMessage2(_ message: Data) throws -> NoiseTransportSession {
        guard sentMessage1 else { throw NoiseChannelError.handshakeIncomplete }
        guard message.count == 48 else { throw NoiseChannelError.zeroRTTForbidden }

        let rePubData = message.prefix(32)
        let encPayload = message.dropFirst(32)
        guard let rePub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: rePubData) else {
            throw NoiseChannelError.decryptionFailed
        }
        symmetric.mixHash(rePubData)

        let eeShared = try ephemeral.sharedSecretFromKeyAgreement(with: rePub)
        symmetric.mixKey(eeShared.withUnsafeBytes { Data($0) })

        let seShared = try localStatic.sharedSecretFromKeyAgreement(with: rePub)
        symmetric.mixKey(seShared.withUnsafeBytes { Data($0) })

        let payload = try symmetric.decryptAndHash(Data(encPayload))
        guard payload.isEmpty else { throw NoiseChannelError.zeroRTTForbidden }

        let (c1, c2) = symmetric.split()
        return NoiseTransportSession(sendCipher: c1, recvCipher: c2, handshakeHash: symmetric.h)
    }
}

public final class NoiseIKHandshakeResponder {
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var symmetric: NoiseSymmetricState
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private var remoteStatic: Curve25519.KeyAgreement.PublicKey?

    public init(
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        prologueHash: Data,
        ephemeralOverride: Curve25519.KeyAgreement.PrivateKey? = nil
    ) throws {
        guard prologueHash.count == 32 else { throw NoiseChannelError.invalidPrologue }
        self.localStatic = localStatic
        self.ephemeral = ephemeralOverride ?? Curve25519.KeyAgreement.PrivateKey()
        self.symmetric = NoiseSymmetricState()
        self.symmetric.mixHash(prologueHash)
        self.symmetric.mixHash(localStatic.publicKey.rawRepresentation)
    }

    public func readMessage1(
        _ message: Data,
        validateClientStaticKey: (Data) throws -> Void
    ) throws -> Data {
        guard message.count >= 96 else { throw NoiseChannelError.decryptionFailed }
        guard message.count == 96 else { throw NoiseChannelError.zeroRTTForbidden }

        let ePubData = message.prefix(32)
        let encS = message.dropFirst(32).prefix(48)
        let encPayload = message.dropFirst(80)

        guard let re = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ePubData) else {
            throw NoiseChannelError.decryptionFailed
        }
        symmetric.mixHash(ePubData)

        let esShared = try localStatic.sharedSecretFromKeyAgreement(with: re)
        symmetric.mixKey(esShared.withUnsafeBytes { Data($0) })

        let rsData = try symmetric.decryptAndHash(Data(encS))
        guard let rs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: rsData) else {
            throw NoiseChannelError.staticKeyMismatch
        }
        try validateClientStaticKey(rsData)

        let ssShared = try localStatic.sharedSecretFromKeyAgreement(with: rs)
        symmetric.mixKey(ssShared.withUnsafeBytes { Data($0) })

        let payload = try symmetric.decryptAndHash(Data(encPayload))
        guard payload.isEmpty else { throw NoiseChannelError.zeroRTTForbidden }

        self.remoteEphemeral = re
        self.remoteStatic = rs
        return rsData
    }

    public func writeMessage2() throws -> (message: Data, session: NoiseTransportSession) {
        guard let re = remoteEphemeral, let rs = remoteStatic else {
            throw NoiseChannelError.handshakeIncomplete
        }
        let ePub = ephemeral.publicKey.rawRepresentation
        symmetric.mixHash(ePub)

        let eeShared = try ephemeral.sharedSecretFromKeyAgreement(with: re)
        symmetric.mixKey(eeShared.withUnsafeBytes { Data($0) })

        let seShared = try ephemeral.sharedSecretFromKeyAgreement(with: rs)
        symmetric.mixKey(seShared.withUnsafeBytes { Data($0) })

        let encEmpty = try symmetric.encryptAndHash(Data())
        let (c1, c2) = symmetric.split()
        let session = NoiseTransportSession(sendCipher: c2, recvCipher: c1, handshakeHash: symmetric.h)
        return (ePub + encEmpty, session)
    }
}

public final class NoiseTransportSession: @unchecked Sendable {
    private let lock = NSLock()
    private var sendCipher: NoiseCipherState
    private var recvCipher: NoiseCipherState
    public let handshakeHash: Data
    private var _isClosed = false

    private var activeMessageID: UInt64?
    private var expectedChunkIndex: UInt32 = 0
    private var reassemblyBuffer = Data()

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isClosed
    }

    init(sendCipher: NoiseCipherState, recvCipher: NoiseCipherState, handshakeHash: Data) {
        self.sendCipher = sendCipher
        self.recvCipher = recvCipher
        self.handshakeHash = handshakeHash
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        _isClosed = true
        activeMessageID = nil
        expectedChunkIndex = 0
        reassemblyBuffer.removeAll(keepingCapacity: false)
    }

    public func sendLogicalMessage(
        _ body: Data,
        logicalMessageID: UInt64,
        padTo4KiB: Bool
    ) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard !_isClosed else { throw NoiseChannelError.channelClosed }
        guard body.count <= NoiseIKProtocol.maxLogicalMessageBytes else {
            throw NoiseChannelError.messageTooLarge
        }

        let maxBody = NoiseIKProtocol.maxChunkBodyBytes
        var offset = 0
        var chunkIndex: UInt32 = 0
        var frames: [Data] = []

        repeat {
            let end = min(body.count, offset + maxBody)
            let chunkBody = body.subdata(in: offset..<end)
            let isFinal = end == body.count

            let unpaddedLength = NoiseIKProtocol.chunkHeaderBytes + chunkBody.count
            let paddingLength: Int
            if padTo4KiB {
                let bucket = NoiseIKProtocol.paddingBucketBytes
                let buckets = max(1, (unpaddedLength + bucket - 1) / bucket)
                let paddedTotal = buckets * bucket
                guard paddedTotal <= NoiseIKProtocol.maxChunkPlaintextBytes else {
                    throw NoiseChannelError.invalidPadding
                }
                paddingLength = paddedTotal - unpaddedLength
            } else {
                paddingLength = 0
            }

            var plaintext = Data(capacity: unpaddedLength + paddingLength)
            appendBigEndian(logicalMessageID, to: &plaintext)
            appendBigEndian(chunkIndex, to: &plaintext)
            plaintext.append(isFinal ? 1 : 0)
            appendBigEndian(UInt32(chunkBody.count), to: &plaintext)
            appendBigEndian(UInt32(paddingLength), to: &plaintext)
            plaintext.append(chunkBody)
            if paddingLength > 0 {
                plaintext.append(Data(repeating: 0, count: paddingLength))
            }

            let encrypted = try sendCipher.encrypt(ad: Data(), plaintext: plaintext)
            guard encrypted.count <= NoiseIKProtocol.maxNoiseFrameBytes else {
                throw NoiseChannelError.messageTooLarge
            }
            frames.append(encrypted)

            offset = end
            chunkIndex += 1
        } while offset < body.count

        return frames
    }

    func sendSingleChunkForTesting(
        logicalMessageID: UInt64,
        chunkIndex: UInt32,
        isFinal: Bool,
        body: Data,
        paddingLength: Int = 0
    ) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !_isClosed else { throw NoiseChannelError.channelClosed }
        var plaintext = Data()
        appendBigEndian(logicalMessageID, to: &plaintext)
        appendBigEndian(chunkIndex, to: &plaintext)
        plaintext.append(isFinal ? 1 : 0)
        appendBigEndian(UInt32(body.count), to: &plaintext)
        appendBigEndian(UInt32(paddingLength), to: &plaintext)
        plaintext.append(body)
        if paddingLength > 0 {
            plaintext.append(Data(repeating: 0, count: paddingLength))
        }
        return try sendCipher.encrypt(ad: Data(), plaintext: plaintext)
    }

    public func receiveFrame(
        _ frame: Data,
        require4KiBPadding: Bool = false
    ) throws -> (logicalMessageID: UInt64, completeBody: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard !_isClosed else { throw NoiseChannelError.channelClosed }
        guard frame.count <= NoiseIKProtocol.maxNoiseFrameBytes else {
            failClosedInLock()
            throw NoiseChannelError.messageTooLarge
        }

        let plaintext: Data
        do {
            plaintext = try recvCipher.decrypt(ad: Data(), ciphertext: frame)
        } catch {
            failClosedInLock()
            throw NoiseChannelError.decryptionFailed
        }

        guard plaintext.count >= NoiseIKProtocol.chunkHeaderBytes,
              plaintext.count <= NoiseIKProtocol.maxChunkPlaintextBytes else {
            failClosedInLock()
            throw NoiseChannelError.invalidChunkHeader
        }
        if require4KiBPadding && (plaintext.count % NoiseIKProtocol.paddingBucketBytes != 0) {
            failClosedInLock()
            throw NoiseChannelError.invalidPadding
        }

        let messageID = readBigEndianUInt64(plaintext, at: 0)
        let chunkIndex = readBigEndianUInt32(plaintext, at: 8)
        let finalByte = plaintext[12]
        let bodyLength = Int(readBigEndianUInt32(plaintext, at: 13))
        let paddingLength = Int(readBigEndianUInt32(plaintext, at: 17))

        guard finalByte == 0 || finalByte == 1 else {
            failClosedInLock()
            throw NoiseChannelError.invalidChunkHeader
        }
        guard NoiseIKProtocol.chunkHeaderBytes + bodyLength + paddingLength == plaintext.count else {
            failClosedInLock()
            throw NoiseChannelError.invalidPadding
        }

        let paddingStart = NoiseIKProtocol.chunkHeaderBytes + bodyLength
        for idx in paddingStart..<plaintext.count where plaintext[idx] != 0 {
            failClosedInLock()
            throw NoiseChannelError.invalidPadding
        }

        if let activeID = activeMessageID {
            guard activeID == messageID else {
                failClosedInLock()
                throw NoiseChannelError.chunkOrderMismatch
            }
        } else {
            activeMessageID = messageID
            expectedChunkIndex = 0
        }

        guard chunkIndex == expectedChunkIndex else {
            failClosedInLock()
            throw NoiseChannelError.chunkOrderMismatch
        }
        expectedChunkIndex += 1

        let chunkBody = plaintext.subdata(in: NoiseIKProtocol.chunkHeaderBytes..<paddingStart)
        guard reassemblyBuffer.count + chunkBody.count <= NoiseIKProtocol.maxLogicalMessageBytes else {
            failClosedInLock()
            throw NoiseChannelError.messageTooLarge
        }
        reassemblyBuffer.append(chunkBody)

        if finalByte == 1 {
            let full = reassemblyBuffer
            activeMessageID = nil
            expectedChunkIndex = 0
            reassemblyBuffer.removeAll(keepingCapacity: false)
            return (messageID, full)
        }
        return nil
    }

    private func failClosedInLock() {
        _isClosed = true
        activeMessageID = nil
        expectedChunkIndex = 0
        reassemblyBuffer.removeAll(keepingCapacity: false)
    }

    private func appendBigEndian(_ value: UInt64, to data: inout Data) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 8))
    }

    private func appendBigEndian(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 4))
    }

    private func readBigEndianUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    private func readBigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(data[offset + i])
        }
        return value
    }
}
