import CoreGraphics
import Foundation
import PDFKit
import Ports
import Vision

/// PDF text via PDFKit. Pages without a text layer are rendered and recognized with Vision (on device).
public struct PDFExtractor: DocumentExtractor {
    /// A page with fewer non-whitespace characters than this is treated as a scan.
    public let minimumTextCharacters: Int
    /// Rendering scale for OCR, relative to the PDF's point size.
    public let ocrScale: CGFloat

    public init(minimumTextCharacters: Int = 20, ocrScale: CGFloat = 2) {
        self.minimumTextCharacters = minimumTextCharacters
        self.ocrScale = ocrScale
    }

    public func extract(from url: URL, events: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable("not a valid PDF") }
        if document.isLocked { throw ExtractionError.passwordProtected }
        let total = document.pageCount
        guard total > 0 else { throw ExtractionError.empty }

        var blocks: [Block] = []
        for index in 0..<total {
            try Task.checkCancellation()
            let number = index + 1
            events(.page(number, of: total))
            guard let page = document.page(at: index) else { continue }

            var text = page.string ?? ""
            if text.filter({ !$0.isWhitespace }).count < minimumTextCharacters {
                events(.recognizing(page: number, of: total))
                text = try await recognize(page)
            }
            blocks += Self.paragraphs(in: text).map { Block(text: $0, page: number) }
        }
        guard !blocks.isEmpty else { throw ExtractionError.empty }
        return ExtractedDocument(blocks: blocks, pageCount: total)
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
        return try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
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
