import CoreGraphics
import Foundation
import Ports

public enum IngestionError: Error, Equatable, LocalizedError {
    case unsupportedType(String)
    case noText
    case embeddingMismatch(expected: Int, got: Int)
    case documentNotFound(String)
    /// A photo was imported on a device that cannot analyze photos.
    case photosUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext): "Files of type “\(ext)” are not supported."
        case .noText: "No text could be found in the document."
        case .embeddingMismatch(let expected, let got): "The embedding model returned \(got) vectors or dimensions where \(expected) were expected."
        case .documentNotFound(let id): "Document \(id) no longer exists."
        case .photosUnavailable: "Photos cannot be analyzed on this device."
        }
    }
}

/// Turns imported files into searchable, citable passages. Work is a persistent queue of jobs that
/// resumes after the app is killed: chunk IDs are deterministic, so redoing a batch overwrites it
/// rather than duplicating it, and a document's passages only become visible in one atomic switch.
public actor IngestionService {
    private let extractor: any DocumentExtractor
    private let embedder: any Embedder
    private let repository: any DocumentRepository
    private let jobs: any IngestJobStore
    private let chunker: Chunker
    private let batchSize: Int
    private let supportedType: @Sendable (URL) -> DocumentType?
    private let tracer: any Tracer
    private let imageFeatures: (any ImageFeaturing)?
    private let recognizer: (any TextRecognizing)?
    private let imageBatchSize: Int

    private var observers: [UUID: AsyncStream<IngestJobRecord>.Continuation] = [:]
    private var running = false
    private var wakeRequested = false
    private var paused = false
    private var activeDocID: String?
    private var deleteRequested: Set<String> = []
    /// The operation (for example a demo reset) that asked for a deferred delete, so the removal is reported under it.
    private var deleteRequesters: [String: TraceOperation] = [:]
    /// The last job state reported per document, so only changes of state are traced, not every progress tick.
    private var tracedStates: [String: IngestState] = [:]

    public init(
        extractor: any DocumentExtractor, embedder: any Embedder, repository: any DocumentRepository,
        jobs: any IngestJobStore, chunker: Chunker = Chunker(), batchSize: Int = 16,
        supportedType: @escaping @Sendable (URL) -> DocumentType?, tracer: any Tracer = NoTracer(),
        imageFeatures: (any ImageFeaturing)? = nil, recognizer: (any TextRecognizing)? = nil, imageBatchSize: Int = 8
    ) {
        self.imageFeatures = imageFeatures
        self.recognizer = recognizer
        self.imageBatchSize = max(1, imageBatchSize)
        self.extractor = extractor
        self.embedder = embedder
        self.repository = repository
        self.jobs = jobs
        self.chunker = chunker
        self.batchSize = max(1, batchSize)
        self.supportedType = supportedType
        self.tracer = tracer
    }

    // MARK: Observation

    /// Every job change, in order. Nothing is dropped for a slow observer.
    public func updates() -> AsyncStream<IngestJobRecord> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<IngestJobRecord>.makeStream(bufferingPolicy: .unbounded)
        observers[token] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(token) } }
        return stream
    }

    private func removeObserver(_ token: UUID) { observers[token] = nil }

    private func save(_ job: IngestJobRecord) async throws {
        try await jobs.upsert(job: job)
        if tracer.isEnabled, tracedStates[job.docId] != job.state {
            tracedStates[job.docId] = job.state
            tracer.emit(.jobState(docId: job.docId, state: job.state.rawValue, progress: job.progress, localOnly: true))
        }
        for continuation in observers.values { continuation.yield(job) }
    }

    // MARK: Queueing

    /// Registers a file for indexing and returns its document ID. The original is stored with the
    /// document, so it can be shown and re-indexed later without importing again.
    @discardableResult
    public func enqueue(fileURL: URL, title: String? = nil) async throws -> String {
        guard let type = supportedType(fileURL) else {
            throw IngestionError.unsupportedType(fileURL.pathExtension.isEmpty ? "unknown" : fileURL.pathExtension)
        }
        let id = UUID().uuidString
        let name = title ?? fileURL.deletingPathExtension().lastPathComponent
        // Always its own group, even inside a demo reset, so each import reads as a complete story.
        return try await inOperation(Self.operation(docId: id, generation: 1, title: name), replacing: true) {
            try await repository.upsert(DocumentRecord(id: id, title: name, type: type))
            try await repository.attachOriginal(fileURL: fileURL, contentType: Self.contentType(for: type, fileURL: fileURL), to: id)
            try await save(IngestJobRecord(docId: id, targetGeneration: 1))
            wakeRequested = true
            return id
        }
    }

    /// Builds a complete new set of passages. The document stays searchable from its current set
    /// until the new one is ready and switched in.
    public func reindex(docId: String) async throws {
        guard let document = try await repository.document(id: docId) else { throw IngestionError.documentNotFound(docId) }
        let previous = try await jobs.job(docId: docId)?.targetGeneration ?? 0
        let generation = max(document.activeGeneration ?? 0, previous) + 1
        try await inOperation(Self.operation(docId: docId, generation: generation, title: document.title), replacing: true) {
            try await save(IngestJobRecord(docId: docId, targetGeneration: generation))
        }
        wakeRequested = true
    }

    // MARK: Deleting

    /// Removes a document with its passages, stored original and job. If the document is being indexed
    /// right now, indexing stops after the current batch and then everything is removed, so no passages
    /// are left behind.
    public func delete(docId: String) async throws {
        if activeDocID == docId {
            deleteRequested.insert(docId)
            if let requester = TraceContext.operation { deleteRequesters[docId] = requester }
            return
        }
        try await removeEverything(docId, as: nil, replacing: false)
    }

    /// `requester` is the operation that asked for a deferred delete; `replacing` is for that deferred removal,
    /// which runs inside an import's own operation.
    private func removeEverything(_ docId: String, as requester: TraceOperation?, replacing: Bool) async throws {
        tracedStates[docId] = nil
        guard tracer.isEnabled else { return try await purge(docId) }
        let operation: TraceOperation
        if let requester {
            operation = requester
        } else {
            let title = (try? await repository.document(id: docId))?.title ?? "document"
            operation = TraceOperation(id: "delete-\(docId)", kind: .delete, title: "Delete “\(title)”")
        }
        try await inOperation(operation, replacing: replacing) { try await purge(docId) }
    }

    private func purge(_ docId: String) async throws {
        try await repository.deleteDocument(id: docId)
        try await jobs.deleteJob(docId: docId)
    }

    // MARK: Tracing

    /// The user action an import or re-index belongs to, keyed by document and generation, so the
    /// events of `enqueue` and of the later background `process` land in one group.
    static func operation(docId: String, generation: Int, title: String) -> TraceOperation {
        generation == 1
            ? TraceOperation(id: "import-\(docId)", kind: .importDocument, title: "Import “\(title)”")
            : TraceOperation(id: "reindex-\(docId)-\(generation)", kind: .reindex, title: "Re-index “\(title)”")
    }

    /// Runs `body` as `operation`. A caller that already opened an operation (the demo reset) keeps it,
    /// unless `replacing` is set.
    private func inOperation<T>(
        _ operation: @autoclosure () -> TraceOperation, replacing: Bool = false, _ body: () async throws -> T
    ) async rethrows -> T {
        guard tracer.isEnabled else { return try await body() }
        if !replacing, TraceContext.operation != nil { return try await body() }
        return try await TraceContext.$operation.withValue(operation()) { try await body() }
    }

    /// Whether any job is still waiting or in progress (used to decide if background time is worth asking for).
    public func hasPendingWork() async -> Bool {
        ((try? await jobs.jobs()) ?? []).contains { !$0.isFinished }
    }

    // MARK: Pausing

    /// While paused, the running job waits between batches (the language model has priority while it answers).
    public func setPaused(_ value: Bool) { paused = value }


    private static func contentType(for type: DocumentType, fileURL: URL) -> String {
        switch type {
        case .text: "text/plain"
        case .markdown: "text/markdown"
        case .pdf: "application/pdf"
        case .docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case .image:
            switch fileURL.pathExtension.lowercased() {
            case "png": "image/png"
            case "heic": "image/heic"
            case "heif": "image/heif"
            default: "image/jpeg"
            }
        }
    }

    // MARK: Running

    /// Processes queued jobs, oldest first, until none are left. Jobs interrupted by an earlier
    /// run continue where they stopped. If the calling task is cancelled, the current job keeps its
    /// progress and resumes on the next run.
    public func run() async {
        // One loop at a time. A request that arrives while it is running just tells it to look again,
        // so a file imported at the last moment is never left waiting.
        guard !running else { wakeRequested = true; return }
        running = true
        defer { running = false }
        do {
            try await resetInterruptedJobs()
            repeat {
                wakeRequested = false
                while !Task.isCancelled {
                    guard let next = try await jobs.jobs().first(where: { $0.state == .queued }) else { break }
                    try await process(next)
                }
            } while wakeRequested && !Task.isCancelled
        } catch {
            // Only cancellation reaches here; job failures are recorded on the job.
        }
    }

    private func resetInterruptedJobs() async throws {
        for var job in try await jobs.jobs() where !job.isFinished && job.state != .queued {
            job.state = .queued
            try await save(job)
        }
    }

    private func process(_ queued: IngestJobRecord) async throws {
        guard tracer.isEnabled else { return try await processJob(queued) }
        let title = (try? await repository.document(id: queued.docId))?.title ?? "document"
        let operation = Self.operation(docId: queued.docId, generation: queued.targetGeneration, title: title)
        try await inOperation(operation, replacing: true) { try await processJob(queued) }
    }

    private func processJob(_ queued: IngestJobRecord) async throws {
        var job = queued
        activeDocID = job.docId
        defer { activeDocID = nil }
        do {
            guard let document = try await repository.document(id: job.docId) else {
                try await jobs.deleteJob(docId: job.docId)
                return
            }
            job.state = .extracting
            job.error = nil
            try await save(job)

            guard let file = try await repository.originalFileURL(docId: job.docId) else {
                throw IngestionError.documentNotFound(job.docId)
            }
            let extracted = try await extract(file, job: &job)
            if document.type == .image, imageFeatures == nil { throw IngestionError.photosUnavailable }
            var drafts = chunker.chunk(extracted.blocks)
            let imageDrafts = try await analyzeImages(extracted.images, of: document, firstOrdinal: drafts.count, job: &job)
            drafts += imageDrafts
            guard !drafts.isEmpty else { throw IngestionError.noText }

            job.state = .embedding
            job.progress = Double(min(job.nextOrdinal, drafts.count)) / Double(drafts.count)
            try await save(job)
            try await embed(drafts, of: document, job: &job)

            var updated = document
            updated.pageCount = extracted.pageCount
            updated.imageCount = imageDrafts.isEmpty ? nil : imageDrafts.count
            try await repository.upsert(updated)
            try await repository.activate(generation: job.targetGeneration, for: job.docId)

            job.state = .ready
            job.progress = 1
            try await save(job)
        } catch is DocumentDeletedDuringIngestion {
            deleteRequested.remove(job.docId)
            let requester = deleteRequesters.removeValue(forKey: job.docId)
            try await removeEverything(job.docId, as: requester, replacing: true)
        } catch is CancellationError {
            throw CancellationError()  // keep progress; the next run resumes
        } catch {
            job.state = .failed
            job.error = error.localizedDescription
            try await save(job)
        }
    }

    private func extract(_ file: URL, job: inout IngestJobRecord) async throws -> ExtractedDocument {
        let (stream, continuation) = AsyncStream<ExtractionEvent>.makeStream(bufferingPolicy: .unbounded)
        let snapshot = job
        let watcher = Task { () -> IngestJobRecord in
            var current = snapshot
            for await event in stream {
                switch event {
                case .page(let n, let total):
                    current.state = .extracting
                    current.progress = Double(n) / Double(max(total, 1))
                case .recognizing(let n, let total):
                    current.state = .recognizingText
                    current.progress = Double(n) / Double(max(total, 1))
                }
                try? await self.save(current)
            }
            return current
        }
        do {
            let result = try await extractor.extract(from: file) { continuation.yield($0) }
            continuation.finish()
            job = await watcher.value
            return result
        } catch {
            continuation.finish()
            job = await watcher.value
            throw error
        }
    }

    /// Between batches: waits while paused, and stops if the job was cancelled or its document deleted.
    private func checkpoint(_ docId: String) async throws {
        while paused && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        if deleteRequested.contains(docId) { throw DocumentDeletedDuringIngestion() }
    }

    /// Reads each image on the device (text in it, similarity vector, a display copy) and stores it. Images are
    /// stored in batches under deterministic IDs, so an interrupted job continues from `nextImage` and never
    /// leaves a second copy. Returns one passage per stored image, so images can be found by their words too.
    /// An image that cannot be analyzed is skipped; it never fails the document.
    private func analyzeImages(
        _ images: [ExtractedImage], of document: DocumentRecord, firstOrdinal: Int, job: inout IngestJobRecord
    ) async throws -> [ChunkDraft] {
        guard !images.isEmpty, let imageFeatures else { return [] }
        let generation = job.targetGeneration
        job.state = .analyzingImages
        job.progress = Double(min(job.nextImage, images.count)) / Double(images.count)
        try await save(job)

        var start = min(job.nextImage, images.count)
        while start < images.count {
            try await checkpoint(job.docId)
            let end = min(start + imageBatchSize, images.count)
            var writes: [ImageWrite] = []
            for index in start..<end {
                let started = tracer.isEnabled ? ContinuousClock.now : nil
                guard let write = try await analyze(images[index], n: index, docId: job.docId, generation: generation, features: imageFeatures)
                else { continue }
                writes.append(write)
                if let started {
                    tracer.emit(duration: started.duration(to: .now).seconds, .imageAnalyzed(
                        docId: job.docId, generation: generation, n: index, ocrLength: write.record.ocrText.count,
                        captionSource: write.record.captionSource.rawValue, dimensions: write.record.features.count))
                }
            }
            if deleteRequested.contains(job.docId) { throw DocumentDeletedDuringIngestion() }
            if !writes.isEmpty { try await repository.writeImages(writes) }
            start = end
            job.nextImage = end
            job.progress = Double(end) / Double(images.count)
            try await save(job)
        }

        return try await repository.images(docId: job.docId, generation: generation).enumerated().map { offset, image in
            ChunkDraft(
                ordinal: firstOrdinal + offset, page: image.page, heading: image.heading,
                text: ImagePassage.text(for: image, title: document.title, chunker: chunker), imageId: image.id)
        }
    }

    /// `nil` when the image cannot be analyzed. Cancellation is never treated as a failure of the image: it stops
    /// the job, which then resumes at this image.
    private func analyze(
        _ source: ExtractedImage, n: Int, docId: String, generation: Int, features: any ImageFeaturing
    ) async throws -> ImageWrite? {
        try Task.checkCancellation()
        // Recognized text is a bonus: an image whose text cannot be read is still kept and still found by its looks.
        var lines: [RecognizedLine] = []
        do {
            lines = try await recognizer?.recognize(source.image, correctLanguage: false) ?? []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lines = []
        }
        let vector: [Float]
        do {
            vector = try await features.features(of: source.image)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        try Task.checkCancellation()
        guard vector.count == features.identity.dimensions, let copy = try? DisplayCopy.jpeg(from: source.image) else { return nil }
        let record = ImageRecord(
            docId: docId, generation: generation, n: n, page: source.page, heading: source.heading, caption: source.caption,
            captionSource: source.captionSource, ocrText: lines.map(\.text).joined(separator: " "),
            width: source.image.width, height: source.image.height, features: vector, featureModel: features.identity.tag)
        return ImageWrite(record: record, displayCopy: copy)
    }

    private func embed(_ drafts: [ChunkDraft], of document: DocumentRecord, job: inout IngestJobRecord) async throws {
        let identity = embedder.identity
        var start = min(job.nextOrdinal, drafts.count)
        while start < drafts.count {
            try await checkpoint(job.docId)
            let end = min(start + batchSize, drafts.count)
            let batch = Array(drafts[start..<end])
            let vectors = try await embedder.embed(batch.map(\.text), kind: .passage(title: document.title))
            guard vectors.count == batch.count, vectors.allSatisfy({ $0.count == identity.dimensions }) else {
                throw IngestionError.embeddingMismatch(expected: identity.dimensions, got: vectors.first?.count ?? vectors.count)
            }
            if deleteRequested.contains(job.docId) { throw DocumentDeletedDuringIngestion() }
            try await repository.writeChunks(zip(batch, vectors).map { draft, vector in
                Chunk(docId: job.docId, generation: job.targetGeneration, ordinal: draft.ordinal, page: draft.page,
                      heading: draft.heading, text: draft.text, embedding: vector, embeddingModel: identity.tag,
                      imageId: draft.imageId)
            })
            start = end
            job.nextOrdinal = end
            job.progress = Double(end) / Double(drafts.count)
            try await save(job)
        }
        if deleteRequested.contains(job.docId) { throw DocumentDeletedDuringIngestion() }
    }
}

private struct DocumentDeletedDuringIngestion: Error {}
