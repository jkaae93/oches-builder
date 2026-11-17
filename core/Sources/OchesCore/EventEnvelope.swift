import Foundation

struct ValidatedEventEnvelope {
    // Structural validation does not imply the event was persisted or authorized.
    let original: RawJSONValue
    let eventID: String
    let sourceID: String
    let sequence: String
    let kind: String
    let payload: RawJSONValue
}

/// Structural draft only: no ordering, access, cursor, or durability guarantee.
func validateEventEnvelope(_ value: RawJSONValue) throws -> ValidatedEventEnvelope {
    guard case .object(let members) = value, members.count == 5,
          Set(members.map { Data($0.0.utf8) }).count == 5 else { throw RequestEnvelopeError.invalidInput }
    func field(_ name: String) -> RawJSONValue? {
        members.first { $0.0.utf8.elementsEqual(name.utf8) }?.1
    }
    guard case .string(let eventID) = field("eventId"), !eventID.isEmpty,
          case .string(let sourceID) = field("sourceId"), !sourceID.isEmpty,
          case .string(let sequence) = field("sequence"),
          sequence == "0" || (sequence.first.map { $0 >= "1" && $0 <= "9" } == true && sequence.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }),
          case .string(let kind) = field("kind"), !kind.isEmpty,
          let payload = field("payload"), case .object = payload else { throw RequestEnvelopeError.invalidInput }
    return ValidatedEventEnvelope(original: value, eventID: eventID, sourceID: sourceID, sequence: sequence, kind: kind, payload: payload)
}
