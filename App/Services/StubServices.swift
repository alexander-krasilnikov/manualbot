import Adapters
import Core
import Foundation
import Ports
import PortsTesting

/// Real database, extraction, ingestion, retrieval and chat logic with a stand-in embedder and a scripted
/// language model, so UI tests run instantly and offline. Enabled by `-uiTestServices`.
final class StubServiceFactory: ServiceFactory, @unchecked Sendable {
    struct Options: Sendable {
        var seedDocuments = false
        var slowAnswers = false
        /// Models (by id) that cannot be loaded: choosing one fails, as a file the runtime cannot run would.
        var failingModels: Set<String> = []
    }

    struct CannotLoad: LocalizedError {
        let title: String
        var errorDescription: String? { "The model “\(title)” could not be loaded." }
    }

    /// The stand-in's distances (hashed words, colour cells) are on their own scale, far above the real model's.
    static let maxDistance = 0.76

    /// Distances between the stand-in image features are on their own scale; see `SamplePhotoMatchTests`.
    static let imageMaxDistance = 0.5

    let options: Options
    private let tracer: any Tracer
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(UUID().uuidString)")
    private let lock = NSLock()
    /// The sample documents are added once, not again when the services are rebuilt after a switch of models.
    private var seeded = false

    init(options: Options, tracer: any Tracer = NoTracer()) {
        self.options = options
        self.tracer = tracer
    }

    /// Words that find the X100 nameplate photo in the stub, standing in for the real model's shared space.
    static let nameplatePhrase = "x100 nameplate"
    /// The stand-in's words-to-photo distances are on their own scale: an anchored question is the photo's own vector.
    static let textToImageMaxDistance = 0.15

    /// The stand-in embedding model's profile. Its distances are the stand-in's own scale; chunks use the default sizes.
    static let profile = EmbedderProfile(
        identity: EmbeddingModelIdentity(id: "fake-joint", version: "1", dimensions: 768),
        prompts: EmbeddingPrompts(query: "", passageWithTitle: "", passage: "", titleLimit: 60),
        maxInputLength: 512, outputSize: 768, chunker: ChunkerConfiguration(),
        thresholds: RelevanceThresholds(text: maxDistance, image: imageMaxDistance, textToImage: textToImageMaxDistance),
        supportsImages: true)

    /// A second stand-in embedder, without photos, for trying a switch of embedding model.
    static let textOnlyProfile = EmbedderProfile(
        identity: EmbeddingModelIdentity(id: "fake-text", version: "1", dimensions: 768),
        prompts: EmbeddingPrompts(query: "", passageWithTitle: "", passage: "", titleLimit: 60),
        maxInputLength: 512, outputSize: 768, chunker: ChunkerConfiguration(),
        thresholds: RelevanceThresholds(text: maxDistance, image: imageMaxDistance, textToImage: textToImageMaxDistance),
        supportsImages: false)

    /// The embedders the stub offers: the one the stub model manifest names (`AppEnvironment`), and a text-only one.
    static let catalog = EmbedderCatalog(embedders: [
        EmbedderCatalogEntry(
            spec: ModelSpec(
                id: "embeddinggemma-2-text-vision-440m", version: "1", role: .embedder, url: URL(string: "https://example.invalid/embed")!,
                bytes: 388_000_000, sha256: String(repeating: "a", count: 64), fileName: "embed.bin", displayName: "EmbeddingGemma 2",
                licence: "Apache License 2.0"),
            profile: profile),
        EmbedderCatalogEntry(
            spec: ModelSpec(
                id: "stub-text-embedder", version: "1", role: .embedder, url: URL(string: "https://example.invalid/text-embed")!,
                bytes: 150_000_000, sha256: String(repeating: "b", count: 64), fileName: "text-embed.bin", displayName: "Stub Text Embedder",
                licence: "MIT License"),
            profile: textOnlyProfile),
    ])

