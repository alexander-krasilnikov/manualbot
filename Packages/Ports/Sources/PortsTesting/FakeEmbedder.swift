import Ports

/// Deterministic bag-of-words embedder: texts sharing words get similar vectors. Not a real model.
public struct FakeEmbedder: Embedder {
    public let identity: EmbeddingModelIdentity

    public init(identity: EmbeddingModelIdentity = .init(id: "fake-embedder", version: "1", dimensions: 32)) {
        self.identity = identity
    }

    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        texts.map { vector(for: $0) }
    }

    func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0, count: identity.dimensions)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            v[Int(fnv1a(word) % UInt64(identity.dimensions))] += 1
        }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm == 0 { v[0] = 1 } else { for i in v.indices { v[i] /= norm } }
        return v
    }

    private func fnv1a(_ s: Substring) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return h
    }
}
