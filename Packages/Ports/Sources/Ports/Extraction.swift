import CoreGraphics
import Foundation

public enum BlockKind: String, Sendable, Codable {
    case paragraph, heading, listItem, table
}

/// A piece of extracted text with its location in the source.
public struct Block: Sendable, Equatable, Codable {
    public var text: String
    public var kind: BlockKind
    /// 1-based page number for paginated sources.
    public var page: Int?
    /// The nearest heading at or before this block.
    public var heading: String?

    public init(text: String, kind: BlockKind = .paragraph, page: Int? = nil, heading: String? = nil) {
        self.text = text
        self.kind = kind
        self.page = page
        self.heading = heading
    }
}

/// An image found in a source file, with the text around it. Extractors only find images; analyzing them
/// (text recognition, features) is done by ingestion.
public struct ExtractedImage: Sendable, Equatable {
    public var image: CGImage
    public var page: Int?
    /// The nearest heading at or before the image.
    public var heading: String?
    public var caption: String?
    public var captionSource: CaptionSource

    public init(image: CGImage, page: Int? = nil, heading: String? = nil, caption: String? = nil, captionSource: CaptionSource = .none) {
        self.image = image
        self.page = page
        self.heading = heading
        self.caption = caption
        self.captionSource = captionSource
    }

    /// Same picture (not the same pixels) and the same surroundings.
    public static func == (a: ExtractedImage, b: ExtractedImage) -> Bool {
        a.image === b.image && a.page == b.page && a.heading == b.heading && a.caption == b.caption
            && a.captionSource == b.captionSource
    }
}

public struct ExtractedDocument: Sendable, Equatable {
    public var blocks: [Block]
    public var pageCount: Int?
    public var images: [ExtractedImage]

    public init(blocks: [Block], pageCount: Int? = nil, images: [ExtractedImage] = []) {
        self.blocks = blocks
        self.pageCount = pageCount
        self.images = images
    }
}

public enum ExtractionEvent: Sendable, Equatable {
    /// Text extraction reached `page` of `total`.
    case page(Int, of: Int)
    /// Page `page` has no text layer and is being recognized with OCR.
    case recognizing(page: Int, of: Int)
}

public enum ExtractionError: Error, Equatable, LocalizedError {
    case unsupportedType(String)
    case unreadable(String)
    case passwordProtected
    case empty

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext): "Files of type “\(ext)” are not supported."
        case .unreadable(let why): "The file could not be read: \(why)"
        case .passwordProtected: "The document is password-protected."
        case .empty: "No text could be found in the document."
        }
    }
}

public protocol DocumentExtractor: Sendable {
    func extract(from url: URL, events: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument
}

/// Counts tokens the way the embedding model will, so chunks fit its input limit.
public protocol TokenCounting: Sendable {
    func count(_ text: String) -> Int
}
