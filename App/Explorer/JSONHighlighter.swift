import Foundation
import SwiftUI

/// Pretty-printed JSON with keys, strings, numbers and literals in their own colors. System colors keep it readable
/// in light and dark mode.
enum JSONHighlighter {
    static let keyColor = Color.indigo
    static let stringColor = Color.red
    static let numberColor = Color.blue
    static let literalColor = Color.pink
    static let punctuationColor = Color.secondary

    /// `value` (as `JSONSerialization` returns it) as indented JSON, nested `indent` levels deep. Object keys are sorted.
    static func highlight(_ value: Any, indent: Int = 0) -> AttributedString {
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { return punctuation("{}") }
            var result = punctuation("{\n")
            for (index, key) in object.keys.sorted().enumerated() {
                result += plain(padding(indent + 1)) + self.key(key)
                result += highlight(object[key] ?? NSNull(), indent: indent + 1)
                result += punctuation(index < object.count - 1 ? ",\n" : "\n")
            }
            return result + plain(padding(indent)) + punctuation("}")
        case let array as [Any]:
            guard !array.isEmpty else { return punctuation("[]") }
            // Arrays of numbers (vectors) stay on one wrapping line; anything else gets a line per element.
            if array.allSatisfy({ $0 is NSNumber && !isBool($0) }) {
                var result = punctuation("[")
                for (index, element) in array.enumerated() {
                    result += highlight(element) + punctuation(index < array.count - 1 ? ", " : "")
                }
                return result + punctuation("]")
            }
            var result = punctuation("[\n")
            for (index, element) in array.enumerated() {
                result += plain(padding(indent + 1)) + highlight(element, indent: indent + 1)
                result += punctuation(index < array.count - 1 ? ",\n" : "\n")
            }
            return result + plain(padding(indent)) + punctuation("]")
        case let text as String:
            return string(text)
        case let number as NSNumber where isBool(number):
            return colored(number.boolValue ? "true" : "false", literalColor)
        case let number as NSNumber:
            return colored(DocumentField.fragment(number, pretty: false), numberColor)
        default:
            return colored("null", literalColor)
        }
    }

    /// `"key": ` with the key colored.
    static func key(_ key: String) -> AttributedString {
        colored(DocumentField.fragment(key, pretty: false), keyColor) + punctuation(": ")
    }

    /// A JSON string literal, escaped.
    static func string(_ text: String) -> AttributedString {
        colored(DocumentField.fragment(text, pretty: false), stringColor)
    }

    static func number(_ text: String) -> AttributedString { colored(text, numberColor) }

    static func punctuation(_ text: String) -> AttributedString { colored(text, punctuationColor) }

    static func padding(_ level: Int) -> String { String(repeating: "  ", count: level) }

    private static func plain(_ text: String) -> AttributedString { AttributedString(text) }

    private static func colored(_ text: String, _ color: Color) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = color
        return result
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
