import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// A document received from another device is searchable only once this device holds every chunk and image of its active set.
@Suite struct ArrivalTests {
    private func filter() -> SearchFilter {
        SearchFilter(documentIDs: nil, embeddingModel: RepoFixture.identity.tag)
    }

    private func imageFilter() -> SearchFilter {
        SearchFilter(documentIDs: nil, embeddingModel: RepoFixture.imageIdentity.tag)
    }

    private func chunks(_ doc: String, _ range: Range<Int>, generation: Int = 1) -> [Chunk] {
        range.map { RepoFixture.chunk(doc, generation, $0, text: "unique alpha \($0)") }
    }

    /// The record as sync delivers it: an active generation with its counts, before all of its chunks are here.
    private func received(_ f: RepoFixture, chunks: Int, images: Int, generation: Int = 1) async throws {
        try await f.repo.upsert(DocumentRecord(
            id: "d1", title: "Received", type: .pdf, activeGeneration: generation, chunkCount: chunks, activeImageCount: images))
    }

    @Test func aPartlyReceivedDocumentIsNotSearchable() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await received(f, chunks: 5, images: 1)
        try await f.repo.writeChunks(chunks("d1", 0..<3))

        #expect(try await f.repo.vectorSearch(RepoFixture.vector(0), limit: 5, filter: filter()).isEmpty)
        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 5, filter: filter()).isEmpty)
        #expect(try await f.repo.arrivingDocumentIDs() == ["d1"])
    }

    @Test func itBecomesSearchableWhenTheLastChunkAndImageArrive() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await received(f, chunks: 5, images: 1)
        try await f.repo.writeChunks(chunks("d1", 0..<5))
        // All chunks, but the image is still on the way.
        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 5, filter: filter()).isEmpty)

        try await f.repo.writeImages([CouchbaseImageTests.image("d1", 1, 0)])
        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 10, filter: filter()).count == 5)
        #expect(try await f.repo.vectorSearch(RepoFixture.vector(0), limit: 5, filter: filter()).count == 5)
        #expect(try await f.repo.imageSearch(RepoFixture.vector(0), limit: 5, filter: imageFilter()).count == 1)
        #expect(try await f.repo.arrivingDocumentIDs().isEmpty)
    }

    @Test func aPartlyReceivedDocumentHidesItsImagesToo() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await received(f, chunks: 2, images: 1)
        try await f.repo.writeImages([CouchbaseImageTests.image("d1", 1, 0)])
        try await f.repo.writeChunks(chunks("d1", 0..<1))

        #expect(try await f.repo.imageSearch(RepoFixture.vector(0), limit: 5, filter: imageFilter()).isEmpty)
    }

    @Test func aRecordWithoutCountsIsSearchableAsBefore() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Old", type: .pdf, activeGeneration: 1))
        try await f.repo.writeChunks(chunks("d1", 0..<2))

        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 5, filter: filter()).count == 2)
        #expect(try await f.repo.arrivingDocumentIDs().isEmpty)
    }

    @Test func aLocalImportIsNeverArriving() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Mine", type: .pdf))
        try await f.repo.writeChunks(chunks("d1", 0..<4))
        try await f.repo.activate(generation: 1, for: "d1")

        #expect(try await f.repo.arrivingDocumentIDs().isEmpty)
        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 10, filter: filter()).count == 4)
    }

    @Test func aReceivedReindexWaitsForItsNewSetAndHidesTheDocumentUntilThen() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Manual", type: .pdf))
        try await f.repo.writeChunks(chunks("d1", 0..<3))
        try await f.repo.activate(generation: 1, for: "d1")

        // Another device re-indexed it: the record now names generation 2 and 4 chunks, 1 of which has arrived.
        try await received(f, chunks: 4, images: 0, generation: 2)
        try await f.repo.writeChunks(chunks("d1", 0..<1, generation: 2))
        #expect(try await f.repo.arrivingDocumentIDs() == ["d1"])
        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 10, filter: filter()).isEmpty)

        try await f.repo.writeChunks(chunks("d1", 1..<4, generation: 2))
        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 10, filter: filter()).count == 4)
    }

    // MARK: Refresh

    @Test func refreshReportsADocumentOnceWhenItBecomesComplete() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await received(f, chunks: 3, images: 0)
        try await f.repo.writeChunks(chunks("d1", 0..<2))
        #expect(try await f.repo.refreshArrivals(of: ["d1"]).isEmpty)

        try await f.repo.writeChunks(chunks("d1", 2..<3))
        #expect(try await f.repo.refreshArrivals(of: ["d1"]) == ["d1"])
        #expect(try await f.repo.refreshArrivals(of: ["d1"]).isEmpty, "reported once")
    }

    @Test func refreshOfAllDocumentsFindsEveryOneThatCompleted() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        for id in ["a", "b", "c"] {
            try await f.repo.upsert(DocumentRecord(id: id, title: id, type: .pdf, activeGeneration: 1, chunkCount: 2, activeImageCount: 0))
        }
        try await f.repo.writeChunks(chunks("a", 0..<2) + chunks("b", 0..<1))
        #expect(try await f.repo.refreshArrivals(of: nil) == ["a"])

        try await f.repo.writeChunks(chunks("b", 1..<2))
        #expect(try await f.repo.refreshArrivals(of: nil) == ["b"])
    }

    @Test func refreshOnlyLooksAtTheDocumentsItIsGiven() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        for id in ["a", "b"] {
            try await f.repo.upsert(DocumentRecord(id: id, title: id, type: .pdf, activeGeneration: 1, chunkCount: 1, activeImageCount: 0))
            try await f.repo.writeChunks(chunks(id, 0..<1))
        }
        #expect(try await f.repo.refreshArrivals(of: ["a"]) == ["a"])
    }

    @Test func aDeletedDocumentLeavesNoStaleState() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await received(f, chunks: 2, images: 0)
        try await f.repo.writeChunks(chunks("d1", 0..<2))
        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 5, filter: filter()).count == 2)

        try await f.repo.deleteDocument(id: "d1")
        try await received(f, chunks: 2, images: 0)       // the same ID comes back with its chunks still missing
        #expect(try await f.repo.keywordSearch(terms: ["alpha"], limit: 5, filter: filter()).isEmpty)
        #expect(try await f.repo.arrivingDocumentIDs() == ["d1"])
    }

    // MARK: Re-indexing sees only whole sets

    @Test func anArrivingDocumentIsNotReportedAsOutdated() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await received(f, chunks: 3, images: 0)
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0, text: "other model").withModel("old-model@0/768")])

        let stale = try await f.repo.documentIDs(notEmbeddedBy: RepoFixture.identity.tag, imageModel: RepoFixture.imageIdentity.tag)
        #expect(stale.isEmpty)
    }
}

private extension Chunk {
    func withModel(_ model: String) -> Chunk {
        var copy = self
        copy.embeddingModel = model
        return copy
    }
}
