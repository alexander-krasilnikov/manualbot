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
}

/// Builds the real services, or stand-ins for UI tests. Building is staged because the models arrive in stages.
protocol ServiceFactory: Sendable {
    /// Needs the embedding model: opens the database and loads the embedder.
    func makeCore(onProgress: @escaping @Sendable (String) -> Void) async throws -> CoreServices
    /// Needs the language model as well.
    func makeChat(core: CoreServices) async throws -> ChatService
    /// Frees model memory (memory warnings). Models reload on next use.
    func unloadModels() async
}

enum ServiceError: LocalizedError {
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name): "The model “\(name)” is not installed."
        }
    }
}

/// The production wiring: Core ML embedder, LiteRT-LM generator, Couchbase Lite.
final class LiveServiceFactory: ServiceFactory, @unchecked Sendable {
    private let manifest: ModelManifest
    private let files: FileModelFiles
    private let support: URL
    private let caches: URL
    private let tracer: any Tracer
    private let lock = NSLock()
    private var embedder: CoreMLEmbedder?
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
        let modelURL = files.installedURL(for: embedderSpec)
        let identity = EmbeddingModelIdentity(id: embedderSpec.id, version: embedderSpec.version, dimensions: 768)

        onProgress("Loading the tokenizer…")
        let tokenizer = try await GemmaTokenizer(folder: modelURL.deletingLastPathComponent().appendingPathComponent("hf_model"))
        let embedder = CoreMLEmbedder(modelURL: modelURL, tokenizer: tokenizer, identity: identity)
        // The first inference after install specializes the model for the Neural Engine, which can take a minute.
        onProgress("Preparing the search model for this iPad. This happens once and can take a minute…")
        _ = try await embedder.embed(["warm up"], kind: .query)
        lock.withLock { self.embedder = embedder }

        onProgress("Opening your library…")
        let repository = try CouchbaseDocumentRepository(
            directory: support.appendingPathComponent("Database", isDirectory: true),
            originalsCache: caches.appendingPathComponent("Originals", isDirectory: true), embedding: identity,
            tracer: tracer)
        let extractor = FileDocumentExtractor()
        let ingestion = IngestionService(
            extractor: extractor, embedder: embedder, repository: repository, jobs: repository,
            chunker: Chunker(configuration: .embeddingGemma, counter: tokenizer),
            supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer)
        let retriever = Retriever(embedder: embedder, search: repository, repository: repository, tracer: tracer)
        return CoreServices(repository: repository, ingestion: ingestion, retriever: retriever, extractor: extractor)
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
