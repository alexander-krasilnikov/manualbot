import Ports
import Synchronization

/// A searcher that returns fixed results and records what it was asked.
public final class FakeChunkSearch: ChunkSearching {
    private struct State {
        var vectorHits: [ScoredChunk] = []
        var keywordHits: [ScoredChunk] = []
        var filters: [SearchFilter] = []
        var keywordTerms: [[String]] = []
    }
    private let state = Mutex(State())

    public init(vectorHits: [ScoredChunk] = [], keywordHits: [ScoredChunk] = []) {
        state.withLock { $0.vectorHits = vectorHits; $0.keywordHits = keywordHits }
    }

    public var vectorHits: [ScoredChunk] {
        get { state.withLock { $0.vectorHits } }
        set { state.withLock { $0.vectorHits = newValue } }
    }
    public var keywordHits: [ScoredChunk] {
        get { state.withLock { $0.keywordHits } }
        set { state.withLock { $0.keywordHits = newValue } }
    }
    public var filters: [SearchFilter] { state.withLock { $0.filters } }
    public var keywordTerms: [[String]] { state.withLock { $0.keywordTerms } }

    public func vectorSearch(_ vector: [Float], limit: Int, filter: SearchFilter) async throws -> [ScoredChunk] {
        state.withLock { s in s.filters.append(filter); return Array(s.vectorHits.prefix(limit)) }
    }

    public func keywordSearch(terms: [String], limit: Int, filter: SearchFilter) async throws -> [ScoredChunk] {
        state.withLock { s in s.keywordTerms.append(terms); return Array(s.keywordHits.prefix(limit)) }
    }
}
