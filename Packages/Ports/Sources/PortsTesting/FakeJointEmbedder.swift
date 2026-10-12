import CoreGraphics
import Ports

/// A stand-in for one model that embeds words and photos into the same space, as EmbeddingGemma 2 does. Photos get the
/// colour-cell features of `FakeImageFeaturer`, padded with zeros to the model's size; words get a hashed bag of words,
/// except that a text containing the phrase of an *anchor* gets that anchor picture's vector, so the words "find" the
/// picture. Not a real model.
public struct FakeJointEmbedder: Embedder, ImageFeaturing {
    public let identity: EmbeddingModelIdentity
    private let words: FakeEmbedder
    private let anchors: [(phrase: String, vector: [Float])]

    public init(
        identity: EmbeddingModelIdentity = .init(id: "fake-joint", version: "1", dimensions: 768),
        anchors: [(phrase: String, image: CGImage)] = []
    ) {
        precondition(identity.dimensions >= 8 * 8 * 3, "a photo has 192 features")
        self.identity = identity
        words = FakeEmbedder(identity: identity)
        self.anchors = anchors.map { ($0.phrase.lowercased(), Self.padded(FakeImageFeaturer.vector(of: $0.image), to: identity.dimensions)) }
    }

    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        let hashed = try await words.embed(texts, kind: kind)
        return zip(texts, hashed).map { text, vector in
            let lowered = text.lowercased()
            return anchors.first { lowered.contains($0.phrase) }?.vector ?? vector
        }
    }

    public func features(of image: CGImage) async throws -> [Float] {
        Self.padded(FakeImageFeaturer.vector(of: image), to: identity.dimensions)
    }

    private static func padded(_ vector: [Float], to size: Int) -> [Float] { vector + [Float](repeating: 0, count: size - vector.count) }
}