    func makeCore(embedder selection: EmbedderSelection, onProgress: @escaping @Sendable (String) -> Void) async throws -> CoreServices {
        // One stand-in model for words and photos, like the real one. Which pictures words find is scripted.
        let profile = selection.profile
        if options.failingModels.contains(selection.spec.id) { throw CannotLoad(title: selection.spec.title) }
        let nameplate = PhotoData.image(from: SampleDocuments.nameplatePhoto(model: "X100-A", serial: "2208-91", style: .label))
        let model = FakeJointEmbedder(identity: profile.identity, anchors: nameplate.map { [(Self.nameplatePhrase, $0)] } ?? [])
        let identity = model.identity
        // Text on photos is read by the operating system, so that is real here.
        let recognizer = VisionTextRecognizer()
        let repository = try CouchbaseDocumentRepository(
            directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("originals"),
            embedding: identity, imageFeatures: identity, tracer: tracer)
        let extractor = FileDocumentExtractor()
        let ingestion = IngestionService(
            extractor: extractor, embedder: model, repository: repository, jobs: repository,
            chunker: Chunker(configuration: profile.chunker), supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer,
            imageFeatures: profile.supportsImages ? model : nil, recognizer: recognizer)
        let retriever = Retriever(
            embedder: model, search: repository, repository: repository,
            configuration: profile.retrievalConfiguration(), tracer: tracer,
            photoSearch: profile.supportsImages ? PhotoSearch(features: model, search: repository, recognizer: recognizer) : nil)
        let core = CoreServices(
            repository: repository, ingestion: ingestion, retriever: retriever, extractor: extractor, embedding: identity,
            supportsPhotos: profile.supportsImages, photosExplanation: selection.photosExplanation)
        let firstTime = lock.withLock { () -> Bool in defer { seeded = true }; return !seeded }
        if options.seedDocuments, firstTime { try await seed(core) }
        return core
    }

    func makeChat(core: CoreServices, generator: ModelSpec) async throws -> ChatService {
        ChatService(
            chats: core.repository, retriever: core.retriever, generator: StubGenerator(slow: options.slowAnswers), tracer: tracer)
    }

    func verifyChat(generator: ModelSpec) async throws {
        if options.failingModels.contains(generator.id) { throw CannotLoad(title: generator.title) }
    }

    func unloadModels() async {}

    /// The X200's nameplate: what the attach button provides in UI tests.
    var stubPhoto: Data? { SampleDocuments.x200Nameplate }

    private func seed(_ core: CoreServices) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manual = root.appendingPathComponent("X200 Manual.txt")
        try """
            To reset the X200 to factory defaults, hold the power button for ten seconds until the indicator light blinks twice.

            Error E-042 means the motor has overheated. Switch the unit off and wait thirty minutes before restarting it.
            """.write(to: manual, atomically: true, encoding: .utf8)
        let warranty = root.appendingPathComponent("Warranty.md")
        try "# Warranty\n\nThe X200 is covered by a two year limited warranty from the date of purchase.".write(to: warranty, atomically: true, encoding: .utf8)
        let pdf = root.appendingPathComponent("Filter Guide.pdf")
        try SampleDocuments.makePDF(pages: [
            "This guide explains how to look after the filter of the purifier.",
            "Replace the HEPA filter every six months by opening the rear panel and sliding out the old filter.",
            "Dispose of the used filter with household waste and record the date in the service log.",
        ]).write(to: pdf)
        let serviceManual = root.appendingPathComponent("X200 Service Manual.pdf")
        try SampleDocuments.makeServiceManual(cropFigure: false).write(to: serviceManual)
        let nameplate = root.appendingPathComponent("Nameplate X100.jpg")
        try SampleDocuments.nameplatePhoto(model: "X100-A", serial: "2208-91", style: .label).write(to: nameplate)
        _ = try await core.ingestion.enqueue(fileURL: pdf)
        _ = try await core.ingestion.enqueue(fileURL: serviceManual)
        _ = try await core.ingestion.enqueue(fileURL: nameplate)
        _ = try await core.ingestion.enqueue(fileURL: manual)
        _ = try await core.ingestion.enqueue(fileURL: warranty)
        await core.ingestion.run()
    }
}

/// Answers from the first numbered chunk and cites it; rewrites follow-ups to themselves.
struct StubGenerator: Generator {
    var slow = false

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        let text = Self.reply(to: request)
        let delay = slow
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled { break }
                    continuation.yield(String(word) + " ")
                    if delay { try? await Task.sleep(for: .milliseconds(120)) } else { await Task.yield() }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func reply(to request: GenerationRequest) -> String {
        if request.maxTokens == 64 {  // query rewriting: keep the last question as is
            return request.prompt.components(separatedBy: "Last question: ").last?
                .components(separatedBy: "\n").first ?? ""
        }
        guard let first = request.prompt.components(separatedBy: "\n").first(where: { $0.hasPrefix("[1] ") }) else { return "NOT_FOUND" }
        let body = first.drop(while: { $0 != ")" }).dropFirst().trimmingCharacters(in: .whitespaces)
        let sentence = body.split(separator: ".").first.map(String.init) ?? body
        // Repeat the sentence a few times so the answer is long enough to stop part-way.
        return (0..<6).map { _ in "\(sentence) [1]." }.joined(separator: " ")
    }
}
