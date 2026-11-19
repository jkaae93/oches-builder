import Foundation

public enum NativeMessagingError: Error, Sendable, Equatable {
    case invalidManifest(String)
    case invalidFrameLength(UInt32)
    case frameTooLarge(Int)
    case invalidUTF8JSON
    case unknownField(String)
    case missingOriginArgument
    case originNotAllowed(String)
    case originMismatch(argv: String, reported: String)
    case portClosed
    case unsupportedEnvelopeOperation(String)
}

public struct NativeMessagingManifestSpec: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let path: String
    public let type: String
    public let allowedOrigins: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case path
        case type
        case allowedOrigins = "allowed_origins"
    }

    public init(
        name: String,
        description: String,
        path: String,
        type: String = "stdio",
        allowedOrigins: [String]
    ) {
        self.name = name
        self.description = description
        self.path = path
        self.type = type
        self.allowedOrigins = allowedOrigins
    }

    public static func isValidChromeExtensionOrigin(_ origin: String) -> Bool {
        let prefix = "chrome-extension://"
        guard origin.hasPrefix(prefix), origin.hasSuffix("/") else {
            return false
        }
        let id = String(origin.dropFirst(prefix.count).dropLast())
        guard id.count == 32 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x61 && scalar.value <= 0x70 // 'a'...'p'
        }
    }

    public static func isValidHostName(_ name: String) -> Bool {
        guard !name.isEmpty,
              !name.contains("*"),
              !name.contains("/"),
              name.contains(".") else {
            return false
        }
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { seg in
            !seg.isEmpty && seg.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7a)
                    || scalar.value == 0x5f
            }
        }
    }

    public func validate() throws {
        guard Self.isValidHostName(name) else {
            throw NativeMessagingError.invalidManifest("invalid host name: \(name)")
        }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeMessagingError.invalidManifest("empty description")
        }
        guard path.hasPrefix("/"), !path.contains("..") else {
            throw NativeMessagingError.invalidManifest("path must be clean absolute path")
        }
        guard type == "stdio" else {
            throw NativeMessagingError.invalidManifest("type must be stdio")
        }
        guard !allowedOrigins.isEmpty else {
            throw NativeMessagingError.invalidManifest("allowed_origins cannot be empty")
        }
        var seen = Set<String>()
        for origin in allowedOrigins {
            guard Self.isValidChromeExtensionOrigin(origin) else {
                throw NativeMessagingError.invalidManifest("invalid origin in allowed_origins: \(origin)")
            }
            guard seen.insert(origin).inserted else {
                throw NativeMessagingError.invalidManifest("duplicate origin in allowed_origins: \(origin)")
            }
        }
    }

    public static func parseAndValidate(jsonData: Data) throws -> NativeMessagingManifestSpec {
        let value = try JSONSerialization.jsonObject(with: jsonData, options: [])
        guard let object = value as? [String: Any] else {
            throw NativeMessagingError.invalidManifest("manifest root must be JSON object")
        }
        let allowedKeys: Set<String> = ["name", "description", "path", "type", "allowed_origins"]
        for key in object.keys where !allowedKeys.contains(key) {
            throw NativeMessagingError.unknownField(key)
        }
        guard let name = object["name"] as? String,
              let description = object["description"] as? String,
              let path = object["path"] as? String,
              let type = object["type"] as? String,
              let origins = object["allowed_origins"] as? [String] else {
            throw NativeMessagingError.invalidManifest("missing or invalid required field")
        }
        let spec = NativeMessagingManifestSpec(
            name: name,
            description: description,
            path: path,
            type: type,
            allowedOrigins: origins
        )
        try spec.validate()
        return spec
    }

    public func encodeCanonicalJSON() throws -> Data {
        try validate()
        let canonical: RawJSONValue = .object([
            ("name", .string(name)),
            ("description", .string(description)),
            ("path", .string(path)),
            ("type", .string(type)),
            ("allowed_origins", .array(allowedOrigins.map { .string($0) })),
        ])
        return try canonicalizeJSON(canonical)
    }
}

public enum NativeMessagingFraming {
    /// W1 & P7 frozen maximum logical payload size over Chrome Native Messaging (256 KiB).
    public static let maxPayloadBytes = NoiseIKProtocol.maxLogicalMessageBytes

    public static func encodeFrame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else {
            throw NativeMessagingError.invalidFrameLength(0)
        }
        guard payload.count <= maxPayloadBytes else {
            throw NativeMessagingError.frameTooLarge(payload.count)
        }
        var header = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &header, count: 4)
        framed.append(payload)
        return framed
    }

    public static func decodeNextFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else {
            return nil
        }
        let start = buffer.startIndex
        let rawLength: UInt32 =
            UInt32(buffer[start])
            | (UInt32(buffer[start + 1]) << 8)
            | (UInt32(buffer[start + 2]) << 16)
            | (UInt32(buffer[start + 3]) << 24)
        let length = Int(rawLength)
        guard rawLength > 0 else {
            throw NativeMessagingError.invalidFrameLength(rawLength)
        }
        guard length <= maxPayloadBytes else {
            throw NativeMessagingError.frameTooLarge(length)
        }
        let total = 4 + length
        guard buffer.count >= total else {
            return nil
        }
        let payload = Data(buffer[buffer.index(start, offsetBy: 4)..<buffer.index(start, offsetBy: total)])
        buffer.removeFirst(total)
        guard String(data: payload, encoding: .utf8) != nil else {
            throw NativeMessagingError.invalidUTF8JSON
        }
        return payload
    }
}

