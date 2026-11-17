import Foundation

struct ValidatedResponseEnvelope {
    let original: RawJSONValue
    let requestID: String
    let revision: RevisionRef?
}

/// Structural validation only; it does not establish that an error message is
/// safe to disclose, a result is authoritative, or a request was authorized.
func validateResponseEnvelope(_ value: RawJSONValue) throws -> ValidatedResponseEnvelope {
    guard case .object(let members) = value,
          Set(members.map { Data($0.0.utf8) }).count == members.count else { throw RequestEnvelopeError.invalidInput }
    let allowed = ["requestId", "result", "correlationId", "revision"]
    guard members.allSatisfy({ member in allowed.contains { member.0.utf8.elementsEqual($0.utf8) } }) else { throw RequestEnvelopeError.invalidInput }
    func field(_ name: String) -> RawJSONValue? { members.first { $0.0.utf8.elementsEqual(name.utf8) }?.1 }
    guard case .string(let requestID) = field("requestId"), !requestID.isEmpty,
          case .object(let result) = field("result"), result.count == 1 else { throw RequestEnvelopeError.invalidInput }
    if let correlation = field("correlationId") {
        guard case .string(let value) = correlation, !value.isEmpty else { throw RequestEnvelopeError.invalidInput }
    }
    let entry = result[0]
    if entry.0.utf8.elementsEqual("ok".utf8) {
        guard case .object = entry.1 else { throw RequestEnvelopeError.invalidInput }
    } else if entry.0.utf8.elementsEqual("error".utf8) {
        guard case .object(let error) = entry.1,
              Set(error.map { Data($0.0.utf8) }).count == error.count else { throw RequestEnvelopeError.invalidInput }
        let permitted = ["code", "message", "action", "detail"]
        guard error.allSatisfy({ item in permitted.contains { item.0.utf8.elementsEqual($0.utf8) } }) else { throw RequestEnvelopeError.invalidInput }
        func item(_ name: String) -> RawJSONValue? { error.first { $0.0.utf8.elementsEqual(name.utf8) }?.1 }
        guard case .string(let code) = item("code"), WireErrorCode(rawValue: code) != nil,
              case .string = item("message"), case .string = item("action") else { throw RequestEnvelopeError.invalidInput }
        if let detail = item("detail") { guard case .string = detail else { throw RequestEnvelopeError.invalidInput } }
    } else { throw RequestEnvelopeError.invalidInput }
    return ValidatedResponseEnvelope(original: value, requestID: requestID, revision: try field("revision").map(parseRevisionRef))
}
