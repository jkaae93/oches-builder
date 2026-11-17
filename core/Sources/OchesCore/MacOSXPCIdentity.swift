import CryptoKit
import Foundation
import Security

public enum CodeSigningPosture: Sendable, Equatable {
    case distributionSigned(teamID: String, signingIdentifier: String)
    case adHoc(signingIdentifier: String)
    case unsigned
    case invalid(reason: String)
}

public struct PeerIdentityRequirement: Sendable, Equatable {
    public let expectedTeamID: String
    public let expectedSigningIdentifier: String

    public init(expectedTeamID: String, expectedSigningIdentifier: String) {
        self.expectedTeamID = expectedTeamID
        self.expectedSigningIdentifier = expectedSigningIdentifier
    }

    public var xpcRequirementString: String {
        "anchor apple generic and identifier \"\(expectedSigningIdentifier)\" and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
    }
}

public enum XPCIdentityError: Error, Sendable, Equatable {
    case duplicateRequirementConfiguration
    case missingRequirementConfiguration
    case emptyIdentityClaim
    case adHocSignatureRejected
    case unsignedPeerRejected
    case teamIDMismatch
    case signingIdentifierMismatch
    case invalidSignature(String)
    case directHostAccessRejected
    case uidOrPidOnlyClaimRejected
    case unauthenticatedRequestDenied

    public var safeWireError: SafeWireError {
        switch self {
        case .duplicateRequirementConfiguration, .missingRequirementConfiguration:
            return SafeWireError(code: .unavailable, detail: nil)
        default:
            return SafeWireError(code: .denied, detail: "AUTH_FAILED")
        }
    }
}

public enum PeerConnectionSource: Sendable, Equatable {
    case verifiedXPC(posture: CodeSigningPosture, effectiveUID: UInt32)
    case uidOrPidOnly(effectiveUID: UInt32, pid: Int32)
    case directHostInvocation(claimedOrigin: String)
}

public final class XPCConnectionRequirementGuard: @unchecked Sendable {
    public let expectedLocalUID: UInt32
    private var configuredRequirement: PeerIdentityRequirement?
    private let lock = NSLock()

    public init(expectedLocalUID: UInt32) {
        self.expectedLocalUID = expectedLocalUID
    }

    /// Configures the single peer code-signing requirement for an XPC connection.
    /// Applying a second requirement fails closed as a programming error (`ARC-11-G3-MACOS-DESIGN.md`).
    public func configurePeerRequirement(_ requirement: PeerIdentityRequirement) throws {
        guard !requirement.expectedTeamID.isEmpty, !requirement.expectedSigningIdentifier.isEmpty else {
            throw XPCIdentityError.emptyIdentityClaim
        }
        lock.lock()
        defer { lock.unlock() }
        if configuredRequirement != nil {
            configuredRequirement = nil
            throw XPCIdentityError.duplicateRequirementConfiguration
        }
        configuredRequirement = requirement
    }

    public func evaluatePeer(_ source: PeerConnectionSource) throws -> PeerIdentityRequirement {
        lock.lock()
        let requirement = configuredRequirement
        lock.unlock()

        guard let requirement else {
            throw XPCIdentityError.missingRequirementConfiguration
        }

        switch source {
        case .directHostInvocation:
            throw XPCIdentityError.directHostAccessRejected
        case .uidOrPidOnly:
            throw XPCIdentityError.uidOrPidOnlyClaimRejected
        case .verifiedXPC(let posture, let effectiveUID):
            guard effectiveUID == expectedLocalUID else {
                throw XPCIdentityError.teamIDMismatch
            }
            switch posture {
            case .distributionSigned(let teamID, let signingIdentifier):
                guard teamID.utf8.elementsEqual(requirement.expectedTeamID.utf8) else {
                    throw XPCIdentityError.teamIDMismatch
                }
                guard signingIdentifier.utf8.elementsEqual(requirement.expectedSigningIdentifier.utf8) else {
                    throw XPCIdentityError.signingIdentifierMismatch
                }
                return requirement
            case .adHoc:
                throw XPCIdentityError.adHocSignatureRejected
            case .unsigned:
                throw XPCIdentityError.unsignedPeerRejected
            case .invalid(let reason):
                throw XPCIdentityError.invalidSignature(reason)
            }
        }
    }
}

