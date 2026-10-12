import CoreGraphics
import Foundation
import Ports
import ImageIO
import UniformTypeIdentifiers

public enum DisplayCopyError: Error, Equatable, LocalizedError {
    case encodingFailed

    public var errorDescription: String? { "The image could not be prepared for storage." }
}

/// The copy of a photo that is stored and shown in the app: at most `maxSide` pixels on the long edge, as JPEG.
/// It is encoded from pixels only, so no metadata (camera, time, location) is carried over, and it stays small
/// enough to keep in the database next to its record.
public enum DisplayCopy {
    public static func jpeg(from image: CGImage, maxSide: Int = 1600, quality: Double = 0.8) throws -> Data {
        let longest = max(image.width, image.height)
        let scale = longest > maxSide ? Double(maxSide) / Double(longest) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        // JPEG has no transparency: draw onto white.
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw DisplayCopyError.encodingFailed }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw DisplayCopyError.encodingFailed }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DisplayCopyError.encodingFailed
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DisplayCopyError.encodingFailed }
        return data as Data
    }
}

/// The text that makes an image findable by words: its caption, section heading and the text read from it.
enum ImageChunk {
    static func text(for image: ImageRecord, title: String, chunker: Chunker) -> String {
        let parts = [image.caption, image.heading, image.ocrText.isEmpty ? nil : image.ocrText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return title }
        let joined = parts.joined(separator: " · ")
        // Long recognized text is cut to what one chunk can hold; the caption comes first, so it is kept.
        return chunker.chunk([Block(text: joined)]).first?.text ?? joined
    }
}

/// A photo the user picked or took, decoded for searching.
public enum PhotoData {
    /// The picture with its orientation applied (so text in it reads upright) and the long edge limited to
    /// `maxPixelSize`, which is plenty for text recognition and similarity and keeps memory small. `nil` if the
    /// data is not an image.
    public static func image(from data: Data, maxPixelSize: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }
}
