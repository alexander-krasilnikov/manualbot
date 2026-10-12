import Foundation
import Observation
import Ports

/// A chunk as the contents list and preview show it. The embedding itself is left out: only its model and length are shown.
struct ChunkEntry: Identifiable, Equatable, Sendable {
    let id: String
    let ordinal: Int
    let page: Int?
    let heading: String?
    let text: String
    /// Set on the chunk that stands for an image.
    let imageId: String?
    let embeddingModel: String
    let dimension: Int

    init(_ chunk: Chunk) {
        id = chunk.id
        ordinal = chunk.ordinal
        page = chunk.page
        heading = chunk.heading
        text = chunk.text
        imageId = chunk.imageId
        embeddingModel = chunk.embeddingModel
        dimension = chunk.embedding.count
    }
}

/// An image as the contents list and preview show it, without its features.
struct ImageEntry: Identifiable, Equatable, Sendable {
    let id: String
    let n: Int
    let page: Int?
    let heading: String?
    let caption: String?
    let captionSource: CaptionSource
    let ocrText: String
    let width: Int
    let height: Int

    init(_ image: ImageRecord) {
        id = image.id
        n = image.n
        page = image.page
        heading = image.heading
        caption = image.caption
        captionSource = image.captionSource
        ocrText = image.ocrText
        width = image.width
        height = image.height
    }
}

struct ContentsSection<Entry: Identifiable & Sendable>: Identifiable, Sendable {
    let id: String
    let title: String
    let entries: [Entry]
}

/// What a document's contents view has selected.
enum ContentsSelection: Equatable {
    case chunk(String)
    case image(String)
}

/// A document's chunks and images (those of its active index), and which one is selected. One instance lives as long as
/// the contents are open.
@MainActor @Observable
final class DocumentContentsModel {
    enum Kind: Hashable { case chunks, images }
    enum Phase: Equatable { case loading, loaded, failed(String) }

    let docId: String
    let title: String
    let type: DocumentType

    private(set) var phase = Phase.loading
    private(set) var chunks: [ChunkEntry] = []
    private(set) var images: [ImageEntry] = []
    private(set) var chunkSections: [ContentsSection<ChunkEntry>] = []
    private(set) var imageSections: [ContentsSection<ImageEntry>] = []
    var kind = Kind.chunks
    private(set) var selection: ContentsSelection?

    /// Called when the user selects an item, so the detail column can show it.
    @ObservationIgnored var onSelect: (@MainActor (DocumentContentsModel) -> Void)?
    /// Called after the lists are reloaded while something is selected, so its preview can be refreshed in place.
    @ObservationIgnored var onRefresh: (@MainActor (DocumentContentsModel) -> Void)?

    private let documents: any DocumentRepository
    private let tracer: any Tracer
    @ObservationIgnored private var operation: TraceOperation?
    @ObservationIgnored private var displayCopies: [String: Data] = [:]

    init(docId: String, title: String, type: DocumentType, documents: any DocumentRepository, tracer: any Tracer = NoTracer()) {
        self.docId = docId
        self.title = title
        self.type = type
        self.documents = documents
        self.tracer = tracer
    }

    /// Reads the chunks and images of the document's active index. Chunk and image IDs include the index's generation, so
    /// a selection that is no longer in the new lists stays selected but resolves to nothing.
    func load() async {
        if tracer.isEnabled {
            let operation = TraceOperation(id: "contents-\(UUID().uuidString)", kind: .browseContents, title: "Contents of “\(title)”")
            self.operation = operation
            await TraceContext.$operation.withValue(operation) { await read() }
        } else {
            await read()
        }
    }

