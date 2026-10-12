/// Which chunks a search may return.
public struct SearchFilter: Sendable, Equatable {
    /// Only chunks from these documents; `nil` searches the whole library.
    public var documentIDs: Set<String>?
    /// Vector search only returns chunks embedded with this model tag.
    public var embeddingModel: String

    public init(documentIDs: Set<String>? = nil, embeddingModel: String) {
        self.documentIDs = documentIDs
        self.embeddingModel = embeddingModel
    }
}

public struct ScoredChunk: Sendable, Equatable {
    public var chunk: Chunk
    /// Vector search: cosine distance (0 = identical). Keyword search: the engine's rank value.
    public var score: Double

    public init(chunk: Chunk, score: Double) {
        self.chunk = chunk
        self.score = score
    }
}

/// Searches the chunks of every ready document's active generation. Half-written or superseded
/// generations, and deleted documents, are never returned.
public protocol ChunkSearching: Sendable {
    /// Nearest chunks by cosine distance, best first.
    func vectorSearch(_ vector: [Float], limit: Int, filter: SearchFilter) async throws -> [ScoredChunk]
    /// Chunks matching any of `terms`, best first. Each term is matched as a whole phrase.
    func keywordSearch(terms: [String], limit: Int, filter: SearchFilter) async throws -> [ScoredChunk]
}
