public enum EmbeddingKind: Sendable {
    /// Text to be stored and searched. `title` is the document title, used by the model's chunk template.
    case chunk(title: String)
    /// A user question searching for chunks.
    case query
}

public protocol Embedder: Sendable {
    var identity: EmbeddingModelIdentity { get }

    /// Returns one L2-normalized vector of `identity.dimensions` floats per input text, in order.
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]]
}