    private func read() async {
        do {
            let chunks = try await documents.activeChunks(docId: docId).map(ChunkEntry.init)
            let images = try await documents.activeImages(docId: docId).map(ImageEntry.init)
            self.chunks = chunks
            self.images = images
            chunkSections = Self.sections(of: chunks, byPage: type == .pdf, fallbackTitle: title, order: \.ordinal)
            imageSections = Self.sections(of: images, byPage: type == .pdf, fallbackTitle: title, order: \.n)
            phase = .loaded
            if selection != nil { onRefresh?(self) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Selection

    func select(_ selection: ContentsSelection) {
        self.selection = selection
        onSelect?(self)
    }

    /// The chunks in the order the list shows them, which Previous and Next follow.
    var orderedChunks: [ChunkEntry] { chunkSections.flatMap(\.entries) }

    var selectedChunk: ChunkEntry? {
        guard case .chunk(let id) = selection else { return nil }
        return chunks.first { $0.id == id }
    }

    var selectedImage: ImageEntry? {
        guard case .image(let id) = selection else { return nil }
        return images.first { $0.id == id }
    }

    /// Selects the chunk `offset` places away from the selected one in list order, if there is one.
    func step(by offset: Int) {
        guard let current = selectedChunk, let index = orderedChunks.firstIndex(of: current) else { return }
        let target = index + offset
        guard orderedChunks.indices.contains(target) else { return }
        select(.chunk(orderedChunks[target].id))
    }

    func hasChunk(offset: Int) -> Bool {
        guard let current = selectedChunk, let index = orderedChunks.firstIndex(of: current) else { return false }
        return orderedChunks.indices.contains(index + offset)
    }

    /// Switches to the chunk list with the chunk that stands for `image` selected.
    func showChunk(of image: ImageEntry) {
        guard let chunk = chunks.first(where: { $0.imageId == image.id }) else { return }
        kind = .chunks
        select(.chunk(chunk.id))
    }

    func chunk(of image: ImageEntry) -> ChunkEntry? { chunks.first { $0.imageId == image.id } }

    // MARK: Neighbours and overlap

    /// The text chunks before and after `chunk` by ordinal, which is where the chunker repeats text. A chunk on another
    /// page or one that stands for an image shares nothing.
    func overlap(of chunk: ChunkEntry) -> (leading: Int, trailing: Int) {
        func neighbour(_ offset: Int) -> ChunkEntry? {
            guard chunk.imageId == nil,
                let other = chunks.first(where: { $0.ordinal == chunk.ordinal + offset }),
                other.imageId == nil, other.page == chunk.page
            else { return nil }
            return other
        }
        let leading = neighbour(-1).map { ChunkOverlap.leading(previous: $0.text, current: chunk.text) } ?? 0
        let trailing = neighbour(1).map { ChunkOverlap.trailing(current: chunk.text, next: $0.text) } ?? 0
        return (leading, trailing)
    }

    // MARK: Thumbnails

    /// The stored display copy of an image, kept for the rows of the list.
    func displayCopy(for imageId: String) async -> Data? {
        if let cached = displayCopies[imageId] { return cached }
        let data = try? await documents.imageData(id: imageId)
        displayCopies[imageId] = data
        return data
    }

    // MARK: Sections

    /// Groups entries by page (PDF) or heading, in order of each group's first entry, entries in `order` within a group.
    /// Sorting by first entry puts an image's chunk at the end of its page or heading instead of after the last page.
    static func sections<Entry: Identifiable & Sendable>(
        of entries: [Entry], byPage: Bool, fallbackTitle: String, order: KeyPath<Entry, Int>
    ) -> [ContentsSection<Entry>] where Entry: PlacedEntry {
        var groups: [String: (title: String, entries: [Entry])] = [:]
        for entry in entries.sorted(by: { $0[keyPath: order] < $1[keyPath: order] }) {
            let (key, title) = byPage ? pageKey(entry.page) : headingKey(entry.heading, fallback: fallbackTitle)
            groups[key, default: (title, [])].entries.append(entry)
        }
        return groups.sorted { ($0.value.entries.first?[keyPath: order] ?? 0) < ($1.value.entries.first?[keyPath: order] ?? 0) }
            .map { ContentsSection(id: $0.key, title: $0.value.title, entries: $0.value.entries) }
    }

    private static func pageKey(_ page: Int?) -> (String, String) {
        guard let page else { return ("page:none", "No page") }
        return ("page:\(page)", "Page \(page)")
    }

    private static func headingKey(_ heading: String?, fallback: String) -> (String, String) {
        let title = heading?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? fallback
        return ("heading:\(title)", title)
    }
}

extension DocumentContentsModel: Hashable {
    nonisolated static func == (lhs: DocumentContentsModel, rhs: DocumentContentsModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// What a chunk or image needs to be placed in a section.
protocol PlacedEntry {
    var page: Int? { get }
    var heading: String? { get }
}

extension ChunkEntry: PlacedEntry {}
extension ImageEntry: PlacedEntry {}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
