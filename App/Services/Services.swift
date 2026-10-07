import Adapters
import Core
import Foundation
import Ports

/// Everything the screens need once the embedding model is ready.
struct CoreServices: Sendable {
    let repository: CouchbaseDocumentRepository
    let ingestion: IngestionService
    let retriever: Retriever
    let extractor: any DocumentExtractor
    /// The embedding model that makes every vector in this library from now on.
    let embedding: EmbeddingModelIdentity
    /// Whether this device can analyze photos. Without it, photo controls are hidden and photo imports are refused.
    var supportsPhotos = true
}

/// Builds the real services, or stand-ins for UI tests. Building is staged because the models arrive in stages.
protocol ServiceFactory: Sendable {
    /// Needs the embedding model: opens the database and loads the embedder.
    func makeCore(onProgress: @escaping @Sendable (String) -> Void) async throws -> CoreServices
    /// Needs the language model as well.
    func makeChat(core: CoreServices) async throws -> ChatService
    /// Frees model memory (memory warnings). Models reload on next use.
    func unloadModels() async
    /// UI tests have no photo picker to drive: a photo the attach button uses instead. `nil` in the real app.
    var stubPhoto: Data? { get }
}

extension ServiceFactory {
    var stubPhoto: Data? { nil }
}

enum ServiceError: LocalizedError {
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name): "The model “\(name)” is not installed."
        }
    }
}

/// The production wiring: LiteRT-LM embedder and generator, Couchbase Lite.
final class LiveServiceFactory: ServiceFactory, @unchecked Sendable {
    private let manifest: ModelManifest
    private let files: FileModelFiles
    private let support: URL
    private let caches: URL
    private let tracer: any Tracer
    private let lock = NSLock()
    private var embedder: LiteRTEmbedder?
    private var generator: LiteRTGenerator?

    init(manifest: ModelManifest, files: FileModelFiles, applicationSupport: URL, caches: URL, tracer: any Tracer = NoTracer()) {
        self.tracer = tracer
        self.manifest = manifest
        self.files = files
        self.support = applicationSupport
        self.caches = caches
    }

    private func spec(_ role: ModelRole) throws -> ModelSpec {
        guard let spec = manifest.models.first(where: { $0.role == role }), files.isInstalled(spec) else {
            throw ServiceError.modelNotInstalled(role == .embedder ? "embedder" : "language model")
        }
        return spec
    }

    func makeCore(onProgress: @escaping @Sendable (String) -> Void) async throws -> CoreServices {
        let embedderSpec = try spec(.embedder)
        // The embedder decides the identity of every vector it makes; the manifest only says which file to load.
        let embedder = LiteRTEmbedder(modelPath: files.installedURL(for: embedderSpec).path, cacheDirectory: caches.path)
        let identity = embedder.identity
        // The first use loads the model and compiles its GPU programs, which can take several seconds.
        onProgress("Preparing the search model…")
        _ = try await embedder.embed(["warm up"], kind: .query)
        lock.withLock { self.embedder = embedder }

        onProgress("Opening your library…")
        let recognizer = VisionTextRecognizer()
        let repository = try CouchbaseDocumentRepository(
            directory: support.appendingPathComponent("Database", isDirectory: true),
            originalsCache: caches.appendingPathComponent("Originals", isDirectory: true), embedding: identity,
            imageFeatures: identity, tracer: tracer)
        let extractor = FileDocumentExtractor()
        let ingestion = IngestionService(
            extractor: extractor, embedder: embedder, repository: repository, jobs: repository,
            chunker: Chunker(configuration: .embeddingGemma2),
            supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer, imageFeatures: embedder, recognizer: recognizer)
        let retriever = Retriever(
            embedder: embedder, search: repository, repository: repository, tracer: tracer,
            photoSearch: PhotoSearch(features: embedder, search: repository, recognizer: recognizer))
        return CoreServices(
            repository: repository, ingestion: ingestion, retriever: retriever, extractor: extractor, embedding: identity)
    }

    func makeChat(core: CoreServices) async throws -> ChatService {
        let generatorSpec = try spec(.generator)
        let generator = LiteRTGenerator(modelPath: files.installedURL(for: generatorSpec).path, cacheDirectory: caches.path)
        lock.withLock { self.generator = generator }
        return ChatService(chats: core.repository, retriever: core.retriever, generator: generator, tracer: tracer)
    }

    func unloadModels() async {
        let (embedder, generator) = lock.withLock { (self.embedder, self.generator) }
        await embedder?.unload()
        await generator?.unload()
    }
}
