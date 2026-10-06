import CoreGraphics
import Foundation
import PDFKit
import Ports

/// PDF text via PDFKit. Pages without a text layer are rendered and recognized with Vision (on device).
public struct PDFExtractor: DocumentExtractor {
    /// A page with fewer non-whitespace characters than this is treated as a scan.
    public let minimumTextCharacters: Int
    /// Rendering scale for OCR, relative to the PDF's point size.
    public let ocrScale: CGFloat
    /// Images whose shorter side is below this many pixels (logos, icons, bullets) are not kept.
    public let minimumImageSide: Int
    /// A picture drawn on more than this many pages of one document (a logo, a letterhead) is not kept.
    public let maxRepeatPages: Int
    /// On a page that needed text recognition, an image covering more than this share of the page is the scan itself.
    public let scanCoverage: CGFloat
    private let recognizer: any TextRecognizing

    public init(
        minimumTextCharacters: Int = 20, ocrScale: CGFloat = 2, minimumImageSide: Int = 160, maxRepeatPages: Int = 3,
        scanCoverage: CGFloat = 0.7, recognizer: any TextRecognizing = VisionTextRecognizer()
    ) {
        self.minimumTextCharacters = minimumTextCharacters
        self.ocrScale = ocrScale
        self.minimumImageSide = minimumImageSide
        self.maxRepeatPages = maxRepeatPages
        self.scanCoverage = scanCoverage
        self.recognizer = recognizer
    }

    public func extract(from url: URL, events: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable("not a valid PDF") }
        if document.isLocked { throw ExtractionError.passwordProtected }
        let total = document.pageCount
        guard total > 0 else { throw ExtractionError.empty }

        var blocks: [Block] = []
        var candidates: [(page: Int, placement: PDFImagePlacement)] = []
        for index in 0..<total {
            try Task.checkCancellation()
            let number = index + 1
            events(.page(number, of: total))
            guard let page = document.page(at: index) else { continue }

            var text = page.string ?? ""
            let needsOCR = text.filter({ !$0.isWhitespace }).count < minimumTextCharacters
            if needsOCR {
                events(.recognizing(page: number, of: total))
                text = try await recognize(page)
            }
            blocks += Self.paragraphs(in: text).map { Block(text: $0, page: number) }
            candidates += imageCandidates(on: page, number: number, needsOCR: needsOCR)
        }
        let images = try keptImages(from: candidates, in: document)
        guard !blocks.isEmpty || !images.isEmpty else { throw ExtractionError.empty }
        return ExtractedDocument(blocks: blocks, pageCount: total, images: images)
    }

    // MARK: Images

    /// The images drawn on `page` that are big enough to be photos. A page that was only a scan has no photos:
    /// its one big image is the page itself.
    private func imageCandidates(on page: PDFPage, number: Int, needsOCR: Bool) -> [(page: Int, placement: PDFImagePlacement)] {
        guard let reference = page.pageRef else { return [] }
        let bounds = page.bounds(for: .mediaBox)
        let pageArea = bounds.width * bounds.height
        return PDFImageScanner.placements(on: reference).compactMap { placement in
            guard min(placement.pixelWidth, placement.pixelHeight) >= minimumImageSide else { return nil }
            if needsOCR, pageArea > 0, placement.rect.width * placement.rect.height > scanCoverage * pageArea { return nil }
            return (number, placement)
        }
    }

    /// Drops pictures repeated across pages, then reads the rest. A picture that cannot be read is skipped
    /// without failing the document.
    private func keptImages(from candidates: [(page: Int, placement: PDFImagePlacement)], in document: PDFDocument) throws -> [ExtractedImage] {
        var pagesByDigest: [String: Set<Int>] = [:]
        for candidate in candidates where !candidate.placement.digest.isEmpty {
            pagesByDigest[candidate.placement.digest, default: []].insert(candidate.page)
        }
        var images: [ExtractedImage] = []
        // Reading order: page by page, top of the page first.
        let ordered = candidates.enumerated().sorted {
            ($0.element.page, -$0.element.placement.rect.maxY, $0.offset) < ($1.element.page, -$1.element.placement.rect.maxY, $1.offset)
        }.map(\.element)
        for (number, placement) in ordered {
            try Task.checkCancellation()
            if let pages = pagesByDigest[placement.digest], pages.count > maxRepeatPages { continue }
            guard let page = document.page(at: number - 1) else { continue }
            let image: CGImage
            switch PDFImageScanner.decode(placement.stream) {
            case .image(let decoded): image = decoded
            case .damaged: continue
            case .unsupported:
                guard let drawn = PDFImageScanner.render(placement.rect, of: page) else { continue }
                image = drawn
            }
            let caption = Self.caption(near: placement.rect, on: page)
            images.append(ExtractedImage(
                image: image, page: number, caption: caption, captionSource: caption == nil ? .none : .nearby))
        }
        return images
    }

    private static let captionBand: CGFloat = 40
    private static let captionPrefixes = ["fig.", "fig ", "figure", "photo", "abb.", "abbildung", "image", "picture"]

    /// Caption-like text directly below the image, else directly above it.
    static func caption(near rect: CGRect, on page: PDFPage) -> String? {
        let width = rect.width + 12, x = rect.minX - 6
        let below = CGRect(x: x, y: rect.minY - captionBand - 2, width: width, height: captionBand)
        let above = CGRect(x: x, y: rect.maxY + 2, width: width, height: captionBand)
        for band in [below, above] {
            guard let selection = page.selection(for: band) else { continue }
            let text = (selection.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if isCaption(text, lineCount: selection.selectionsByLine().count) { return text }
        }
        return nil
    }

    /// One or two short lines, or any text that announces itself as a figure. Body text runs to more lines.
    static func isCaption(_ text: String, lineCount: Int) -> Bool {
        guard !text.isEmpty, text.count <= 300 else { return false }
        if captionPrefixes.contains(where: { text.lowercased().hasPrefix($0) }) { return true }
        return lineCount <= 2 && text.count <= 160
    }

    /// Blank-line separated paragraphs; hard-wrapped lines inside a paragraph are joined.
    static func paragraphs(in text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    // MARK: OCR

    private func recognize(_ page: PDFPage) async throws -> String {
        let image = try render(page)
        return try await recognizer.recognize(image, correctLanguage: true).map(\.text).joined(separator: "\n")
    }

    private func render(_ page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * ocrScale), height = Int(bounds.height * ocrScale)
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw ExtractionError.unreadable("could not render a page for text recognition") }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: ocrScale, y: ocrScale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw ExtractionError.unreadable("could not render a page") }
        return image
    }
}
