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
    /// Whether the embedding model in use can analyze photos. Without it, photo controls explain why and photo imports are refused.
    var supportsPhotos = true
    /// Why photos cannot be analyzed, in words for the user. `nil` when they can.
    var photosExplanation: String?
}

/// The embedding model in use, and the profile that says how to ask it and what its answers mean.
struct EmbedderSelection: Sendable {
    let spec: ModelSpec
    let profile: EmbedderProfile
    /// False for an embedding model that is not in the built-in list: its profile is generic.
    var isTested = true

    /// What to tell the user when this embedding model cannot analyze photos. `nil` when it can.
    var photosExplanation: String? {
        profile.supportsImages ? nil
            : "The embedding model in use, \(spec.title), cannot analyze photos, so photo search is off. Choose another embedding model in Settings to search by photo."
    }
}

/// Builds the real services, or stand-ins for UI tests. Building is staged because the models arrive in stages.
/// The models to build from are passed in: the factory never chooses a model itself.
protocol ServiceFactory: Sendable {
    /// Needs the embedding model: opens the database and loads the embedder.
    func makeCore(embedder: EmbedderSelection, onProgress: @escaping @Sendable (String) -> Void) async throws -> CoreServices
    /// Needs the language model as well.
    func makeChat(core: CoreServices, generator: ModelSpec) async throws -> ChatService
    /// Loads the language model now, so that one that cannot be loaded is found out when it is chosen, not at the first question.
    func verifyChat(generator: ModelSpec) async throws
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
    /// The embedding model in use is not one the app has a profile for (for example after an update that dropped it).
    case unknownEmbedder(String)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let name): "The model “\(name)” is not installed."
        case .unknownEmbedder(let name): "The app has no settings for the embedding model “\(name)”."
        }
    }
}

/// The production wiring: LiteRT-LM embedder and generator, Couchbase Lite.
final class LiveServiceFactory: ServiceFactory, @unchecked Sendable {
    private let files: FileModelFiles
    private let support: URL
    private let caches: URL
    private let tracer: any Tracer
    private let lock = NSLock()
    private var embedder: LiteRTEmbedder?
    private var generator: LiteRTGenerator?

    init(files: FileModelFiles, applicationSupport: URL, caches: URL, tracer: any Tracer = NoTracer()) {
        self.tracer = tracer
        self.files = files
        self.support = applicationSupport
        self.caches = caches
    }

    private func installedPath(of spec: ModelSpec) throws -> String {
        guard files.isInstalled(spec) else { throw ServiceError.modelNotInstalled(spec.title) }
        return files.installedURL(for: spec).path
    }

    func makeCore(embedder selection: EmbedderSelection, onProgress: @escaping @Sendable (String) -> Void) async throws -> CoreServices {
        let profile = selection.profile
        // The profile decides the identity of every vector the embedder makes; the spec only says which file to load.
        let embedder = LiteRTEmbedder(profile: profile, modelPath: try installedPath(of: selection.spec), cacheDirectory: caches.path)
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
        // A model without photos in its vector space has no image features: photos are neither indexed nor searched.
        let imageFeatures: (any ImageFeaturing)? = profile.supportsImages ? embedder : nil
        let ingestion = IngestionService(
            extractor: extractor, embedder: embedder, repository: repository, jobs: repository,
            chunker: Chunker(configuration: profile.chunker),
            supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer, imageFeatures: imageFeatures, recognizer: recognizer)
        let retriever = Retriever(
            embedder: embedder, search: repository, repository: repository, configuration: profile.retrievalConfiguration(),
            tracer: tracer, photoSearch: imageFeatures.map { PhotoSearch(features: $0, search: repository, recognizer: recognizer) })
        return CoreServices(
            repository: repository, ingestion: ingestion, retriever: retriever, extractor: extractor, embedding: identity,
            supportsPhotos: profile.supportsImages, photosExplanation: selection.photosExplanation)
    }

    func makeChat(core: CoreServices, generator spec: ModelSpec) async throws -> ChatService {
        let generator = LiteRTGenerator(modelPath: try installedPath(of: spec), cacheDirectory: caches.path)
        lock.withLock { self.generator = generator }
        return ChatService(chats: core.repository, retriever: core.retriever, generator: generator, tracer: tracer)
    }

    func verifyChat(generator _: ModelSpec) async throws {
        let generator = lock.withLock { self.generator }
        try await generator?.warmUp()
    }

    func unloadModels() async {
        let (embedder, generator) = lock.withLock { (self.embedder, self.generator) }
        await embedder?.unload()
        await generator?.unload()
    }
}
