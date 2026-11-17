import CryptoKit
import Foundation
import JavaScriptCore

public enum CanonicalizationError: Error {
    case invalidNumber
    case duplicateKey
    case javascriptUnavailable
}

/// Canonicalizes a validated value; this does not authenticate or authorize it.
func canonicalizeJSON(_ value: RawJSONValue) throws -> Data {
    guard let context = JSContext(), let stringify = context.evaluateScript("JSON.stringify") else {
        throw CanonicalizationError.javascriptUnavailable
    }
    func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x09: result += "\\t"
            case 0x0a: result += "\\n"
            case 0x0c: result += "\\f"
            case 0x0d: result += "\\r"
            case 0...0x1f: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
    func encode(_ value: RawJSONValue) throws -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return quote(s)
        case .number(let text):
            guard let number = Double(text), number.isFinite,
                  let argument = JSValue(double: number, in: context),
                  let result = stringify.call(withArguments: [argument]),
                  let output = result.toString(), context.exception == nil else {
                throw CanonicalizationError.invalidNumber
            }
            return output
        case .array(let values): return "[" + (try values.map(encode)).joined(separator: ",") + "]"
        case .object(let members):
            var seen = Set<Data>()
            for (key, _) in members where !seen.insert(Data(key.utf8)).inserted {
                throw CanonicalizationError.duplicateKey
            }
            let sorted = members.sorted { Array($0.0.utf16).lexicographicallyPrecedes(Array($1.0.utf16)) }
            return "{" + (try sorted.map { quote($0.0) + ":" + (try encode($0.1)) }).joined(separator: ",") + "}"
        }
    }
    return Data(try encode(value).utf8)
}

func canonicalSHA256(_ value: RawJSONValue) throws -> Data {
    Data(SHA256.hash(data: try canonicalizeJSON(value)))
}
