import Core
import Foundation
import Ports
import Testing
@testable import Adapters

/// One entry of each category, downloaded from its publisher by the app's downloader, imported through the catalog import,
/// indexed by the real models and asked about in the chat. Opt in with RUN_NETWORK_TESTS=1 and both model paths:
///
///     RUN_NETWORK_TESTS=1 EMBEDDER_MODEL_PATH=…/embeddinggemma-2-text-vision-440m.litertlm \
///       GENERATOR_MODEL_PATH=…/gemma-4-E2B-it.litertlm swift test --filter ManualCatalogRealStackTests
private let embedderPath = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"]
private let generatorPath = ProcessInfo.processInfo.environment["GENERATOR_MODEL_PATH"]
private let enabled = ProcessInfo.processInfo.environment["RUN_NETWORK_TESTS"] == "1" && embedderPath != nil && generatorPath != nil

@Suite(.serialized, .enabled(if: enabled)) struct ManualCatalogRealStackTests {
    /// One small entry per category: two from archive.org and info.couchbase.com are among them, the hosts the spec names.
    static let picks = [
        "2025-mazda-cx-5-specifications-features-canada", "harley-davidson-2026-e-brochure-uk",
        "service-letter-sl2023-738-sampling-of-scavenge-drain-oil-feed", "honda-bf25a-bf30a-outboard-owners-manual-2002",
        "powerflex-4-adjustable-frequency-ac-drive-user-manual-22a-um001", "small-wind-electric-systems-a-u-s-consumers-guide",
        "ufm-3-540-07-operation-and-maintenance-generators-2026", "tm-9-6115-641-10-operators-manual-generator-set-skid-mounted",
        "couchbase-capella-datasheet",
    ]

    private var bundledCatalogURL: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("App/Resources/ManualCatalog.json")
    }

    @Test(arguments: picks) func anEntryDownloadsIndexesAndAnswers(_ id: String) async throws {
        let catalog = try ManualCatalog.decode(from: Data(contentsOf: bundledCatalogURL))
        let entry = try #require(catalog.entry(id: id), "the catalog no longer has \(id): pick another small entry")

        let embedder = LiteRTEmbedder(profile: EvalProfile.current, modelPath: try #require(embedderPath))
        let generator = LiteRTGenerator(modelPath: try #require(generatorPath))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-stack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CouchbaseDocumentRepository(
            directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("o"),
            embedding: EvalProfile.current.identity)
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: repo, jobs: repo,
            chunker: Chunker(configuration: EvalProfile.current.chunker), supportedType: FileDocumentExtractor.documentType(for:))
        let importer = CatalogImporter(downloader: URLSessionManualDownloader(), ingestion: ingestion, repository: repo)

        let result = try await importer.importEntry(entry)
        #expect(result.outcome == .imported)
        #expect(!result.publisherUpdatedFile, "the publisher has changed \(id) since the catalog was prepared: run refresh")
        await ingestion.run()
        let job = try await repo.job(docId: entry.documentID)
        #expect(job?.state == .ready, "\(entry.host): \(String(describing: job))")
        let chunks = try await repo.activeChunks(docId: entry.documentID)
        #expect(!chunks.isEmpty)
        #expect(try await repo.document(id: entry.documentID)?.origin?.host == entry.host)

        let retriever = Retriever(embedder: embedder, search: repo, repository: repo, configuration: EvalProfile.current.retrievalConfiguration())
        let chat = ChatService(chats: repo, retriever: retriever, generator: generator)
        let thread = try await repo.createChat()
        var reply: MessageRecord?
        for try await event in chat.ask("What is “\(entry.title)” about?", in: thread.id) { if case .completed(let message) = event { reply = message } }
        let answer = try #require(reply)
        print("CATALOG \(entry.category) / \(entry.host): \(chunks.count) chunks;", answer.notFound ? "NOT FOUND" : answer.text.prefix(160), "| cited:", answer.citations.map(\.docTitle))
        #expect(!answer.notFound, "\(entry.title) was imported but the chat found nothing in it")
        #expect(answer.citations.contains { $0.docId == entry.documentID })
    }
}
