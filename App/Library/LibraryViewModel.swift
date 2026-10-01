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
        case embedding(Double)
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
        var isWorking: Bool {
            switch self {
            case .queued, .extracting, .recognizing, .embedding: true
            case .ready, .failed: false
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id: String
        var title: String
        var type: DocumentType
        var pageCount: Int?
        var importedAt: Date
        var status: Status
    }

    private(set) var items: [Item] = []
    /// Files that could not be imported, each with the reason.
    private(set) var rejections: [String] = []

    private let documents: any DocumentRepository
    private let jobs: any IngestJobStore
    private let ingestion: IngestionService
    /// Called after a document becomes searchable (used to warm up the vector index).
    private let onDocumentReady: (@Sendable () async -> Void)?

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
        await refresh()
        await ingestion.run()  // picks up work left over from a previous launch
        var warming: Task<Void, Never>?
        for await job in await ingestion.updates() {
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
                 importedAt: record.importedAt, status: Self.status(of: record, job: jobByDoc[record.id]))
        }.sorted { $0.importedAt > $1.importedAt }
    }

    static func status(of record: DocumentRecord, job: IngestJobRecord?) -> Status {
        guard let job else { return record.activeGeneration == nil ? .queued : .ready }
        switch job.state {
        case .queued: return record.activeGeneration == nil ? .queued : .ready  // a re-index keeps the old passages searchable
        case .extracting: return record.activeGeneration == nil ? .extracting(job.progress) : .ready
        case .recognizingText: return record.activeGeneration == nil ? .recognizing(job.progress) : .ready
        case .embedding: return record.activeGeneration == nil ? .embedding(job.progress) : .ready
        case .ready: return .ready
        case .failed: return record.activeGeneration == nil ? .failed(job.error ?? "Indexing failed.") : .ready
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
        try? await ingestion.delete(docId: id)
        await refresh()
    }

    func reindex(_ id: String) async {
        try? await ingestion.reindex(docId: id)
        await refresh()
        Task { await ingestion.run() }
    }

    func retry(_ id: String) async { await reindex(id) }
}
