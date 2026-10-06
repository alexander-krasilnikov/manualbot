import CoreGraphics
import Foundation

/// Turns an image into a vector so that similar-looking images are close. Like `Embedder`, it states which
/// model made the vectors, because vectors from different models or revisions must never be compared.
public protocol ImageFeaturing: Sendable {
    var identity: EmbeddingModelIdentity { get }

    /// One L2-normalized vector of `identity.dimensions` floats.
    func features(of image: CGImage) async throws -> [Float]
}

/// A line of text found in an image, with its box in normalized image coordinates (origin bottom left).
public struct RecognizedLine: Sendable, Equatable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect = .zero) {
        self.text = text
        self.box = box
    }
}

public protocol TextRecognizing: Sendable {
    /// Recognizes text on the device, in reading order. `correctLanguage` turns on dictionary-based correction,
    /// which helps prose but damages codes such as `X200-B`.
    func recognize(_ image: CGImage, correctLanguage: Bool) async throws -> [RecognizedLine]
}

public struct ScoredImage: Sendable, Equatable {
    public var image: ImageRecord
    /// Cosine distance (0 = identical).
    public var score: Double

    public init(image: ImageRecord, score: Double) {
        self.image = image
        self.score = score
    }
}

/// Searches the images of every ready document's active generation. Half-written or superseded generations,
/// and deleted documents, are never returned. `filter.embeddingModel` is the image feature model tag.
public protocol ImageSearching: Sendable {
    /// Nearest images by cosine distance, best first.
    func imageSearch(_ vector: [Float], limit: Int, filter: SearchFilter) async throws -> [ScoredImage]
}
