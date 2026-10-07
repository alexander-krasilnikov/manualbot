import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

@Suite struct RankFusionTests {
    @Test func aPassageFoundByBothListsRanksFirst() {
        // "shared" is 2nd in one list and 3rd in the other; "only-v" is 1st in just one.
        let fused = RankFusion.fuse([["only-v", "shared", "v3"], ["k1", "k2", "shared"]], limit: 10)
        #expect(fused.first?.id == "shared")
        #expect(fused.first?.ranks == [1, 2])
    }

    @Test func duplicatesAppearOnce() {
        let fused = RankFusion.fuse([["a", "b", "a"], ["b", "a"]], limit: 10)
        #expect(fused.map(\.id).sorted() == ["a", "b"])
    }

    @Test func listsWithNoOverlapInterleaveByRank() {
        let fused = RankFusion.fuse([["v1", "v2"], ["k1", "k2"]], limit: 10)
        #expect(fused.map(\.id) == ["v1", "k1", "v2", "k2"])  // equal scores tie-break by best rank, then id
    }

    @Test func limitCutsTheList() {
        let fused = RankFusion.fuse([(0..<20).map { "v\($0)" }, (0..<20).map { "k\($0)" }], limit: 6)
        #expect(fused.count == 6)
    }

    @Test func emptyInputsGiveEmptyOutput() {
        #expect(RankFusion.fuse([], limit: 5).isEmpty)
        #expect(RankFusion.fuse([[], []], limit: 5).isEmpty)
    }

    @Test func orderingIsDeterministic() {
        let lists = [["a", "b", "c"], ["c", "b", "a"]]
        let runs = (0..<10).map { _ in RankFusion.fuse(lists, limit: 3).map(\.id) }
        #expect(Set(runs).count == 1)
    }
}

@Suite struct QueryTermsTests {
    @Test func dropsQuestionWordsButKeepsCodes() {
        #expect(QueryTerms.keywords(from: "What does E-042 mean?") == ["E-042", "mean"])
        #expect(QueryTerms.keywords(from: "how do I reset the X200 unit") == ["reset", "X200", "unit"])
    }

    @Test func trimsPunctuationAndDuplicates() {
        #expect(QueryTerms.keywords(from: "Filter, filter; FILTER!") == ["Filter"])
        #expect(QueryTerms.keywords(from: "  ") == [])
    }

    @Test func identifiesCodes() {
        let terms = QueryTerms.keywords(from: "part PN-7731 and M8x20 bolt in 2024")
        #expect(QueryTerms.codes(in: terms) == ["PN-7731", "M8x20", "2024"])
        #expect(QueryTerms.codes(in: ["reset", "button"]) == [])
    }

    @Test func codesMatchAsWholeTokens() {
        #expect(QueryTerms.contains("Error E-042 means overheating.", code: "e-042"))
        #expect(QueryTerms.contains("See (E-042).", code: "E-042"))
        #expect(!QueryTerms.contains("Error E-0421 means", code: "E-042"))
        #expect(!QueryTerms.contains("XE-042", code: "E-042"))
    }
}

/// A searcher that returns fixed results and records what it was asked.
private final class ScriptedSearch: ChunkSearching, @unchecked Sendable {
    var vectorHits: [ScoredChunk] = []
    var keywordHits: [ScoredChunk] = []
    var filters: [SearchFilter] = []
    var keywordTerms: [[String]] = []

    func vectorSearch(_ vector: [Float], limit: Int, filter: SearchFilter) async throws -> [ScoredChunk] {
        filters.append(filter)
        return Array(vectorHits.prefix(limit))
    }

    func keywordSearch(terms: [String], limit: Int, filter: SearchFilter) async throws -> [ScoredChunk] {
        keywordTerms.append(terms)
        return Array(keywordHits.prefix(limit))
    }
}

private func chunk(_ doc: String, _ ordinal: Int, _ text: String) -> Chunk {
    Chunk(docId: doc, generation: 1, ordinal: ordinal, page: ordinal + 1, text: text,
          embedding: [Float](repeating: 0, count: 32), embeddingModel: FakeEmbedder().identity.tag)
}

@Suite struct RetrieverTests {
    private func make(
        _ search: ScriptedSearch, config: RetrievalConfiguration = .standIn, tracer: any Tracer = NoTracer()
    ) async throws -> Retriever {
        let repo = InMemoryDocumentRepository()
        try await repo.upsert(DocumentRecord(id: "a", title: "Manual A", type: .pdf))
        try await repo.upsert(DocumentRecord(id: "b", title: "Manual B", type: .docx))
        return Retriever(embedder: FakeEmbedder(), search: search, repository: repo, configuration: config, tracer: tracer)
    }

