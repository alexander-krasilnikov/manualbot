@preconcurrency import CouchbaseLiteSwift
import Foundation
import Core
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// A library made with the previous embedding model has 768-dimension vector indexes. The new model's vectors have 256
/// floats, and an index silently ignores vectors of any other length, so the indexes must be created again.
@Suite struct CouchbaseIndexMigrationTests {
    static let old = EmbeddingModelIdentity(id: "embeddinggemma-300m", version: "1", dimensions: 768)
    static let new = EmbeddingModelIdentity(id: "embeddinggemma-2-text-vision-440m", version: "1", dimensions: 256)

    private func open(_ root: URL, text: EmbeddingModelIdentity, images: EmbeddingModelIdentity) throws -> CouchbaseDocumentRepository {
        try CouchbaseDocumentRepository(
            directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("originals"),
            embedding: text, imageFeatures: images)
    }

    private func vector(_ hot: Int, dimensions: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        v[hot % dimensions] = 1
        return v
    }

    private func chunks(_ model: EmbeddingModelIdentity, count: Int, doc: String = "d1", generation: Int = 1) -> [Chunk] {
        (0..<count).map {
            Chunk(docId: doc, generation: generation, ordinal: $0, page: $0 + 1, text: "passage \($0) about valves",
                  embedding: vector($0, dimensions: model.dimensions), embeddingModel: model.tag)
        }
    }

    private func image(_ model: EmbeddingModelIdentity, n: Int, doc: String = "d1", generation: Int = 1) -> ImageWrite {
        ImageWrite(
            record: ImageRecord(docId: doc, generation: generation, n: n, page: n + 1, width: 10, height: 10,
                                features: vector(n, dimensions: model.dimensions), featureModel: model.tag),
            displayCopy: Data([0]))
    }

    @Test func aLibraryOfAnotherDimensionGetsNewIndexesAndFindsNewVectors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // The previous version: 768-dimension indexes holding passages and a photo.
        let before = try open(root, text: Self.old, images: Self.old)
        try await before.upsert(DocumentRecord(id: "d1", title: "Old", type: .pdf))
        try await before.writeChunks(chunks(Self.old, count: 120))
        try await before.writeImages([image(Self.old, n: 0)])
        try await before.activate(generation: 1, for: "d1")
        try await before.close()

        // The new version opens the same database with 256-dimension identities.
        let after = try open(root, text: Self.new, images: Self.new)
        try await after.upsert(DocumentRecord(id: "d2", title: "New", type: .pdf))
        try await after.writeChunks(chunks(Self.new, count: 120, doc: "d2"))
        try await after.writeImages([image(Self.new, n: 0, doc: "d2"), image(Self.new, n: 1, doc: "d2")])
        try await after.activate(generation: 1, for: "d2")

        let textPlan = try await after.explain(
            "SELECT meta().id FROM manualbot.chunks ORDER BY APPROX_VECTOR_DISTANCE(embedding, $vector, \"cosine\") LIMIT 5",
            vector: vector(3, dimensions: 256))
        #expect(textPlan.contains(CouchbaseSchema.vectorIndex), "\(textPlan)")
        let imagePlan = try await after.explain(
            "SELECT meta().id FROM manualbot.images ORDER BY APPROX_VECTOR_DISTANCE(features, $vector, \"cosine\") LIMIT 5",
            vector: vector(1, dimensions: 256))
        #expect(imagePlan.contains(CouchbaseSchema.imageVectorIndex), "\(imagePlan)")

