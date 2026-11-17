import Foundation

public enum RawJSONValidationError: Error, Equatable {
    case invalidInput
    case duplicateKey
    case limitExceeded
    case unsafeNumber
}

/// JSON objects retain ordered members instead of using Swift String-keyed maps.
indirect enum RawJSONValue {
    case object([(String, RawJSONValue)])
    case array([RawJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

/// Detects duplicate object keys before Foundation can discard them. This is not
/// a complete wire validator: schema and JCS checks are
/// still required before any request can be dispatched.
@discardableResult
func validateUniqueJSONKeys(_ data: Data, maximumBytes: Int, maximumDepth: Int, maximumStringBytes: Int) throws -> RawJSONValue {
    try parseJSON(data, maximumBytes: maximumBytes, maximumDepth: maximumDepth, maximumStringBytes: maximumStringBytes, wirePolicy: true)
}

// Internal reference-vector entry point; never use in place of the wire policy.
func parseJSON(_ data: Data, maximumBytes: Int, maximumDepth: Int, maximumStringBytes: Int, wirePolicy: Bool) throws -> RawJSONValue {
    // Hard safety ceilings are provisional implementation limits, not wire
    // contract values. A caller cannot disable bounds by supplying Int.max.
    guard maximumBytes > 0, maximumBytes <= 1_048_576,
          maximumDepth > 0, maximumDepth <= 128,
          maximumStringBytes > 0, maximumStringBytes <= 262_144 else { throw RawJSONValidationError.invalidInput }
    guard data.count <= maximumBytes else { throw RawJSONValidationError.limitExceeded }
    guard String(data: data, encoding: .utf8) != nil else { throw RawJSONValidationError.invalidInput }
    var scanner = KeyScanner(bytes: Array(data), maximumDepth: maximumDepth, maximumStringBytes: maximumStringBytes, wirePolicy: wirePolicy)
    scanner.whitespace()
    guard scanner.index < scanner.bytes.count, !wirePolicy || scanner.bytes[scanner.index] == 0x7b else { throw RawJSONValidationError.invalidInput }
    let value = try scanner.value(depth: 0)
    scanner.whitespace()
    guard scanner.index == scanner.bytes.count else { throw RawJSONValidationError.invalidInput }
    // Parse only after bounded scanning; Foundation validates syntax, not duplicate keys.
    guard (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
        throw RawJSONValidationError.invalidInput
    }
    return value
}

private struct KeyScanner {
    let bytes: [UInt8]
    let maximumDepth: Int
    let maximumStringBytes: Int
    let wirePolicy: Bool
    var index = 0

    mutating func whitespace() {
        while index < bytes.count && [0x20, 0x0a, 0x0d, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func value(depth: Int) throws -> RawJSONValue {
        whitespace()
        guard index < bytes.count else { throw RawJSONValidationError.invalidInput }
        switch bytes[index] {
        case 0x7b: return try object(depth: depth + 1)
        case 0x5b: return try array(depth: depth + 1)
        case 0x22: return .string(try string())
        default:
            let start = index
            while index < bytes.count && ![0x2c, 0x5d, 0x7d, 0x20, 0x0a, 0x0d, 0x09].contains(bytes[index]) { index += 1 }
            guard start < index else { throw RawJSONValidationError.invalidInput }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            if token.first == "-" || token.first?.isNumber == true {
                guard let number = Double(token), number.isFinite else { throw RawJSONValidationError.unsafeNumber }
                if !wirePolicy { return .number(token) }
                // Decimal has finite precision; do not let a long mantissa be
                // rounded down across the safe boundary. This conservative
                // policy is provisional pending the wire-number decision.
                let mantissa = token.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
                guard mantissa.utf8.filter({ $0 >= 0x30 && $0 <= 0x39 }).count <= 38 else {
                    throw RawJSONValidationError.unsafeNumber
                }
                // Check the original decimal value too: Double alone rounds large integers.
                guard let decimal = Decimal(string: token, locale: Locale(identifier: "en_US_POSIX")),
                      !decimal.isNaN else { throw RawJSONValidationError.unsafeNumber }
                let limit = Decimal(9_007_199_254_740_991 as Int64)
                guard decimal <= limit && decimal >= -limit else { throw RawJSONValidationError.unsafeNumber }
                return .number(token)
            }
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: throw RawJSONValidationError.invalidInput
            }
        }
    }

    mutating func object(depth: Int) throws -> RawJSONValue {
        guard depth <= maximumDepth else { throw RawJSONValidationError.limitExceeded }
        index += 1
        whitespace()
        if take(0x7d) { return .object([]) }
        var keys = Set<Data>()
        var members: [(String, RawJSONValue)] = []
        repeat {
            whitespace()
            let key = try string()
            guard keys.insert(Data(key.utf8)).inserted else { throw RawJSONValidationError.duplicateKey }
            whitespace()
            guard take(0x3a) else { throw RawJSONValidationError.invalidInput }
            let item = try value(depth: depth)
            members.append((key, item))
            whitespace()
            if take(0x7d) { return .object(members) }
            guard take(0x2c) else { throw RawJSONValidationError.invalidInput }
        } while true
    }

    mutating func array(depth: Int) throws -> RawJSONValue {
        guard depth <= maximumDepth else { throw RawJSONValidationError.limitExceeded }
        index += 1
        whitespace()
        if take(0x5d) { return .array([]) }
        var items: [RawJSONValue] = []
        repeat {
            items.append(try value(depth: depth))
            whitespace()
            if take(0x5d) { return .array(items) }
            guard take(0x2c) else { throw RawJSONValidationError.invalidInput }
        } while true
    }

    mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 0x22 else { throw RawJSONValidationError.invalidInput }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            guard index - start - 1 <= maximumStringBytes || (byte == 0x22 && !escaped && index - start - 2 <= maximumStringBytes) else { throw RawJSONValidationError.limitExceeded }
            if escaped { escaped = false; continue }
            if byte == 0x5c { escaped = true; continue }
            if byte == 0x22 {
                let fragment = Data(bytes[start..<index])
                guard let decoded = try? JSONSerialization.jsonObject(with: fragment, options: .fragmentsAllowed) as? String else {
                    throw RawJSONValidationError.invalidInput
                }
                return decoded
            }
        }
        throw RawJSONValidationError.invalidInput
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}
