import Foundation
import Ports

/// Checks the `[n]` markers in a generated answer against the chunks that were actually supplied.
public enum CitationValidator {
    public struct Result: Equatable {
        /// The answer with invalid markers removed and valid ones normalized to `[1][2]`.
        public var text: String
        /// Chunk numbers cited, in order of first appearance.
        public var cited: [Int]
        /// Whether at least one valid marker remains. An answer without one is not grounded.
        public var isGrounded: Bool { !cited.isEmpty }
    }

    private static let marker = try! NSRegularExpression(pattern: #"\[\s*(\d+(?:\s*[,;]\s*\d+)*)\s*\]"#)

    public static func validate(_ answer: String, chunkCount: Int) -> Result {
        var cited: [Int] = []
        let ns = answer as NSString
        var output = ""
        var cursor = 0

        for match in marker.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length

            let numbers = ns.substring(with: match.range(at: 1))
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
                .compactMap { Int($0) }
            var valid: [Int] = []
            for n in numbers where (1...max(chunkCount, 1)).contains(n) && chunkCount > 0 && !valid.contains(n) {
                valid.append(n)
                if !cited.contains(n) { cited.append(n) }
            }
            output += valid.map { "[\($0)]" }.joined()
        }
        output += ns.substring(from: cursor)
        return Result(text: tidy(output), cited: cited)
    }

    /// Removing a marker can leave `word .` or two spaces behind.
    private static func tidy(_ text: String) -> String {
        var result = text
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        for punctuation in [".", ",", ";", ":", "!", "?"] {
            result = result.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