public struct MachOCodeSignatureInspector: Sendable {
    public init() {}

    public func inspectBinary(at url: URL) -> CodeSigningPosture {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return .invalid(reason: "SecStaticCodeCreateWithPath failed: \(createStatus)")
        }

        let validStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        if validStatus == errSecCSUnsigned {
            return .unsigned
        }
        if validStatus != errSecSuccess {
            return .invalid(reason: "SecStaticCodeCheckValidity failed: \(validStatus)")
        }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else {
            return .invalid(reason: "SecCodeCopySigningInformation failed: \(infoStatus)")
        }

        let identifier = info[kSecCodeInfoIdentifier as String] as? String ?? ""
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        let isAdHoc = (flags & 0x0002) != 0

        if isAdHoc || teamID == nil || teamID?.isEmpty == true {
            return .adHoc(signingIdentifier: identifier)
        }
        return .distributionSigned(teamID: teamID!, signingIdentifier: identifier)
    }

    public func satisfiesRequirement(_ requirement: PeerIdentityRequirement, binaryAt url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }
        var secReq: SecRequirement?
        guard SecRequirementCreateWithString(requirement.xpcRequirementString as CFString, SecCSFlags(), &secReq) == errSecSuccess,
              let req = secReq else {
            return false
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req)
        return status == errSecSuccess
    }
}

public enum KeyStoreError: Error, Sendable, Equatable {
    case keyUnavailable(String)
    case keyNotFound
    case keyRevoked
    case signatureInvalid
    case plaintextFallbackForbidden

    public var safeWireError: SafeWireError {
        switch self {
        case .keyUnavailable:
            return SafeWireError(code: .unavailable, detail: "KEY_UNAVAILABLE")
        case .keyNotFound, .keyRevoked, .signatureInvalid:
            return SafeWireError(code: .denied, detail: "AUTH_FAILED")
        case .plaintextFallbackForbidden:
            return SafeWireError(code: .unavailable, detail: "KEY_UNAVAILABLE")
        }
    }
}

public enum KeyPurpose: String, Sendable, Equatable, Codable {
    case signingP256 = "SIGNING_P256"
    case noiseX25519 = "NOISE_X25519"
}

public struct StoredPublicKeyRecord: Sendable, Equatable {
    public let keyID: String
    public let purpose: KeyPurpose
    public let publicKeyBytes: Data
    public let hardwareBacked: Bool

    public init(keyID: String, purpose: KeyPurpose, publicKeyBytes: Data, hardwareBacked: Bool) {
        self.keyID = keyID
        self.purpose = purpose
        self.publicKeyBytes = publicKeyBytes
        self.hardwareBacked = hardwareBacked
    }
}

public protocol ProtectedKeyStore: Sendable {
    func generateSigningKey(keyID: String) throws -> StoredPublicKeyRecord
    func generateNoiseStaticKey(keyID: String) throws -> StoredPublicKeyRecord
    func publicKey(keyID: String) throws -> StoredPublicKeyRecord
    func sign(keyID: String, payload: Data) throws -> Data
    func verify(publicKeyBytes: Data, payload: Data, signature: Data) -> Bool
    func revokeKey(keyID: String) throws
}

/// Software/in-memory protected key store simulating Keychain/Secure Enclave ACL lock
/// and revocation boundaries for deterministic unit/regression testing without touching
/// the user's real login keychain (`MACOS_IDENTITY_EXPERIMENT.md`).
public final class ScopedProtectedKeyStore: ProtectedKeyStore, @unchecked Sendable {
    private struct KeyMaterial {
        let purpose: KeyPurpose
        let signingPrivateKey: P256.Signing.PrivateKey?
        let noisePrivateKey: Curve25519.KeyAgreement.PrivateKey?
        var revoked: Bool
    }

