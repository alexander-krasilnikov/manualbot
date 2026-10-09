import Adapters
import Core
import Foundation
import Observation
import Ports

/// The document library: what is imported, and how far indexing has got.
@MainActor @Observable
final class LibraryViewModel {
    enum Status: Equatable {
        case queued
        case extracting(Double)
        case recognizing(Double)
        case analyzing(Double)
        case embedding(Double)
        /// Searchable from its previous index while a new one is built (a re-index, such as after a model update).
        case updating(Double)
        case ready
        case failed(String)

        /// Searchable: ready, or ready from the previous index while it is being updated.
        var isReady: Bool { self == .ready || isUpdating }
        var isUpdating: Bool { if case .updating = self { true } else { false } }
        var isWorking: Bool {
            switch self {
            case .queued, .extracting, .recognizing, .analyzing, .embedding, .updating: true
            case .ready, .failed: false
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: String
        var title: String
        var type: DocumentType
        var pageCount: Int?
        /// Photos found in the document (1 for an imported photo, 0 when there are none).
        var imageCount: Int = 0
        var importedAt: Date
        var status: Status
    }

    private(set) var items: [Item] = []
    /// Files that could not be imported, each with the reason.
    private(set) var rejections: [String] = []
    /// Why photos cannot be imported, naming the embedding model in use. `nil` when they can.
    var photosExplanation: String?

    private let documents: any DocumentRepository
    private let jobs: any IngestJobStore
    private let ingestion: IngestionService
    /// Called after a document becomes searchable (used to warm up the vector index).
    private let onDocumentReady: (@Sendable () async -> Void)?
    /// Display copies of photo documents, loaded when a row first shows them.
    @ObservationIgnored private var thumbnails: [String: Data] = [:]

    init(
        documents: any DocumentRepository, jobs: any IngestJobStore, ingestion: IngestionService,
        onDocumentReady: (@Sendable () async -> Void)? = nil
    ) {
        self.documents = documents
        self.jobs = jobs
        self.ingestion = ingestion
        self.onDocumentReady = onDocumentReady
    }

    var readyDocuments: [Item] { items.filter { $0.status.isReady } }

    /// Refreshes on every ingestion change for as long as the caller keeps this task alive.
    func observe() async {
        // Subscribe before running, so the changes the run itself makes are not missed: this call may be the one that
        // does all the work (after a switch of embedding model, say), and nothing else would tell the list it finished.
        let updates = await ingestion.updates()
        await refresh()
        await ingestion.run()  // picks up work left over from a previous launch
        await refresh()
        var warming: Task<Void, Never>?
        for await job in updates {
            await refresh()
            if job.state == .ready, let onDocumentReady {
                // The first vector query after new data trains the index; do it now rather than on a user's question.
                warming?.cancel()
                warming = Task { try? await Task.sleep(for: .seconds(1)); if !Task.isCancelled { await onDocumentReady() } }
            }
        }
    }

    func refresh() async {
        guard let records = try? await documents.documents() else { return }
        let jobByDoc = Dictionary(((try? await jobs.jobs()) ?? []).map { ($0.docId, $0) }, uniquingKeysWith: { a, _ in a })
        items = records.map { record in
            Item(id: record.id, title: record.title, type: record.type, pageCount: record.pageCount,
                 imageCount: record.imageCount ?? 0, importedAt: record.importedAt,
                 status: Self.status(of: record, job: jobByDoc[record.id]))
        }.sorted { $0.importedAt > $1.importedAt }
    }

    static func status(of record: DocumentRecord, job: IngestJobRecord?) -> Status {
        let searchable = record.activeGeneration != nil
        guard let job else { return searchable ? .ready : .queued }
        switch job.state {
        case .queued: return searchable ? .updating(0) : .queued
        case .extracting: return searchable ? .updating(job.progress) : .extracting(job.progress)
        case .recognizingText: return searchable ? .updating(job.progress) : .recognizing(job.progress)
        case .analyzingImages: return searchable ? .updating(job.progress) : .analyzing(job.progress)
        case .embedding: return searchable ? .updating(job.progress) : .embedding(job.progress)
        case .ready: return .ready
        // A failed re-index leaves the previous index in place, so the document stays searchable.
        case .failed: return searchable ? .ready : .failed(job.error ?? "Indexing failed.")
        }
    }

    // MARK: Import

    /// Imports files the user picked or dropped. Unsupported types are reported, the rest are queued.
    func importFiles(_ urls: [URL]) async {
        rejections = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await ingestion.enqueue(fileURL: url)
            } catch IngestionError.photosUnavailable {
                rejections.append("\(url.lastPathComponent): \(photosExplanation ?? IngestionError.photosUnavailable.localizedDescription)")
            } catch {
                rejections.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        await refresh()
        Task { await ingestion.run() }
    }

    func dismissRejections() { rejections = [] }

    // MARK: Manage

    func rename(_ id: String, to title: String) async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var record = try? await documents.document(id: id) else { return }
        record.title = clean
        try? await documents.upsert(record)
        await refresh()
    }

    func delete(_ id: String) async {
        thumbnails[id] = nil
        try? await ingestion.delete(docId: id)
        await refresh()
    }

    /// The stored display copy of a photo document's picture, for its row in the library.
    func thumbnail(for id: String) async -> Data? {
        if let cached = thumbnails[id] { return cached }
        guard let image = try? await documents.activeImages(docId: id).first,
            let data = try? await documents.imageData(id: image.id)
        else { return nil }
        thumbnails[id] = data
        return data
    }

    func reindex(_ id: String) async {
        thumbnails[id] = nil
        try? await ingestion.reindex(docId: id)
        await refresh()
        Task { await ingestion.run() }
    }

    func retry(_ id: String) async { await reindex(id) }
}
