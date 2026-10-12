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
        /// A PDF, opened at `page` with `chunk` to highlight.
        case pdf(url: URL, page: Int, chunk: String, title: String)
        /// Extracted text (Word, text, Markdown) with the cited paragraphs marked.
        case text(title: String, paragraphs: [Paragraph], highlighted: Set<Int>)
        /// An imported photo.
        case image(url: URL, title: String)
        /// The document is gone; only the stored chunk remains.
        case deleted(Citation)
        case unavailable(title: String, reason: String)
        /// One chunk of a document, as stored.
        case chunkPreview(ChunkPreview)
        /// One image kept from a document, with its stored picture.
        case imagePreview(ImagePreview)
    }

    struct ChunkPreview: Equatable {
        let docTitle: String
        let entry: ChunkEntry
        let total: Int
        /// Characters at the start of the text repeated from the previous chunk, and at its end repeated in the next.
        let leadingOverlap: Int
        let trailingOverlap: Int
        let hasPrevious: Bool
        let hasNext: Bool
        let citation: Citation
    }

    struct ImagePreview: Equatable {
        let docTitle: String
        let entry: ImageEntry
        let data: Data
        /// Whether a chunk stands for this image.
        let hasChunk: Bool
        let citation: Citation
    }

    private(set) var content = Content.none
    /// The document the last opened source belongs to.
    private(set) var documentID: String?

    /// A stored record, as the Database explorer opens it.
    struct DatabaseRecord: Equatable {
        let collection: String
        let id: String
    }

    /// The stored record of what is shown: the document for a PDF, text or photo, the chunk or image for a preview.
    /// `nil` when nothing is shown or the document is gone.
    var databaseRecord: DatabaseRecord? {
        switch content {
        case .chunkPreview(let preview): DatabaseRecord(collection: CollectionNames.chunks, id: preview.entry.id)
        case .imagePreview(let preview): DatabaseRecord(collection: CollectionNames.images, id: preview.entry.id)
        case .pdf, .text, .image: documentID.map { DatabaseRecord(collection: CollectionNames.documents, id: $0) }
        case .none, .deleted, .unavailable: nil
        }
    }
    private(set) var isLoading = false
    /// Changes on every open, so the view re-scrolls even when the same chunk is opened twice.
    private(set) var openCount = 0

    private let documents: any DocumentRepository
    private let extractor: any DocumentExtractor
    private let tracer: any Tracer

    init(documents: any DocumentRepository, extractor: any DocumentExtractor, tracer: any Tracer = NoTracer()) {
        self.documents = documents
        self.extractor = extractor
        self.tracer = tracer
    }

    func open(_ citation: Citation) async {
        guard tracer.isEnabled else { return await load(citation) }
        let title = citation.page.map { "Open “\(citation.docTitle)”, page \($0)" } ?? "Open “\(citation.docTitle)”"
        let operation = TraceOperation(id: "open-\(UUID().uuidString)", kind: .openSource, title: title)
        await TraceContext.$operation.withValue(operation) { await load(citation) }
    }

    private func load(_ citation: Citation) async {
        openCount += 1
        documentID = citation.docId
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
        if document.type == .image {
            content = .image(url: file, title: document.title)
            return
        }
        if document.type == .pdf {
            content = .pdf(url: file, page: citation.page ?? 1, chunk: citation.snippet, title: document.title)
            return
        }
        do {
            let extracted = try await extractor.extract(from: file) { _ in }
            let paragraphs = extracted.blocks.enumerated().map { Paragraph(id: $0.offset, text: $0.element.text, isHeading: $0.element.kind == .heading) }
            var marked = Self.highlighted(in: paragraphs, chunk: citation.snippet)
            // A photo in a Word document is cited by the section it sits in, so show that section's heading.
            if marked.isEmpty, citation.imageId != nil, let heading = citation.heading {
                marked = Self.headingParagraphs(in: paragraphs, heading: heading)
            }
            content = .text(title: document.title, paragraphs: paragraphs, highlighted: marked)
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

    // MARK: Previews of a document's contents

    /// Shows what `contents` has selected. A selection that is no longer in the lists (its index was replaced) says so.
    func preview(_ contents: DocumentContentsModel) async {
        switch contents.selection {
        case .chunk:
            guard let entry = contents.selectedChunk else {
                content = .unavailable(title: contents.title, reason: "This chunk is no longer in the document's index.")
                return
            }
            let overlap = contents.overlap(of: entry)
            content = .chunkPreview(ChunkPreview(
                docTitle: contents.title, entry: entry, total: contents.chunks.count,
                leadingOverlap: overlap.leading, trailingOverlap: overlap.trailing,
                hasPrevious: contents.hasChunk(offset: -1), hasNext: contents.hasChunk(offset: 1),
                citation: Self.citation(for: entry, docId: contents.docId, title: contents.title)))
        case .image:
            guard let entry = contents.selectedImage else {
                content = .unavailable(title: contents.title, reason: "This image is no longer in the document's index.")
                return
            }
            isLoading = true
            defer { isLoading = false }
            guard let data = try? await documents.imageData(id: entry.id) else {
                content = .unavailable(title: contents.title, reason: "The stored image is not available.")
                return
            }
            let chunk = contents.chunk(of: entry)
            let citation = chunk.map { Self.citation(for: $0, docId: contents.docId, title: contents.title) }
                ?? Citation(n: 0, chunkId: "", docId: contents.docId, docTitle: contents.title, page: entry.page,
                            heading: entry.heading, snippet: entry.caption ?? "", imageId: entry.id)
            content = .imagePreview(ImagePreview(docTitle: contents.title, entry: entry, data: data, hasChunk: chunk != nil, citation: citation))
        case nil:
            break
        }
    }

    /// The document whose chunk or image is being previewed, if one is.
    var previewedDocument: String? {
        switch content {
        case .chunkPreview(let preview): preview.citation.docId
        case .imagePreview(let preview): preview.citation.docId
        default: nil
        }
    }

    func showDeleted(title: String) {
        content = .unavailable(title: title, reason: "The document was deleted.")
    }

    static func citation(for chunk: ChunkEntry, docId: String, title: String) -> Citation {
        Citation(n: 0, chunkId: chunk.id, docId: docId, docTitle: title, page: chunk.page, heading: chunk.heading,
                 snippet: chunk.text, imageId: chunk.imageId)
    }

    // MARK: Matching a chunk to paragraphs

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The heading paragraphs that read `heading`.
    static func headingParagraphs(in paragraphs: [Paragraph], heading: String) -> Set<Int> {
        let wanted = normalize(heading)
        return Set(paragraphs.filter { $0.isHeading && normalize($0.text) == wanted }.map(\.id))
    }

    /// Paragraphs the chunk covers: those it contains completely, plus the ones holding its first and last words
    /// (a chunk can start or end part-way through a paragraph).
    static func highlighted(in paragraphs: [Paragraph], chunk: String) -> Set<Int> {
        let whole = normalize(chunk)
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
