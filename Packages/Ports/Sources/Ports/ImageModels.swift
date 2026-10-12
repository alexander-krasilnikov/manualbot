import Foundation

/// Where an image's caption came from.
public enum CaptionSource: String, Sendable, Codable {
    /// Caption-like text printed next to the image on the page, or a caption paragraph after it.
    case nearby
    /// The alt text the author gave the image.
    case alt
    case none
}

/// A photo kept from an imported photo file or from inside a document. The display copy is stored as a
/// blob beside this record and read with `DocumentRepository.imageData(id:)`.
public struct ImageRecord: Sendable, Codable, Hashable, Identifiable {
    public var docId: String
    public var generation: Int
    /// Position among the document's images, from 0.
    public var n: Int
    public var page: Int?
    /// The nearest heading at or before the image.
    public var heading: String?
    public var caption: String?
    public var captionSource: CaptionSource
    /// Text recognized in the image itself (labels, nameplates).
    public var ocrText: String
    public var width: Int
    public var height: Int
    public var features: [Float]
    /// Tag of the `EmbeddingModelIdentity` that produced `features`.
    public var featureModel: String

    /// Deterministic, so re-writing an image overwrites it instead of duplicating it.
    public var id: String { ImageRecord.makeID(docId: docId, generation: generation, n: n) }

    public static func makeID(docId: String, generation: Int, n: Int) -> String { "\(docId):\(generation):img:\(n)" }

    /// Reads an image ID back into its parts. `nil` if it is not an image ID (a chunk ID never parses).
    public static func parseID(_ id: String) -> (docId: String, generation: Int, n: Int)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[parts.count - 2] == "img", let n = Int(parts[parts.count - 1]),
            let generation = Int(parts[parts.count - 3])
        else { return nil }
        return (parts.dropLast(3).joined(separator: ":"), generation, n)
    }

    public init(
        docId: String, generation: Int, n: Int, page: Int? = nil, heading: String? = nil, caption: String? = nil,
        captionSource: CaptionSource = .none, ocrText: String = "", width: Int, height: Int, features: [Float],
        featureModel: String
    ) {
        self.docId = docId
        self.generation = generation
        self.n = n
        self.page = page
        self.heading = heading
        self.caption = caption
        self.captionSource = captionSource
        self.ocrText = ocrText
        self.width = width
        self.height = height
        self.features = features
        self.featureModel = featureModel
    }
}

/// An image record together with the display copy to store beside it.
public struct ImageWrite: Sendable {
    public var record: ImageRecord
    public var displayCopy: Data

    public init(record: ImageRecord, displayCopy: Data) {
        self.record = record
        self.displayCopy = displayCopy
    }
}

/// A snapshot of an image that matched a photo question. It keeps rendering after its document is deleted.
public struct ImageMatch: Sendable, Codable, Hashable, Identifiable {
    public var imageId: String
    public var docId: String
    public var docTitle: String
    public var page: Int?
    public var heading: String?
    /// Cosine distance from the question's photo (0 = identical).
    public var distance: Double

    public var id: String { imageId }

    public init(imageId: String, docId: String, docTitle: String, page: Int? = nil, heading: String? = nil, distance: Double) {
        self.imageId = imageId
        self.docId = docId
        self.docTitle = docTitle
        self.page = page
        self.heading = heading
        self.distance = distance
    }
}