        // New 256-dimension vectors are searchable, and old ones do not appear.
        let hits = try await after.vectorSearch(vector(7, dimensions: 256), limit: 5, filter: SearchFilter(embeddingModel: Self.new.tag))
        #expect(hits.first?.chunk.id == "d2:1:7", "\(hits.map(\.chunk.id))")
        #expect(hits.allSatisfy { $0.chunk.docId == "d2" })
        let photos = try await after.imageSearch(vector(1, dimensions: 256), limit: 5, filter: SearchFilter(embeddingModel: Self.new.tag))
        #expect(photos.first?.image.n == 1 && photos.first?.image.docId == "d2", "\(photos.map { "\($0.image.docId)#\($0.image.n)" })")
        #expect(photos.allSatisfy { $0.image.docId == "d2" })
        try await after.close()
    }

    /// The sequence number of the record of index dimensions: it changes only when an index was created again.
    private func recordSequence(_ root: URL) throws -> UInt64 {
        var config = DatabaseConfiguration()
        config.directory = root.appendingPathComponent("db").path
        let database = try Database(name: "manualbot", config: config)
        defer { try? database.close() }
        let meta = try #require(try database.collection(name: CouchbaseSchema.localMeta, scope: CouchbaseSchema.scope))
        return try #require(try meta.document(id: CouchbaseSchema.vectorDimensionsDocument)).sequence
    }

    @Test func theIndexesAreKeptWhenTheDimensionIsUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try open(root, text: Self.new, images: Self.new)
        try await first.upsert(DocumentRecord(id: "d1", title: "Doc", type: .pdf))
        try await first.writeChunks(chunks(Self.new, count: 120))
        try await first.activate(generation: 1, for: "d1")
        try await first.close()
        let recorded = try recordSequence(root)

        let second = try open(root, text: Self.new, images: Self.new)
        let hits = try await second.vectorSearch(vector(5, dimensions: 256), limit: 3, filter: SearchFilter(embeddingModel: Self.new.tag))
        #expect(hits.first?.chunk.id == "d1:1:5")
        try await second.close()
        #expect(try recordSequence(root) == recorded, "reopening with the same dimensions must not rebuild the indexes")
    }

    @Test func aDatabaseFromBeforeTheDimensionWasRecordedIsRebuiltOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try open(root, text: Self.old, images: Self.old)
        try await first.close()

        // Forget what was recorded, as a database made by the previous app version would have it.
        var config = DatabaseConfiguration()
        config.directory = root.appendingPathComponent("db").path
        let database = try Database(name: "manualbot", config: config)
        let meta = try #require(try database.collection(name: CouchbaseSchema.localMeta, scope: CouchbaseSchema.scope))
        try meta.delete(document: try #require(try meta.document(id: CouchbaseSchema.vectorDimensionsDocument)))
        try database.close()

        let second = try open(root, text: Self.new, images: Self.new)
        try await second.writeChunks(chunks(Self.new, count: 120))
        try await second.upsert(DocumentRecord(id: "d1", title: "Doc", type: .pdf))
        try await second.activate(generation: 1, for: "d1")
        let hits = try await second.vectorSearch(vector(9, dimensions: 256), limit: 3, filter: SearchFilter(embeddingModel: Self.new.tag))
        #expect(hits.first?.chunk.id == "d1:1:9")
        try await second.close()
    }

    @Test func aChangeOfModelReindexesTheLibraryWhileKeywordSearchKeepsWorking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reindex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fx = Fixtures()
        let file = fx.write(Data((0..<40).map { "Step \($0): check valve \($0) and the pressure gauge. " }.joined().utf8), as: "valves.txt")
        func service(_ repo: CouchbaseDocumentRepository, _ model: EmbeddingModelIdentity) -> IngestionService {
            IngestionService(
                extractor: FileDocumentExtractor(), embedder: FakeEmbedder(identity: model), repository: repo, jobs: repo,
                chunker: Chunker(configuration: ChunkerConfiguration(targetTokens: 60, maxTokens: 100, overlapTokens: 12, minTailTokens: 20)),
                batchSize: 4, supportedType: FileDocumentExtractor.documentType(for:))
        }

        // The previous version indexed the document with the old model.
        let before = try open(root, text: Self.old, images: Self.old)
        let docId = try await service(before, Self.old).enqueue(fileURL: file)
        await service(before, Self.old).run()
        #expect(try await before.activeChunks(docId: docId).allSatisfy { $0.embeddingModel == Self.old.tag })
        try await before.close()

        // The updated app starts with the new model.
        let repo = try open(root, text: Self.new, images: Self.new)
        let updated = service(repo, Self.new)
        let newFilter = SearchFilter(embeddingModel: Self.new.tag)
        #expect(try await updated.reindexOutdated(for: Self.new) == 1)

        // Before the new vectors exist: keyword search finds the document, vector search does not return old vectors.
        let keywordBefore = try await repo.keywordSearch(terms: ["pressure gauge"], limit: 5, filter: newFilter)
        #expect(!keywordBefore.isEmpty, "keyword search must keep working during the re-index")
        let probe = try await FakeEmbedder(identity: Self.new).embed(["check valve 7"], kind: .query)[0]
        #expect(try await repo.vectorSearch(probe, limit: 5, filter: newFilter).isEmpty, "old vectors must not be returned")

        await updated.run()
        #expect(try await repo.job(docId: docId)?.state == .ready)
        #expect(try await repo.activeChunks(docId: docId).allSatisfy { $0.embeddingModel == Self.new.tag && $0.embedding.count == 256 })
        #expect(!(try await repo.vectorSearch(probe, limit: 5, filter: newFilter)).isEmpty, "new vectors must be searchable")
        #expect(!(try await repo.keywordSearch(terms: ["pressure gauge"], limit: 5, filter: newFilter)).isEmpty)
        #expect(try await updated.reindexOutdated(for: Self.new) == 0)
        try await repo.close()
    }
}
