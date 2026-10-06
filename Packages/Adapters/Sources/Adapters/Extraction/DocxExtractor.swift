import CoreGraphics
import Foundation
import ImageIO
import Ports
import ZIPFoundation

/// Word documents: unzips the package and stream-parses `word/document.xml`.
/// Headings, list items and table rows are recognized; tables are written row by row as `a | b | c`.
/// Pictures are read from `word/media` through the document's relationships, with the nearest heading and a
/// caption: the author's alt text, or else a caption paragraph right after the picture.
public struct DocxExtractor: DocumentExtractor {
    /// Pictures whose shorter side is below this many pixels (icons, bullets) are not kept.
    public let minimumImageSide: Int
    /// A picture used more than this many times in one document (a logo) is not kept.
    public let maxRepeats: Int

    public init(minimumImageSide: Int = 160, maxRepeats: Int = 3) {
        self.minimumImageSide = minimumImageSide
        self.maxRepeats = maxRepeats
    }

    public func extract(from url: URL, events: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument {
        let archive: Archive
        let xml: Data
        do {
            guard let opened = try? Archive(url: url, accessMode: .read) else {
                throw ExtractionError.unreadable("not a valid .docx file")
            }
            archive = opened
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
        let images = (try? images(of: delegate.drawings, in: archive)) ?? []
        guard !delegate.blocks.isEmpty || !images.isEmpty else { throw ExtractionError.empty }
        return ExtractedDocument(blocks: delegate.blocks, images: images)
    }

    // MARK: Pictures

    private func images(of drawings: [Drawing], in archive: Archive) throws -> [ExtractedImage] {
        guard !drawings.isEmpty, let relationships = archive["word/_rels/document.xml.rels"] else { return [] }
        var relationshipXML = Data()
        _ = try archive.extract(relationships) { relationshipXML.append($0) }
        let targets = RelationshipsDelegate.targets(in: relationshipXML)

        let uses = Dictionary(grouping: drawings, by: \.relationshipId).mapValues(\.count)
        var images: [ExtractedImage] = []
        for drawing in drawings {
            try Task.checkCancellation()
            guard let target = targets[drawing.relationshipId], (uses[drawing.relationshipId] ?? 0) <= maxRepeats,
                let entry = archive[Self.path(of: target)], let image = Self.decode(entry, in: archive),
                min(image.width, image.height) >= minimumImageSide
            else { continue }
            let (caption, source) = Self.caption(for: drawing)
            images.append(ExtractedImage(image: image, heading: drawing.heading, caption: caption, captionSource: source))
        }
        return images
    }

    /// The relationship target as a path inside the package: relative to `word/`, or absolute from the root.
    static func path(of target: String) -> String {
        var parts = target.hasPrefix("/") ? [] : ["word"]
        for part in target.split(separator: "/") {
            if part == ".." { _ = parts.popLast() } else if part != "." { parts.append(String(part)) }
        }
        return parts.joined(separator: "/")
    }

    private static func decode(_ entry: Entry, in archive: Archive) -> CGImage? {
        var data = Data()
        guard (try? archive.extract(entry) { data.append($0) }) != nil,
            let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) != nil
        else { return nil }
        // Left compressed until it is analyzed, so a document with many pictures does not hold them all decoded.
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The alt text when the author wrote one, else the caption paragraph that followed the picture.
    private static func caption(for drawing: Drawing) -> (String?, CaptionSource) {
        if let alt = drawing.alt, isMeaningful(alt: alt) { return (alt, .alt) }
        if let caption = drawing.caption { return (caption, .nearby) }
        return (nil, .none)
    }

    /// Word writes machine descriptions ("A picture containing text, Description automatically generated") and
    /// editors fill in file names; neither says what the picture shows.
    static func isMeaningful(alt: String) -> Bool {
        let text = alt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains("automatically generated"), !text.hasPrefix("a picture containing") else { return false }
        if text.range(of: #"\.(png|jpe?g|gif|bmp|tiff?|heic|emf|wmf)$"#, options: .regularExpression) != nil { return false }
        if text.range(of: #"^(picture|image|figure|graphic|photo)\s*\d*$"#, options: .regularExpression) != nil { return false }
        return true
    }
}

/// A picture placed in the document body.
struct Drawing {
    var relationshipId: String
    var alt: String?
    var heading: String?
    var caption: String?
}

/// `Id → Target` of the relationships that point at images.
private final class RelationshipsDelegate: NSObject, XMLParserDelegate {
    private var targets: [String: String] = [:]

    static func targets(in xml: Data) -> [String: String] {
        let delegate = RelationshipsDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.targets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard name == "Relationship", let id = attributes["Id"], let target = attributes["Target"],
            attributes["Type"]?.hasSuffix("/image") == true, attributes["TargetMode"] != "External"
        else { return }
        targets[id] = target
    }
}

private final class DocumentXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var blocks: [Block] = []
    private(set) var drawings: [Drawing] = []

    private var heading: String?
    private var paragraph = ""
    private var inParagraph = false
    private var inText = false
    private var style: String?
    private var isListItem = false

    private var tableDepth = 0
    private var rowCells: [String] = []
    private var cellParagraphs: [String] = []

    private var inDrawing = false
    private var drawingAlt: String?
    private var drawingRelationship: String?
    /// Pictures found in the paragraph being read, and those in the paragraph before it that may be followed by a caption.
    private var paragraphDrawings: [Int] = []
    private var awaitingCaption: [Int] = []

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
        case "w:drawing":
            inDrawing = true
            drawingAlt = nil
            drawingRelationship = nil
        case "wp:docPr" where inDrawing:
            let alt = attributes["descr"] ?? attributes["title"]
            drawingAlt = alt?.isEmpty == false ? alt : nil
        case "a:blip" where inDrawing: drawingRelationship = attributes["r:embed"]
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
        case "w:drawing":
            inDrawing = false
            if let relationship = drawingRelationship {
                drawings.append(Drawing(relationshipId: relationship, alt: drawingAlt, heading: heading))
                paragraphDrawings.append(drawings.count - 1)
            }
        case "w:p":
            inParagraph = false
            let text = finishParagraph()
            // The paragraph after a picture is its caption if it says so; any other text paragraph ends the wait.
            if paragraphDrawings.isEmpty, let text, !awaitingCaption.isEmpty {
                if Self.isCaptionParagraph(style: style, text: text) {
                    for index in awaitingCaption { drawings[index].caption = text }
                }
                awaitingCaption = []
            }
            if !paragraphDrawings.isEmpty { awaitingCaption = paragraphDrawings }
            paragraphDrawings = []
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

    /// Records the paragraph as a block (or a table cell part) and returns its cleaned text, `nil` when empty.
    @discardableResult
    private func finishParagraph() -> String? {
        let text = paragraph.replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if tableDepth > 0 {
            cellParagraphs.append(text)  // table cells are assembled into a row block
            return text
        }
        if Self.isHeadingStyle(style) {
            heading = text
            blocks.append(Block(text: text, kind: .heading, heading: text))
        } else {
            blocks.append(Block(text: text, kind: isListItem ? .listItem : .paragraph, heading: heading))
        }
        return text
    }

    /// A `Caption`-style paragraph, or one that starts like a figure label.
    static func isCaptionParagraph(style: String?, text: String) -> Bool {
        guard text.count <= 300 else { return false }
        if style?.lowercased() == "caption" { return true }
        let lower = text.lowercased()
        return ["figure", "fig.", "fig ", "photo", "abb."].contains { lower.hasPrefix($0) }
    }

    /// `Title`, `Heading1`... and the space/case variants Word and other editors emit.
    static func isHeadingStyle(_ style: String?) -> Bool {
        guard let style = style?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
        return style == "title" || style.hasPrefix("heading")
    }
}
