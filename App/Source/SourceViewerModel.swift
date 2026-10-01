import Foundation
import Observation
import Ports

/// Resolves a citation to something the source column can show.
@MainActor @Observable
final class SourceViewerModel {
    struct Paragraph: Identifiable, Equatable {
        let id: Int
        let text: String
        let isHeading: Bool
    }

    enum Content: Equatable {
        case none
        /// A PDF, opened at `page` with `passage` to highlight.
        case pdf(url: URL, page: Int, passage: String, title: String)
        /// Extracted text (Word, text, Markdown) with the cited paragraphs marked.
        case text(title: String, paragraphs: [Paragraph], highlighted: Set<Int>)
        /// The document is gone; only the stored passage remains.
        case deleted(Citation)
        case unavailable(title: String, reason: String)
    }

    private(set) var content = Content.none
    private(set) var isLoading = false
    /// Changes on every open, so the view re-scrolls even when the same passage is opened twice.
    private(set) var openCount = 0

    private let documents: any DocumentRepository
    private let extractor: any DocumentExtractor

    init(documents: any DocumentRepository, extractor: any DocumentExtractor) {
        self.documents = documents
        self.extractor = extractor
    }

    func open(_ citation: Citation) async {
        openCount += 1
        isLoading = true
        defer { isLoading = false }
        guard let document = try? await documents.document(id: citation.docId) else {
            content = .deleted(citation)
            return
        }
        guard let file = try? await documents.originalFileURL(docId: citation.docId) else {
            content = .unavailable(title: document.title, reason: "The original file is not available.")
            return
        }
        if document.type == .pdf {
            content = .pdf(url: file, page: citation.page ?? 1, passage: citation.snippet, title: document.title)
            return
        }
        do {
            let extracted = try await extractor.extract(from: file) { _ in }
            let paragraphs = extracted.blocks.enumerated().map { Paragraph(id: $0.offset, text: $0.element.text, isHeading: $0.element.kind == .heading) }
            content = .text(title: document.title, paragraphs: paragraphs, highlighted: Self.highlighted(in: paragraphs, passage: citation.snippet))
        } catch {
            content = .unavailable(title: document.title, reason: error.localizedDescription)
        }
    }

    /// Opens a document from the library at its first page, with nothing highlighted.
    func openDocument(_ id: String) async {
        let title = (try? await documents.document(id: id))?.title ?? ""
        await open(Citation(n: 0, chunkId: "", docId: id, docTitle: title, page: 1, snippet: ""))
    }

    func close() { content = .none }

    // MARK: Matching a passage to paragraphs

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Paragraphs the passage covers: those it contains completely, plus the ones holding its first and last words
    /// (a passage can start or end part-way through a paragraph).
    static func highlighted(in paragraphs: [Paragraph], passage: String) -> Set<Int> {
        let whole = normalize(passage)
        guard !whole.isEmpty else { return [] }
        let head = String(whole.prefix(40)), tail = String(whole.suffix(40))
        var result = Set<Int>()
        for paragraph in paragraphs {
            let text = normalize(paragraph.text)
            guard !text.isEmpty else { continue }
            if whole.contains(text) || text.contains(head) || text.contains(tail) { result.insert(paragraph.id) }
        }
        return result
    }
}
