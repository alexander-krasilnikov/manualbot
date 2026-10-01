import Foundation
import Ports
import Testing
@testable import Adapters

@Suite struct ChunkSearchTests {
    private static let identity = RepoFixture.identity

    /// A unit vector that is 1 at `hot` and 0 elsewhere, so distances between chunks are predictable.
    private func vec(_ hot: Int) -> [Float] { RepoFixture.vector(hot) }

    private func chunk(_ doc: String, gen: Int = 1, _ ordinal: Int, hot: Int, text: String, model: String? = nil) -> Chunk {
        Chunk(docId: doc, generation: gen, ordinal: ordinal, page: ordinal + 1, text: text, embedding: vec(hot),
              embeddingModel: model ?? Self.identity.tag)
    }

    /// Two ready documents (A, B), one still ingesting (C), and A also has a half-written newer generation.
    private func seed(_ f: RepoFixture, filler: Int = 120) async throws {
        for (id, gen) in [("A", 1), ("B", 1)] {
            try await f.repo.upsert(DocumentRecord(id: id, title: "Doc \(id)", type: .pdf, activeGeneration: nil))
            var chunks = (0..<filler).map { chunk(id, $0, hot: id == "A" ? $0 : 200 + $0, text: "filler passage \($0) of \(id)") }
            if id == "A" { chunks[7].text = "To reset the unit hold the button for ten seconds."; chunks[9].text = "Replace the filter yearly." }
            if id == "B" { chunks[3].text = "Error E-042 means the motor overheated."; chunks[4].text = "Error E-0421 is unrelated." }
            try await f.repo.writeChunks(chunks)
            try await f.repo.activate(generation: gen, for: id)
        }
        // C: chunks written, never activated.
        try await f.repo.upsert(DocumentRecord(id: "C", title: "Doc C", type: .pdf))
        try await f.repo.writeChunks([chunk("C", 0, hot: 7, text: "reset button secret draft E-042")])
        // A: newer generation partly written but not active.
        try await f.repo.writeChunks([chunk("A", gen: 2, 0, hot: 7, text: "reset button from the future generation")])
        // A chunk embedded by another model version.
        try await f.repo.writeChunks([chunk("B", 500, hot: 7, text: "reset button other model", model: "old-model@0/768")])
    }

    private func filter(_ scope: Set<String>? = nil) -> SearchFilter {
        SearchFilter(documentIDs: scope, embeddingModel: Self.identity.tag)
    }

    // MARK: 5.1 vector

