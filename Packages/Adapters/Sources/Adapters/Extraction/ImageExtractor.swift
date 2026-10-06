import CoreGraphics
import Foundation
import ImageIO
import Ports

/// A photo file (JPEG, PNG, HEIC) becomes a document with no text and exactly one image. The EXIF orientation is
/// applied while decoding, so the image is upright for text recognition, similarity and display.
public struct ImageExtractor: DocumentExtractor {
    /// Longest side kept, in pixels. Phone photos are about 4,000 pixels, so this only limits huge scans.
    public let maxPixelSize: Int

    public init(maxPixelSize: Int = 4096) {
        self.maxPixelSize = maxPixelSize
    }

    public func extract(from url: URL, events: @Sendable (ExtractionEvent) -> Void) async throws -> ExtractedDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ExtractionError.unreadable("not a valid image")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ExtractionError.unreadable("the image could not be decoded")
        }
        return ExtractedDocument(blocks: [], images: [ExtractedImage(image: image)])
    }
}
