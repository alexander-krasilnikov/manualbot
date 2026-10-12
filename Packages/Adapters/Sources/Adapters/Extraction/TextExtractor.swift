import Foundation
import Ports

/// Plain text and Markdown. Paragraphs are separated by blank lines; Markdown `#` headings become
/// heading provenance for the blocks that follow.
public struct TextExtractor: DocumentExtractor {
    public let isMarkdown: Bool

    public init(isMarkdown: Bool) { self.isMarkdown = isMarkdown }

    public func extract(from url: URL, events: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ExtractionError.unreadable(error.localizedDescription) }
        let text = Self.decode(data)
        let blocks = isMarkdown ? Self.markdownBlocks(text) : Self.plainBlocks(text)
        guard !blocks.isEmpty else { throw ExtractionError.empty }
        return ExtractedDocument(blocks: blocks)
    }

    /// UTF-8 first, then whatever encoding Foundation detects (UTF-16 with BOM, Windows-1252, ...),
    /// then Latin-1, which accepts every byte sequence.
    static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return stripBOM(utf8) }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let encoding = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: &lossy)
        if encoding != 0, let converted, !lossy.boolValue { return stripBOM(converted as String) }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func stripBOM(_ s: String) -> String { s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }

    private static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    static func plainBlocks(_ text: String) -> [Block] {
        paragraphs(text).map { Block(text: $0) }
    }

    static func markdownBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var heading: String?
        var paragraph: [String] = []
        var inFence = false

        func flush() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(Block(text: joined, heading: heading)) }
            paragraph = []
        }

        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inFence.toggle(); continue }
            if !inFence, line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flush()
                    let title = line.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
                    heading = title
                    blocks.append(Block(text: title, kind: .heading, heading: title))
                    continue
                }
            }
            if line.isEmpty && !inFence { flush() } else if !line.isEmpty { paragraph.append(line) }
        }
        flush()
        return blocks
    }
}