    private var keys: [String: KeyMaterial] = [:]
    private var isLocked: Bool = false
    private let lock = NSLock()

    public init(locked: Bool = false) {
        self.isLocked = locked
    }

    public func setLocked(_ locked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.isLocked = locked
    }

    public func generateSigningKey(keyID: String) throws -> StoredPublicKeyRecord {
        guard !keyID.isEmpty else { throw KeyStoreError.keyUnavailable("empty keyID") }
        lock.lock()
        defer { lock.unlock() }
        if isLocked { throw KeyStoreError.keyUnavailable("keychain locked") }
        let priv = P256.Signing.PrivateKey()
        keys[keyID] = KeyMaterial(purpose: .signingP256, signingPrivateKey: priv, noisePrivateKey: nil, revoked: false)
        return StoredPublicKeyRecord(
            keyID: keyID,
            purpose: .signingP256,
            publicKeyBytes: priv.publicKey.x963Representation,
            hardwareBacked: false
        )
    }

    public func generateNoiseStaticKey(keyID: String) throws -> StoredPublicKeyRecord {
        guard !keyID.isEmpty else { throw KeyStoreError.keyUnavailable("empty keyID") }
        lock.lock()
        defer { lock.unlock() }
        if isLocked { throw KeyStoreError.keyUnavailable("keychain locked") }
        let priv = Curve25519.KeyAgreement.PrivateKey()
        keys[keyID] = KeyMaterial(purpose: .noiseX25519, signingPrivateKey: nil, noisePrivateKey: priv, revoked: false)
        return StoredPublicKeyRecord(
            keyID: keyID,
            purpose: .noiseX25519,
            publicKeyBytes: priv.publicKey.rawRepresentation,
            hardwareBacked: false
        )
    }

    public func publicKey(keyID: String) throws -> StoredPublicKeyRecord {
        lock.lock()
        defer { lock.unlock() }
        if isLocked { throw KeyStoreError.keyUnavailable("keychain locked") }
        guard let item = keys[keyID] else { throw KeyStoreError.keyNotFound }
        if item.revoked { throw KeyStoreError.keyRevoked }
        switch item.purpose {
        case .signingP256:
            return StoredPublicKeyRecord(
                keyID: keyID,
                purpose: .signingP256,
                publicKeyBytes: item.signingPrivateKey!.publicKey.x963Representation,
                hardwareBacked: false
            )
        case .noiseX25519:
            return StoredPublicKeyRecord(
                keyID: keyID,
                purpose: .noiseX25519,
                publicKeyBytes: item.noisePrivateKey!.publicKey.rawRepresentation,
                hardwareBacked: false
            )
        }
    }

    public func sign(keyID: String, payload: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if isLocked { throw KeyStoreError.keyUnavailable("keychain locked") }
        guard let item = keys[keyID] else { throw KeyStoreError.keyNotFound }
        if item.revoked { throw KeyStoreError.keyRevoked }
        guard let priv = item.signingPrivateKey else {
            throw KeyStoreError.keyUnavailable("not a signing key")
        }
        return try priv.signature(for: payload).derRepresentation
    }

    public func verify(publicKeyBytes: Data, payload: Data, signature: Data) -> Bool {
        guard let pub = try? P256.Signing.PublicKey(x963Representation: publicKeyBytes),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return pub.isValidSignature(sig, for: payload)
    }

    public func revokeKey(keyID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if isLocked { throw KeyStoreError.keyUnavailable("keychain locked") }
        guard var item = keys[keyID] else { throw KeyStoreError.keyNotFound }
        item.revoked = true
        keys[keyID] = item
    }
}
