import Foundation
import Ports

public struct RetrievalConfiguration: Sendable, Equatable {
    /// Candidates taken from each search before fusion.
    public var candidatesPerSearch: Int
    /// Passages returned after fusion.
    public var resultLimit: Int
    /// A result is relevant when its best cosine distance is at most this. Tuned on the evaluation set (task 6.3) with real EmbeddingGemma output: answerable questions reach at most 0.66, off-topic ones start at 0.87, and every threshold from 0.68 to 0.86 separates them perfectly; 0.76 sits in the middle of that range.
    public var maxDistance: Double
    /// Passages offered as suggestions when nothing is relevant.
    public var suggestionCount: Int

    public init(candidatesPerSearch: Int = 20, resultLimit: Int = 6, maxDistance: Double = 0.76, suggestionCount: Int = 3) {
        self.candidatesPerSearch = candidatesPerSearch
        self.resultLimit = resultLimit
        self.maxDistance = maxDistance
        self.suggestionCount = suggestionCount
    }
}

public struct RetrievedPassage: Sendable, Equatable, Identifiable {
    public var chunk: Chunk
    public var documentTitle: String
    /// Cosine distance from the query, when the vector search found this passage.
    public var distance: Double?
    /// Zero-based position in the keyword results, when the keyword search found it.
    public var keywordRank: Int?
    public var fusedScore: Double

    public var id: String { chunk.id }
}

public struct RetrievalResult: Sendable, Equatable {
    /// Fused passages, best first. Only use them to answer when `relevant` is true.
    public var passages: [RetrievedPassage]
    public var relevant: Bool
    /// Best cosine distance seen, or `nil` if the library has nothing comparable.
    public var bestDistance: Double?

    /// The nearest passages, offered to the user when nothing was relevant enough to answer from.
    public func closest(_ count: Int = 3) -> [RetrievedPassage] { Array(passages.prefix(count)) }
}

/// Finds the passages that best answer a question: semantic (vector) and exact (keyword) search,
/// merged, then a relevance check.
public struct Retriever: Sendable {
    private let embedder: any Embedder
    private let search: any ChunkSearching
    private let repository: any DocumentRepository
    private let tracer: any Tracer
    public let configuration: RetrievalConfiguration

    public init(
        embedder: any Embedder, search: any ChunkSearching, repository: any DocumentRepository,
        configuration: RetrievalConfiguration = .init(), tracer: any Tracer = NoTracer()
    ) {
        self.embedder = embedder
        self.search = search
        self.repository = repository
        self.configuration = configuration
        self.tracer = tracer
    }

    public func retrieve(_ question: String, scope: Set<String>? = nil) async throws -> RetrievalResult {
        let filter = SearchFilter(documentIDs: scope, embeddingModel: embedder.identity.tag)
        let vector = try await tracer.measure(
            { try await embedder.embed([question], kind: .query)[0] }, event: { .queryEmbedded(dimensions: $0.count) })
        let terms = QueryTerms.keywords(from: question)
        if terms.isEmpty { tracer.emit(.keywordSearchSkipped) }

        async let semantic = search.vectorSearch(vector, limit: configuration.candidatesPerSearch, filter: filter)
        async let keyword = terms.isEmpty ? [] : search.keywordSearch(terms: terms, limit: configuration.candidatesPerSearch, filter: filter)
        let (vectorHits, keywordHits) = try await (semantic, keyword)

        let byID = Dictionary((vectorHits + keywordHits).map { ($0.chunk.id, $0.chunk) }, uniquingKeysWith: { a, _ in a })
        let fused = RankFusion.fuse(
            [vectorHits.map(\.chunk.id), keywordHits.map(\.chunk.id)], limit: configuration.resultLimit)

        var titles: [String: String] = [:]
        for docId in Set(fused.compactMap { byID[$0.id]?.docId }) {
            titles[docId] = try await repository.document(id: docId)?.title
        }
        let distances = Dictionary(vectorHits.map { ($0.chunk.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let passages = fused.compactMap { item -> RetrievedPassage? in
            guard let chunk = byID[item.id] else { return nil }
            return RetrievedPassage(
                chunk: chunk, documentTitle: titles[chunk.docId] ?? "Untitled", distance: distances[item.id],
                keywordRank: item.ranks[1], fusedScore: item.score)
        }

        if tracer.isEnabled {
            let ranks = Dictionary(uniqueKeysWithValues: fused.map { ($0.id, $0.ranks) })
            tracer.emit(.fusion(method: "Reciprocal Rank Fusion", k: RankFusion.defaultK, entries: passages.map { passage in
                FusionEntry(
                    chunkID: passage.chunk.id, documentTitle: passage.documentTitle,
                    vectorPosition: ranks[passage.chunk.id]?[0], keywordPosition: passage.keywordRank,
                    distance: passage.distance, score: passage.fusedScore)
            }))
        }

        let best = vectorHits.map(\.score).min()
        let outcome = relevance(best: best, passages: passages, terms: terms)
        tracer.emit(.relevance(bestDistance: best, threshold: configuration.maxDistance, outcome: outcome))
        return RetrievalResult(passages: passages, relevant: outcome != .failed, bestDistance: best)
    }

    /// Relevant when the closest passage is near enough in meaning, or when an identifier from the
    /// question (an error code, a part number) appears verbatim in one of the top passages.
    func relevance(best: Double?, passages: [RetrievedPassage], terms: [String]) -> RelevanceOutcome {
        if let best, best <= configuration.maxDistance { return .passedOnDistance }
        let codes = QueryTerms.codes(in: terms)
        guard !codes.isEmpty else { return .failed }
        for passage in passages.prefix(configuration.suggestionCount) {
            if let code = codes.first(where: { QueryTerms.contains(passage.chunk.text, code: $0) }) {
                return .passedOnIdentifier(code)
            }
        }
        return .failed
    }
}