    @Test func nearestPassageComesFirstWithZeroDistance() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        let hits = try await f.repo.vectorSearch(vec(7), limit: 5, filter: filter())
        #expect(hits.count == 5)
        #expect(hits[0].chunk.id == "A:1:7")
        #expect(hits[0].score < 0.001)
        #expect(hits.map(\.score) == hits.map(\.score).sorted())
    }

    @Test func draftSupersededAndMismatchedModelPassagesAreExcluded() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        // Several chunks share hot index 7 (A:1:7, C, A gen2, mismatched B). Only A:1:7 may come back.
        let hits = try await f.repo.vectorSearch(vec(7), limit: 400, filter: filter())
        let ids = Set(hits.map(\.chunk.id))
        #expect(ids.contains("A:1:7"))
        #expect(!ids.contains("C:1:0"), "document without an active generation")
        #expect(!ids.contains("A:2:0"), "generation that is not active")
        #expect(!ids.contains("B:1:500"), "chunk from another embedding model")
        #expect(hits.allSatisfy { $0.chunk.embeddingModel == Self.identity.tag })
    }

    @Test func scopeRestrictsToPinnedDocumentsAndStillFillsTheLimit() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        let onlyB = try await f.repo.vectorSearch(vec(7), limit: 10, filter: filter(["B"]))
        #expect(onlyB.count == 10, "a filtered query should still return a full page, got \(onlyB.count)")
        #expect(onlyB.allSatisfy { $0.chunk.docId == "B" })

        let both = try await f.repo.vectorSearch(vec(7), limit: 400, filter: filter(["A", "B"]))
        #expect(Set(both.map(\.chunk.docId)) == ["A", "B"])
    }

    @Test func scopeToADocumentThatIsNotReadyReturnsNothing() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        #expect(try await f.repo.vectorSearch(vec(7), limit: 5, filter: filter(["C"])).isEmpty)
        #expect(try await f.repo.vectorSearch(vec(7), limit: 5, filter: filter(["does-not-exist"])).isEmpty)
    }

    @Test func emptyLibraryReturnsNothing() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        #expect(try await f.repo.vectorSearch(vec(1), limit: 5, filter: filter()).isEmpty)
        #expect(try await f.repo.keywordSearch(terms: ["x"], limit: 5, filter: filter()).isEmpty)
    }

    @Test func deletedDocumentsDisappearFromSearch() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        try await f.repo.deleteDocument(id: "A")
        let hits = try await f.repo.vectorSearch(vec(7), limit: 400, filter: filter())
        #expect(hits.allSatisfy { $0.chunk.docId != "A" })
        // Keyword search ignores embedding models (the text is valid either way), so B's "other model"
        // passage can still match, but nothing from the deleted document A may.
        let keyword = try await f.repo.keywordSearch(terms: ["reset"], limit: 10, filter: filter())
        #expect(keyword.map(\.chunk.id) == ["B:1:500"], "got \(keyword.map(\.chunk.id))")
    }

    // MARK: 5.2 keyword

    @Test func anExactErrorCodeIsFound() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        let hits = try await f.repo.keywordSearch(terms: ["E-042"], limit: 5, filter: filter())
        #expect(hits.first?.chunk.id == "B:1:3")
        #expect(hits.first?.chunk.text.contains("E-042") == true)
        // The unrelated E-0421 passage must not be what ranks first.
        #expect(hits.map(\.chunk.id).first != "B:1:4")
    }

    @Test func draftAndInactiveGenerationsAreExcludedFromKeywordSearch() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        let hits = try await f.repo.keywordSearch(terms: ["reset", "button"], limit: 20, filter: filter())
        let ids = Set(hits.map(\.chunk.id))
        #expect(ids.contains("A:1:7"))
        #expect(!ids.contains("C:1:0"))
        #expect(!ids.contains("A:2:0"))
    }

    @Test func multipleTermsMatchAnyAndRankMoreMatchesFirst() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        let hits = try await f.repo.keywordSearch(terms: ["reset", "button", "filter"], limit: 10, filter: filter())
        let ids = hits.map(\.chunk.id)
        #expect(ids.contains("A:1:7") && ids.contains("A:1:9"))
        #expect(ids.first == "A:1:7", "two matching terms should outrank one: \(ids)")
    }

    @Test func keywordScopeIsHonored() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        #expect(try await f.repo.keywordSearch(terms: ["E-042"], limit: 5, filter: filter(["A"])).isEmpty)
        #expect(try await f.repo.keywordSearch(terms: ["E-042"], limit: 5, filter: filter(["B"])).count >= 1)
    }

    @Test func punctuationInTermsIsNeverQuerySyntax() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        for terms in [["what's"], ["C++"], ["a\"b"], ["NOT"], ["x AND y"], ["(reset)"], ["*"], ["E-042", "M8x20"], ["   "]] {
            _ = try await f.repo.keywordSearch(terms: terms, limit: 5, filter: filter())  // must not throw
        }
        #expect(try await f.repo.keywordSearch(terms: [], limit: 5, filter: filter()).isEmpty)
    }

    @Test func matchExpressionQuotesEachTerm() {
        #expect(CouchbaseDocumentRepository.matchExpression(for: ["E-042", "reset"]) == "\"E-042\" OR \"reset\"")
        #expect(CouchbaseDocumentRepository.matchExpression(for: ["a\"b"]) == "\"a b\"")
        #expect(CouchbaseDocumentRepository.matchExpression(for: ["  ", ""]) == "")
    }
}
