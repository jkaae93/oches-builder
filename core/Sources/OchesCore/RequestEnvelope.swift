import Foundation

public enum RequestEnvelopeError: Error, Equatable {
    case invalidInput
    case versionUnsupported
}

/// Structural validation only. It does not authenticate, authorize, validate
/// operation payloads, or make a request eligible for dispatch.
@discardableResult
func validateRequestEnvelope(_ value: RawJSONValue, negotiated: NegotiatedProtocol) throws -> RevisionRef? {
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
          nonempty(field("clientId")), nonempty(field("workspaceId")), nonempty(field("requestId")),
          nonempty(field("operation")), case .object = field("payload") else { throw RequestEnvelopeError.invalidInput }
    guard major == 1, major == negotiated.major, minor == negotiated.minor else { throw RequestEnvelopeError.versionUnsupported }
    var expectedRevision: RevisionRef?
    if let revision = field("expectedRevision") {
        guard case .object(let parts) = revision, parts.count == 3, Set(parts.map { Data($0.0.utf8) }).count == 3 else { throw RequestEnvelopeError.invalidInput }
        func part(_ name: String) -> RawJSONValue? { parts.first { $0.0.utf8.elementsEqual(name.utf8) }?.1 }
        guard case .string(let objectID) = part("objectId"), !objectID.isEmpty,
              case .string(let generation) = part("storeGeneration"), !generation.isEmpty,
              case .string(let number) = part("revision"),
              number == "0" || (number.first.map { $0 >= "1" && $0 <= "9" } == true && number.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }) else {
            throw RequestEnvelopeError.invalidInput
        }
        expectedRevision = RevisionRef(objectID: objectID, storeGeneration: generation, revision: number)
    }
    if let approvals = field("approvalRefs") {
        guard case .array(let refs) = approvals, !refs.isEmpty, refs.allSatisfy({ nonempty($0) }) else { throw RequestEnvelopeError.invalidInput }
    }
    return expectedRevision
}
