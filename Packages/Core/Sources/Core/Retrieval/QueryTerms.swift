import Foundation

/// Turns a natural-language question into the terms worth searching for exactly.
public enum QueryTerms {
    static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "can", "do", "does", "for", "from", "how", "i", "if", "in",
        "is", "it", "its", "me", "my", "of", "on", "or", "should", "so", "that", "the", "their", "then", "there",
        "these", "this", "to", "was", "we", "what", "when", "where", "which", "who", "why", "will", "with", "would",
        "you", "your", "about", "into", "than", "have", "has", "had", "not", "get", "use", "tell",
    ]

    /// Words worth matching, in order, without duplicates. Punctuation around a word is dropped, but
    /// characters inside codes (`E-042`, `M8x20`, `PN_7731`) are kept.
    public static func keywords(from question: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in question.split(whereSeparator: { $0.isWhitespace }) {
            let word = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard word.count >= 2 else { continue }
            let key = word.lowercased()
            guard !stopwords.contains(key), seen.insert(key).inserted else { continue }
            terms.append(word)
        }
        return terms
    }

    /// Identifier-like terms (they contain a digit), which embeddings represent poorly and which are
    /// matched verbatim: error codes, part numbers, model names.
    public static func codes(in terms: [String]) -> [String] {
        terms.filter { $0.contains(where: \.isNumber) && $0.count >= 3 }
    }

    /// Whether `text` contains `code` as a whole token, ignoring case.
    public static func contains(_ text: String, code: String) -> Bool {
        let haystack = text.lowercased(), needle = code.lowercased()
        var start = haystack.startIndex
        while let range = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
            let isWord: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
            if !isWord(before) && !isWord(after) { return true }
            start = range.upperBound
        }
        return false
    }
}