public struct NativeMessagingCallerVerification: Sendable, Equatable {
    public let verifiedOrigin: String
    public let trustLevel: ClientTrustLevel
    public let unprovenAgainstDirectHostExecution: Bool

    public init(
        verifiedOrigin: String,
        trustLevel: ClientTrustLevel,
        unprovenAgainstDirectHostExecution: Bool
    ) {
        self.verifiedOrigin = verifiedOrigin
        self.trustLevel = trustLevel
        self.unprovenAgainstDirectHostExecution = unprovenAgainstDirectHostExecution
    }
}

public struct NativeMessagingCallerGate: Sendable {
    public let allowedOrigins: Set<String>

    public init(manifest: NativeMessagingManifestSpec) throws {
        try manifest.validate()
        self.allowedOrigins = Set(manifest.allowedOrigins)
    }

    public func verifyHostArguments(
        _ arguments: [String],
        reportedBodyOrigin: String? = nil
    ) throws -> NativeMessagingCallerVerification {
        guard arguments.count >= 2 else {
            throw NativeMessagingError.missingOriginArgument
        }
        let argvOrigin = arguments[1]
        guard NativeMessagingManifestSpec.isValidChromeExtensionOrigin(argvOrigin),
              allowedOrigins.contains(argvOrigin) else {
            throw NativeMessagingError.originNotAllowed(argvOrigin)
        }
        if let reportedBodyOrigin, reportedBodyOrigin != argvOrigin {
            throw NativeMessagingError.originMismatch(argv: argvOrigin, reported: reportedBodyOrigin)
        }
        // Per ADR-017 & EXTENSION_IDENTITY_BOUNDARIES: Chrome argv[1] cannot distinguish
        // normal Chrome launch from a direct standalone Host process invocation by local malware.
        return NativeMessagingCallerVerification(
            verifiedOrigin: argvOrigin,
            trustLevel: .userEnrolledKey,
            unprovenAgainstDirectHostExecution: true
        )
    }
}

public final class NativeMessagingHostBridge: @unchecked Sendable {
    public private(set) var activeVerification: NativeMessagingCallerVerification?
    public private(set) var activeSession: NoiseTransportSession?
    public private(set) var inboundBuffer = Data()

    private let gate: NativeMessagingCallerGate
    private static let allowedOuterOperations: Set<String> = [
        "ping",
        "bootstrap",
        "noise_handshake_msg1",
        "noise_frame",
    ]

    public init(manifest: NativeMessagingManifestSpec) throws {
        self.gate = try NativeMessagingCallerGate(manifest: manifest)
    }

    public var isPortOpen: Bool { activeVerification != nil }

    public func openPort(arguments: [String]) throws -> NativeMessagingCallerVerification {
        let verification = try gate.verifyHostArguments(arguments)
        activeVerification = verification
        activeSession = nil
        inboundBuffer.removeAll(keepingCapacity: false)
        return verification
    }

    public func attachNoiseSession(_ session: NoiseTransportSession) throws {
        guard isPortOpen else {
            throw NativeMessagingError.portClosed
        }
        activeSession = session
    }

    public func closePort() {
        activeSession?.close()
        activeSession = nil
        activeVerification = nil
        inboundBuffer.removeAll(keepingCapacity: false)
    }

    public func receiveChunk(
        _ bytes: Data,
        reportedBodyOriginKey: String = "callerOrigin"
    ) throws -> [[String: RawJSONValue]] {
        guard let verification = activeVerification else {
            throw NativeMessagingError.portClosed
        }
        inboundBuffer.append(bytes)
        var accepted: [[String: RawJSONValue]] = []
        while let payload = try NativeMessagingFraming.decodeNextFrame(from: &inboundBuffer) {
            let parsed: RawJSONValue
            do {
                parsed = try validateUniqueJSONKeys(
                    payload,
                    maximumBytes: NativeMessagingFraming.maxPayloadBytes,
                    maximumDepth: 32,
                    maximumStringBytes: NativeMessagingFraming.maxPayloadBytes
                )
            } catch {
                throw NativeMessagingError.invalidUTF8JSON
            }
            guard case .object(let pairs) = parsed else {
                throw NativeMessagingError.invalidUTF8JSON
            }
            var dict: [String: RawJSONValue] = [:]
            for (k, v) in pairs {
                dict[k] = v
            }
            if let bodyOriginVal = dict[reportedBodyOriginKey] {
                guard case .string(let reported) = bodyOriginVal else {
                    throw NativeMessagingError.originMismatch(argv: verification.verifiedOrigin, reported: "<non-string>")
                }
                if reported != verification.verifiedOrigin {
                    throw NativeMessagingError.originMismatch(argv: verification.verifiedOrigin, reported: reported)
                }
            }
            guard case .string(let operation) = dict["op"],
                  Self.allowedOuterOperations.contains(operation) else {
                let opName: String
                if case .string(let str) = dict["op"] {
                    opName = str
                } else {
                    opName = "<missing>"
                }
                throw NativeMessagingError.unsupportedEnvelopeOperation(opName)
            }
            accepted.append(dict)
        }
        return accepted
    }
}
