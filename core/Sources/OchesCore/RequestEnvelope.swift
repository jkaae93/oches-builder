import Foundation

public enum RequestEnvelopeError: Error, Equatable {
    case invalidInput
    case versionUnsupported
}

struct ValidatedRequestEnvelope {
    // Preserve the validated original tree; reconstructed subsets must not be
    // used for request digests or approval binding.
    let original: RawJSONValue
    let clientID: String
    let workspaceID: String
    let requestID: String
    let operation: String
    let payload: RawJSONValue
    let approvalRefs: [String]?
    let expectedRevision: RevisionRef?
}

/// Structural validation only. It does not authenticate, authorize, validate
/// operation payloads, or make a request eligible for dispatch.
@discardableResult
func validateRequestEnvelope(_ value: RawJSONValue, negotiated: NegotiatedProtocol) throws -> ValidatedRequestEnvelope {
    guard case .object(let members) = value else { throw RequestEnvelopeError.invalidInput }
    guard Set(members.map { Data($0.0.utf8) }).count == members.count else { throw RequestEnvelopeError.invalidInput }
    func field(_ name: String) -> RawJSONValue? {
        members.first { $0.0.utf8.elementsEqual(name.utf8) }?.1
    }
    let allowed = ["protocolMajor", "protocolMinor", "clientId", "workspaceId", "requestId", "operation", "payload", "expectedRevision", "approvalRefs"]
    guard members.allSatisfy({ member in allowed.contains { member.0.utf8.elementsEqual($0.utf8) } }) else {
        throw RequestEnvelopeError.invalidInput
    }
    func integer(_ value: RawJSONValue?) -> UInt32? {
        guard case .number(let text) = value,
              let mantissa = text.split(whereSeparator: { $0 == "e" || $0 == "E" }).first,
              mantissa.utf8.filter({ $0 >= 48 && $0 <= 57 }).count <= 38,
              let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN,
              decimal >= 0, decimal <= Decimal(UInt32.max) else { return nil }
        var original = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &original, 0, .down)
        guard rounded == decimal else { return nil }
        return UInt32(NSDecimalNumber(decimal: rounded).uint64Value)
    }
    func nonempty(_ value: RawJSONValue?) -> Bool {
        guard case .string(let text) = value else { return false }
        return !text.isEmpty
    }
    guard let major = integer(field("protocolMajor")), let minor = integer(field("protocolMinor")),
          case .string(let clientID) = field("clientId"), !clientID.isEmpty,
          case .string(let workspaceID) = field("workspaceId"), !workspaceID.isEmpty,
          case .string(let requestID) = field("requestId"), !requestID.isEmpty,
          case .string(let operation) = field("operation"), !operation.isEmpty,
          let payload = field("payload"), case .object = payload else { throw RequestEnvelopeError.invalidInput }
    guard major == 1, major == negotiated.major, minor == negotiated.minor else { throw RequestEnvelopeError.versionUnsupported }
    let expectedRevision = try field("expectedRevision").map(parseRevisionRef)
    var approvalRefs: [String]?
    if let approvals = field("approvalRefs") {
        guard case .array(let refs) = approvals, !refs.isEmpty, refs.allSatisfy({ nonempty($0) }) else { throw RequestEnvelopeError.invalidInput }
        approvalRefs = refs.compactMap { if case .string(let value) = $0 { return value }; return nil }
    }
    return ValidatedRequestEnvelope(original: value, clientID: clientID, workspaceID: workspaceID, requestID: requestID, operation: operation, payload: payload, approvalRefs: approvalRefs, expectedRevision: expectedRevision)
}

func parseRevisionRef(_ value: RawJSONValue) throws -> RevisionRef {
    guard case .object(let parts) = value, parts.count == 3, Set(parts.map { Data($0.0.utf8) }).count == 3 else { throw RequestEnvelopeError.invalidInput }
    func part(_ name: String) -> RawJSONValue? { parts.first { $0.0.utf8.elementsEqual(name.utf8) }?.1 }
    guard case .string(let objectID) = part("objectId"), !objectID.isEmpty,
          case .string(let generation) = part("storeGeneration"), !generation.isEmpty,
          case .string(let number) = part("revision"),
          number == "0" || (number.first.map { $0 >= "1" && $0 <= "9" } == true && number.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }) else {
        throw RequestEnvelopeError.invalidInput
    }
    return RevisionRef(objectID: objectID, storeGeneration: generation, revision: number)
}
