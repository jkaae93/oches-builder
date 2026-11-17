import Foundation

public enum RawJSONValidationError: Error, Equatable {
    case invalidInput
    case duplicateKey
}

/// Detects duplicate object keys before Foundation can discard them. This is not
/// a complete wire validator: numeric, resource-limit and schema checks are
/// still required before any request can be dispatched.
public func validateUniqueJSONKeys(_ data: Data) throws {
    guard String(data: data, encoding: .utf8) != nil else { throw RawJSONValidationError.invalidInput }
    // Foundation supplies syntax and Unicode validation; the scanner below
    // observes original object members, including escaped equivalent names.
    guard let root = try? JSONSerialization.jsonObject(with: data), root is [String: Any] else {
        throw RawJSONValidationError.invalidInput
    }
    var scanner = KeyScanner(bytes: Array(data))
    try scanner.value()
    scanner.whitespace()
    guard scanner.index == scanner.bytes.count else { throw RawJSONValidationError.invalidInput }
}

private struct KeyScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func whitespace() {
        while index < bytes.count && [0x20, 0x0a, 0x0d, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws {
        whitespace()
        guard index < bytes.count else { throw RawJSONValidationError.invalidInput }
        switch bytes[index] {
        case 0x7b: try object()
        case 0x5b: try array()
        case 0x22: _ = try string()
        default:
            while index < bytes.count && ![0x2c, 0x5d, 0x7d, 0x20, 0x0a, 0x0d, 0x09].contains(bytes[index]) { index += 1 }
        }
    }

    mutating func object() throws {
        index += 1
        whitespace()
        if take(0x7d) { return }
        var keys = Set<Data>()
        repeat {
            whitespace()
            let key = try string()
            guard keys.insert(Data(key.utf8)).inserted else { throw RawJSONValidationError.duplicateKey }
            whitespace()
            guard take(0x3a) else { throw RawJSONValidationError.invalidInput }
            try value()
            whitespace()
            if take(0x7d) { return }
            guard take(0x2c) else { throw RawJSONValidationError.invalidInput }
        } while true
    }

    mutating func array() throws {
        index += 1
        whitespace()
        if take(0x5d) { return }
        repeat {
            try value()
            whitespace()
            if take(0x5d) { return }
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
