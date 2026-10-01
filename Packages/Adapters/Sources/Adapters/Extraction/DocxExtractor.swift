import Foundation
import Ports
import ZIPFoundation

/// Word documents: unzips the package and stream-parses `word/document.xml`.
/// Headings, list items and table rows are recognized; tables are written row by row as `a | b | c`.
public struct DocxExtractor: DocumentExtractor {
    public init() {}

    public func extract(from url: URL, events: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument {
        let xml: Data
        do {
            guard let archive = try? Archive(url: url, accessMode: .read) else {
                throw ExtractionError.unreadable("not a valid .docx file")
            }
            guard let entry = archive["word/document.xml"] else { throw ExtractionError.unreadable("not a Word document") }
            var buffer = Data()
            _ = try archive.extract(entry) { buffer.append($0) }
            xml = buffer
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError.unreadable("not a valid .docx file")
        }

        let parser = XMLParser(data: xml)
        let delegate = DocumentXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ExtractionError.unreadable(parser.parserError?.localizedDescription ?? "invalid document XML")
        }
        guard !delegate.blocks.isEmpty else { throw ExtractionError.empty }
        return ExtractedDocument(blocks: delegate.blocks)
    }
}

private final class DocumentXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var blocks: [Block] = []

    private var heading: String?
    private var paragraph = ""
    private var inParagraph = false
    private var inText = false
    private var style: String?
    private var isListItem = false

    private var tableDepth = 0
    private var rowCells: [String] = []
    private var cellParagraphs: [String] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "w:tbl": tableDepth += 1
        case "w:tr" where tableDepth == 1: rowCells = []
        case "w:tc" where tableDepth == 1: cellParagraphs = []
        case "w:p":
            inParagraph = true
            paragraph = ""
            style = nil
            isListItem = false
        case "w:pStyle" where inParagraph: style = attributes["w:val"]
        case "w:numPr" where inParagraph: isListItem = true
        case "w:t" where inParagraph: inText = true
        case "w:tab" where inParagraph: paragraph += "\t"
        case "w:br" where inParagraph, "w:cr" where inParagraph: paragraph += " "
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { paragraph += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "w:t": inText = false
        case "w:p":
            inParagraph = false
            finishParagraph()
        case "w:tc" where tableDepth == 1:
            rowCells.append(cellParagraphs.joined(separator: " "))
        case "w:tr" where tableDepth == 1:
            let row = rowCells.map { $0.trimmingCharacters(in: .whitespaces) }
            if row.contains(where: { !$0.isEmpty }) {
                blocks.append(Block(text: row.joined(separator: " | "), kind: .table, heading: heading))
            }
        case "w:tbl": tableDepth -= 1
        default: break
        }
    }

    private func finishParagraph() {
        let text = paragraph.replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return }
        if tableDepth > 0 {
            cellParagraphs.append(text)  // table cells are assembled into a row block
            return
        }
        if Self.isHeadingStyle(style) {
            heading = text
            blocks.append(Block(text: text, kind: .heading, heading: text))
        } else {
            blocks.append(Block(text: text, kind: isListItem ? .listItem : .paragraph, heading: heading))
        }
    }

    /// `Title`, `Heading1`... and the space/case variants Word and other editors emit.
    static func isHeadingStyle(_ style: String?) -> Bool {
        guard let style = style?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
        return style == "title" || style.hasPrefix("heading")
    }
}
