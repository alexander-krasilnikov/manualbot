public enum EmbeddingKind: Sendable {
    /// Text to be stored and searched. `title` is the document title, used by the model's passage template.
    case passage(title: String)
    /// A user question searching for passages.
    case query
}

public protocol Embedder: Sendable {
    var identity: EmbeddingModelIdentity { get }

    /// Returns one L2-normalized vector of `identity.dimensions` floats per input text, in order.
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]]
}
