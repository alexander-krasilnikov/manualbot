import Foundation

/// Where two neighbouring chunks repeat each other. Chunks do not record this: the chunker starts each chunk with the
/// closing sentences of the previous one, so the repeated part is found by comparing the texts word by word.
enum ChunkOverlap {
    /// Fewer repeated words than this are more likely a coincidence than the chunker's overlap.
    static let minimumWords = 3

    /// How many characters at the start of `current` repeat the end of `previous`; 0 when they do not.
    static func leading(previous: String, current: String) -> Int {
        let before = words(in: previous), after = words(in: current)
        guard let count = repeatedWords(endOf: before.map(\.word), startOf: after.map(\.word)) else { return 0 }
        let end = after[count - 1].range.upperBound
        return current.distance(from: current.startIndex, to: end)
    }

    /// How many characters at the end of `current` are repeated at the start of `next`; 0 when none are.
    static func trailing(current: String, next: String) -> Int {
        let before = words(in: current), after = words(in: next)
        guard let count = repeatedWords(endOf: before.map(\.word), startOf: after.map(\.word)) else { return 0 }
        let start = before[before.count - count].range.lowerBound
        return current.distance(from: start, to: current.endIndex)
    }

    /// The longest run of words that ends `before` and starts `after`, if it is long enough. A chunk is never reported
    /// as entirely repeated.
    private static func repeatedWords(endOf before: [String], startOf after: [String]) -> Int? {
        let longest = min(before.count, after.count) - 1
        guard longest >= minimumWords else { return nil }
        for count in stride(from: longest, through: minimumWords, by: -1)
        where before.suffix(count).elementsEqual(after.prefix(count)) {
            return count
        }
        return nil
    }

    private static func words(in text: String) -> [(word: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            if start < index { result.append((String(text[start..<index]), start..<index)) }
        }
        return result
    }
}
