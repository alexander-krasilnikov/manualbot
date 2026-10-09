import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// The read-only calls behind the X-ray panel and the database explorer.
@Suite struct CouchbaseInspectorTests {
    private func seeded(chunks: Int = 3) async throws -> RepoFixture {
        let f = try RepoFixture()
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Manual", type: .pdf, activeGeneration: 1))
        try await f.repo.writeChunks((0..<chunks).map { RepoFixture.chunk("d1", 1, $0) })
        return f
    }

    private func object(_ json: String?) throws -> [String: Any] {
        let data = Data(try #require(json).utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 2.2 collections and indexes

    @Test func collectionsAreGroupedAndCounted() async throws {
        let f = try await seeded(); defer { Task { await f.cleanUp() } }
        let summaries = try await f.repo.collectionSummaries()
        #expect(summaries.map(\.name) == ["documents", "chunks", "images", "chats", "messages", "ingestJobs", "localMeta"])
        #expect(summaries.filter(\.localOnly).map(\.name) == ["chats", "messages", "ingestJobs", "localMeta"])
        #expect(summaries.filter { !$0.localOnly }.map(\.name) == ["documents", "chunks", "images"])
        #expect(summaries.first { $0.name == "documents" }?.count == 1)
        #expect(summaries.first { $0.name == "chunks" }?.count == 3)
        #expect(summaries.first { $0.name == "localMeta" }?.count == 1)
    }

    @Test func theVectorIndexIsDescribedWithTheDimensionsItWasCreatedWith() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let indexes = try await f.repo.indexes()
        #expect(indexes.map(\.name).sorted() == ["chunks_doc_gen", "chunks_fts", "chunks_vec", "images_doc_gen", "images_vec", "messages_chat"])
        let vector = try #require(indexes.first { $0.name == "chunks_vec" })
        #expect(vector.collection == "chunks")
        #expect(vector.settings == .init(
            kind: .vector, expression: "embedding", dimensions: RepoFixture.identity.dimensions, metric: "cosine",
            centroids: 64, encoding: "SQ8"))
        #expect(indexes.first { $0.name == "chunks_fts" }?.settings?.kind == .fullText)
        #expect(indexes.first { $0.name == "chunks_doc_gen" }?.settings?.expression == "docId, generation")
    }

    // MARK: 2.3 paging

    @Test func twoPagesOfFiftyCoverOneHundredTwentyIDsWithoutRepeatsOrGaps() async throws {
        let f = try await seeded(chunks: 120); defer { Task { await f.cleanUp() } }
        var all: [String] = []
        var after: String?
        for _ in 0..<3 {
            let page = try await f.repo.documentIDs(collection: "chunks", after: after, containing: nil, limit: 50)
            all += page
            after = page.last
        }
        #expect(all.count == 120)
        #expect(Set(all).count == 120)
        #expect(all == all.sorted())
        #expect(try await f.repo.documentIDs(collection: "chunks", after: all.last, containing: nil, limit: 50).isEmpty)
    }

    @Test func theFilterNarrowsTheIDs() async throws {
        let f = try await seeded(chunks: 12); defer { Task { await f.cleanUp() } }
        let all = try await f.repo.documentIDs(collection: "chunks", after: nil, containing: nil, limit: 50)
        let target = try #require(all.first)
        let some = try await f.repo.documentIDs(collection: "chunks", after: nil, containing: target, limit: 50)
        #expect(some.contains(target))
        #expect(some.count < all.count)
        #expect(try await f.repo.documentIDs(collection: "chunks", after: nil, containing: "no-such-text", limit: 50).isEmpty)
    }

    @Test func anUnknownCollectionThrows() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        await #expect(throws: CouchbaseStoreError.unknownCollection("chunks; DROP")) {
            try await f.repo.documentIDs(collection: "chunks; DROP", after: nil, containing: nil, limit: 50)
        }
    }

    // MARK: 2.4 document, blob, children

    @Test func aFullEmbeddingHasTheEmbeddersLength() async throws {
        let f = try await seeded(); defer { Task { await f.cleanUp() } }
        let id = try #require(try await f.repo.documentIDs(collection: "chunks", after: nil, containing: nil, limit: 1).first)
        let shortened = try object(try await f.repo.storedDocument(collection: "chunks", id: id, fullVectors: false))
        let full = try object(try await f.repo.storedDocument(collection: "chunks", id: id, fullVectors: true))
        #expect((shortened["embedding"] as? String)?.contains("\(RepoFixture.identity.dimensions) values") == true)
        #expect((full["embedding"] as? [Any])?.count == RepoFixture.identity.dimensions)
        #expect(try await f.repo.storedDocument(collection: "chunks", id: "nope", fullVectors: false) == nil)
    }

    @Test func anImageRecordsBlobIsReturned() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let write = CouchbaseImageTests.image("d1", 1, 0)
        try await f.repo.writeImages([write])
        let content = try #require(try await f.repo.blob(collection: "images", id: write.record.id, key: "image"))
        #expect(content.contentType == "image/jpeg")
        #expect(content.data == write.displayCopy)
        #expect(try await f.repo.blob(collection: "images", id: write.record.id, key: "nothing") == nil)
        let summary = try object(try await f.repo.storedDocument(collection: "images", id: write.record.id, fullVectors: false))
        #expect((summary["image"] as? [String: Any])?["@type"] as? String == "blob")
    }

    @Test func aDocumentListsTheChunksAndImagesOfItsActiveGeneration() async throws {
        let f = try await seeded(chunks: 3); defer { Task { await f.cleanUp() } }
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 2, 0), RepoFixture.chunk("d1", 2, 1)])
        try await f.repo.writeImages([CouchbaseImageTests.image("d1", 1, 0), CouchbaseImageTests.image("d1", 1, 1), CouchbaseImageTests.image("d1", 2, 0)])
        let children = try await f.repo.children(documentID: "d1")
        #expect(children.chunks.count == 3)
        #expect(children.images.count == 2)
        // Still being imported: no active generation yet, so every generation written so far is listed.
        try await f.repo.upsert(DocumentRecord(id: "d2", title: "New", type: .pdf))
        try await f.repo.writeChunks([RepoFixture.chunk("d2", 1, 0)])
        #expect(try await f.repo.children(documentID: "d2").chunks.count == 1)
    }

    // MARK: 2.5 query

    @Test func moreThanTheLimitIsTruncated() async throws {
        let f = try await seeded(chunks: 250); defer { Task { await f.cleanUp() } }
        let result = try await f.repo.query(sql: "SELECT meta().id AS id FROM manualbot.chunks ORDER BY meta().id", limit: 200)
        #expect(result.rows.count == 200)
        #expect(result.truncated)
        #expect(result.columns == ["id"])
        #expect(result.duration > .zero)
        let exact = try await f.repo.query(sql: "SELECT meta().id AS id FROM manualbot.chunks", limit: 250)
        #expect(exact.rows.count == 250)
        #expect(!exact.truncated)
    }

    @Test func vectorsInResultsAreShortened() async throws {
        let f = try await seeded(); defer { Task { await f.cleanUp() } }
        let result = try await f.repo.query(sql: "SELECT embedding FROM manualbot.chunks LIMIT 1", limit: 200)
        #expect(result.rows.count == 1)
        #expect(result.rows[0].contains("\(RepoFixture.identity.dimensions) values"))
    }

    @Test func invalidSQLThrowsTheDatabaseError() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        await #expect(throws: (any Error).self) { try await f.repo.query(sql: "SELEKT nothing", limit: 200) }
    }

    // MARK: 2.6 read-only

    @Test func inspectingLeavesNoTraceAndChangesNothing() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Manual", type: .pdf, activeGeneration: 1))
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0)])
        try await f.repo.writeImages([CouchbaseImageTests.image("d1", 1, 0)])
        let before = try await f.repo.collectionSummaries()
        let recorded = tracer.events.count

        let id = try #require(try await f.repo.documentIDs(collection: "chunks", after: nil, containing: nil, limit: 50).first)
        _ = try await f.repo.storedDocument(collection: "chunks", id: id, fullVectors: true)
        _ = try await f.repo.blob(collection: "images", id: "d1:1:img:0", key: "image")
        _ = try await f.repo.children(documentID: "d1")
        _ = try await f.repo.indexes()
        _ = try await f.repo.query(sql: "SELECT meta().id FROM manualbot.chunks", limit: 200)
        _ = try await f.repo.plan(sql: "SELECT meta().id FROM manualbot.chunks WHERE docId = $docId")

        #expect(tracer.events.count == recorded)
        #expect(try await f.repo.collectionSummaries() == before)
    }
}