    // MARK: Tracing

    @Test func fusionEventShowsWhereEachSearchFoundThePassage() async throws {
        let search = ScriptedSearch()
        let shared = chunk("a", 2, "shared passage")
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "v only"), score: 0.1), ScoredChunk(chunk: shared, score: 0.2)]
        search.keywordHits = [ScoredChunk(chunk: chunk("b", 0, "k only"), score: 1), ScoredChunk(chunk: shared, score: 2)]
        let tracer = RecordingTracer()
        _ = try await make(search, tracer: tracer).retrieve("passage")

        let fusion = try #require(tracer.kinds.compactMap { kind -> (String, Double, [FusionEntry])? in
            if case .fusion(let method, let k, let entries) = kind { return (method, k, entries) }
            return nil
        }.first)
        #expect(fusion.0 == "Reciprocal Rank Fusion")
        #expect(fusion.1 == 60)
        let entry = try #require(fusion.2.first { $0.chunkID == shared.id })
        #expect(entry.vectorPosition == 1 && entry.keywordPosition == 1)
        #expect(entry.distance == 0.2)
        #expect(entry.documentTitle == "Manual A")
        let keywordOnly = try #require(fusion.2.first { $0.chunkID == "b:1:0" })
        #expect(keywordOnly.vectorPosition == nil && keywordOnly.keywordPosition == 0 && keywordOnly.distance == nil)
        #expect(fusion.2.first?.chunkID == shared.id, "the entries keep the fused order")
    }

    @Test func aCodeFoundInATopPassageIsNamedInTheRelevanceEvent() async throws {
        let search = ScriptedSearch()
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "Something else entirely."), score: 0.95)]
        search.keywordHits = [ScoredChunk(chunk: chunk("b", 4, "Error E-042 means the motor overheated."), score: 1)]
        let tracer = RecordingTracer()
        _ = try await make(search, tracer: tracer).retrieve("what does E-042 mean")
        #expect(tracer.kinds.contains(.relevance(bestDistance: 0.95, threshold: 0.76, outcome: .passedOnIdentifier("E-042"))))
    }

    @Test func distanceAndFailureAreReportedWithTheThreshold() async throws {
        let near = ScriptedSearch()
        near.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "Hold the reset button."), score: 0.2)]
        let nearTracer = RecordingTracer()
        _ = try await make(near, tracer: nearTracer).retrieve("how do I reset it")
        #expect(nearTracer.kinds.contains(.relevance(bestDistance: 0.2, threshold: 0.76, outcome: .passedOnDistance)))

        let far = ScriptedSearch()
        far.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "unrelated"), score: 0.9)]
        let farTracer = RecordingTracer()
        _ = try await make(far, tracer: farTracer).retrieve("what is the meaning of life")
        #expect(farTracer.kinds.contains(.relevance(bestDistance: 0.9, threshold: 0.76, outcome: .failed)))
    }

    @Test func embeddingTheQuestionReportsDimensionsAndTime() async throws {
        let tracer = RecordingTracer()
        _ = try await make(ScriptedSearch(), tracer: tracer).retrieve("reset")
        let event = try #require(tracer.events.first { if case .queryEmbedded = $0.kind { true } else { false } })
        #expect(event.kind == .queryEmbedded(dimensions: FakeEmbedder().identity.dimensions))
        #expect(event.duration != nil)
    }

    @Test func aQuestionWithNoSearchableWordsSaysTheKeywordSearchWasSkipped() async throws {
        let tracer = RecordingTracer()
        _ = try await make(ScriptedSearch(), tracer: tracer).retrieve("what is it?")
        #expect(tracer.kinds.contains(.keywordSearchSkipped))

        let withWords = RecordingTracer()
        _ = try await make(ScriptedSearch(), tracer: withWords).retrieve("reset button")
        #expect(!withWords.kinds.contains(.keywordSearchSkipped))
    }

    @Test func aDisabledTracerChangesNothingAndRecordsNothing() async throws {
        let search = ScriptedSearch()
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "Hold the reset button."), score: 0.2)]
        let off = RecordingTracer(isEnabled: false)
        let traced = try await make(search, tracer: off).retrieve("how do I reset it")
        let plain = try await make(search).retrieve("how do I reset it")
        #expect(traced == plain)
        #expect(off.events.isEmpty)
    }

    @Test func closeVectorMatchIsRelevant() async throws {
        let search = ScriptedSearch()
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "Hold the reset button."), score: 0.2)]
        let result = try await make(search).retrieve("how do I reset it")
        #expect(result.relevant)
        #expect(result.bestDistance == 0.2)
        #expect(result.passages.first?.documentTitle == "Manual A")
        #expect(result.passages.first?.distance == 0.2)
    }

    @Test func distantMatchesAreNotRelevantButStillOfferedAsSuggestions() async throws {
        let search = ScriptedSearch()
        search.vectorHits = (0..<5).map { ScoredChunk(chunk: chunk("a", $0, "unrelated \($0)"), score: 0.9 + Double($0) / 100) }
        let result = try await make(search).retrieve("what is the meaning of life")
        #expect(!result.relevant)
        #expect(result.closest().count == 3)
        #expect(result.closest().map(\.chunk.ordinal) == [0, 1, 2])
    }

    @Test func aVerbatimCodeBypassesTheDistanceThreshold() async throws {
        let search = ScriptedSearch()
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "Something else entirely."), score: 0.95)]
        search.keywordHits = [ScoredChunk(chunk: chunk("b", 4, "Error E-042 means the motor overheated."), score: 1)]
        let result = try await make(search).retrieve("what does E-042 mean")
        #expect(result.relevant, "an exact code match should count")
        #expect(result.bestDistance == 0.95)
        #expect(result.passages.contains { $0.chunk.text.contains("E-042") })
    }

    @Test func aCodeThatIsNotInTheTopPassagesDoesNotBypass() async throws {
        let search = ScriptedSearch()
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "Nothing about that."), score: 0.95)]
        search.keywordHits = [ScoredChunk(chunk: chunk("b", 1, "Error E-0421 is different."), score: 1)]
        let result = try await make(search).retrieve("what does E-042 mean")
        #expect(!result.relevant)
    }

    @Test func keywordMatchesAloneDoNotMakeWordyQuestionsRelevant() async throws {
        let search = ScriptedSearch()
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "Far away."), score: 0.9)]
        search.keywordHits = [ScoredChunk(chunk: chunk("a", 1, "The word button appears here."), score: 1)]
        let result = try await make(search).retrieve("button")
        #expect(!result.relevant)  // no code, and the semantic match is too far
    }

    @Test func emptyLibraryIsNotRelevant() async throws {
        let result = try await make(ScriptedSearch()).retrieve("anything at all")
        #expect(!result.relevant)
        #expect(result.passages.isEmpty)
        #expect(result.bestDistance == nil)
    }

    @Test func thresholdIsInclusiveAndConfigurable() async throws {
        let search = ScriptedSearch()
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "x"), score: 0.4)]
        #expect(try await make(search, config: .init(maxDistance: 0.4)).retrieve("q").relevant)
        #expect(!(try await make(search, config: .init(maxDistance: 0.39)).retrieve("q").relevant))
    }

    @Test func passageFoundByBothSearchesRanksFirstAndAppearsOnce() async throws {
        let search = ScriptedSearch()
        let shared = chunk("a", 2, "shared passage")
        search.vectorHits = [ScoredChunk(chunk: chunk("a", 0, "v only"), score: 0.1), ScoredChunk(chunk: shared, score: 0.2)]
        search.keywordHits = [ScoredChunk(chunk: chunk("b", 0, "k only"), score: 1), ScoredChunk(chunk: shared, score: 2)]
        let result = try await make(search).retrieve("passage")
        #expect(result.passages.first?.chunk == shared)
        #expect(result.passages.filter { $0.chunk == shared }.count == 1)
        #expect(result.passages.first?.distance == 0.2)
        #expect(result.passages.first?.keywordRank == 1)
    }

    @Test func scopeAndEmbeddingModelAreForwardedToSearch() async throws {
        let search = ScriptedSearch()
        _ = try await make(search).retrieve("reset", scope: ["a", "b"])
        _ = try await make(search).retrieve("reset")
        #expect(search.filters.map(\.documentIDs) == [["a", "b"], nil])
        #expect(search.filters.allSatisfy { $0.embeddingModel == FakeEmbedder().identity.tag })
    }

    @Test func questionsWithNoSearchableWordsSkipKeywordSearch() async throws {
        let search = ScriptedSearch()
        _ = try await make(search).retrieve("what is it?")
        #expect(search.keywordTerms.isEmpty)
    }

    @Test func resultLimitCapsThePassages() async throws {
        let search = ScriptedSearch()
        search.vectorHits = (0..<20).map { ScoredChunk(chunk: chunk("a", $0, "p\($0)"), score: 0.1) }
        let result = try await make(search, config: .init(resultLimit: 4)).retrieve("q")
        #expect(result.passages.count == 4)
    }
}
