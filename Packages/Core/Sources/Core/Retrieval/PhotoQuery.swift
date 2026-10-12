import Foundation

/// The words to search with when the user's question includes a photo: what they typed, plus the identifiers
/// read off the photo (model, type and part numbers). A nameplate carries many other numbers (voltage,
/// frequency, protection class, dates) that would only add noise to a keyword search, so they are left out.
public struct PhotoQuery: Sendable, Equatable {
    /// What to embed and search with: the typed question followed by the identifiers.
    public var text: String
    /// The identifiers kept from the photo, in reading order.
    public var identifiers: [String]
    /// Everything the photo's text recognition returned, one line per line of text, for display and tracing.
    public var recognizedText: String

    public var isEmpty: Bool { text.isEmpty }

    public init(typed: String, recognizedLines lines: [String]) {
        let identifiers = Self.identifiers(in: lines)
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identifiers = identifiers
        self.recognizedText = lines.joined(separator: "\n")
        self.text = ([typed].filter { !$0.isEmpty } + identifiers).joined(separator: " ")
    }

    // MARK: Rules

    /// Words that introduce a number or code on a nameplate or label.
    private static let labels: Set<String> = [
        "model", "mod", "type", "typ", "p/n", "pn", "part", "art", "art.-nr", "art-nr", "artnr", "ref", "item", "serial",
        "s/n", "sn", "lot",
    ]
    /// Words that may follow a label before its value ("Part No.", "Serial Number").
    private static let labelFollowers: Set<String> = ["no", "nr", "number", "#"]

    /// A number with its unit (`230V`, `7.5kW`, `1450rpm`) or an ingress protection class (`IP54`).
    private static let rating = try! NSRegularExpression(
        pattern: #"^(\d+([.,]\d+)?(v|vac|vdc|a|ma|w|kw|kva|va|hz|khz|rpm|bar|psi|kpa|mpa|kg|lb|lbs|db|mm|cm|l|min|°c|°f|ph)|ip\d{2})$"#)
    private static let date = try! NSRegularExpression(pattern: #"^\d{1,4}[-/.]\d{1,2}([-/.]\d{1,4})?$"#)

    static func identifiers(in lines: [String]) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func keep(_ token: String) {
            if seen.insert(token.lowercased()).inserted { found.append(token) }
        }

        var labelledNextLine = false
        for line in lines {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            var afterLabel = labelledNextLine
            var valuesKept = 0
            labelledNextLine = false
            for (index, raw) in tokens.enumerated() {
                let word = clean(raw)
                guard !word.isEmpty else { continue }
                let key = word.lowercased()
                if labels.contains(key) {
                    afterLabel = true
                    valuesKept = 0
                    // A label alone at the end of a line has its value on the next line.
                    if index == tokens.count - 1 { labelledNextLine = true }
                    continue
                }
                if afterLabel, valuesKept == 0, labelFollowers.contains(key) { continue }
                if afterLabel, !matches(rating, word), valuesKept == 0 || word.contains(where: \.isNumber) {
                    keep(word)
                    valuesKept += 1
                } else if !afterLabel, isIdentifier(word) {
                    keep(word)
                }
            }
        }
        return found
    }

    /// Letters and digits inside the token, with the punctuation around it (colons, tildes, commas) removed.
    private static func clean(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// An unlabelled token is an identifier when it mixes digits with letters or hyphens (`X200-B`, `FH-220`,
    /// `E-042`), and is not a rating, protection class or date.
    private static func isIdentifier(_ word: String) -> Bool {
        guard word.count >= 3, word.contains(where: \.isNumber), !matches(rating, word), !matches(date, word) else { return false }
        return word.contains { $0.isLetter || $0 == "-" || $0 == "/" }
    }

    private static func matches(_ expression: NSRegularExpression, _ word: String) -> Bool {
        let lower = word.lowercased()
        return expression.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
    }
}
