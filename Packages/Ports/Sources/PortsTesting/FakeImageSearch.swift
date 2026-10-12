import Ports
import Synchronization

/// An image searcher that returns fixed results and records what it was asked.
public final class FakeImageSearch: ImageSearching {
    private struct State {
        var hits: [ScoredImage] = []
        var filters: [SearchFilter] = []
        var vectors: [[Float]] = []
    }
    private let state = Mutex(State())

    public init(hits: [ScoredImage] = []) {
        state.withLock { $0.hits = hits }
    }

    public var hits: [ScoredImage] {
        get { state.withLock { $0.hits } }
        set { state.withLock { $0.hits = newValue } }
    }
    public var filters: [SearchFilter] { state.withLock { $0.filters } }
    public var vectors: [[Float]] { state.withLock { $0.vectors } }

    public func imageSearch(_ vector: [Float], limit: Int, filter: SearchFilter) async throws -> [ScoredImage] {
        state.withLock { s in
            s.filters.append(filter)
            s.vectors.append(vector)
            return Array(s.hits.prefix(limit))
        }
    }
}
