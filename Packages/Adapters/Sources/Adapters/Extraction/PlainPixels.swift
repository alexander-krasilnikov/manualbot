import CoreGraphics

/// Extracted pictures go to text recognition, the image-feature model and the stored copy. A decode array on a
/// picture (ImageIO adds one to CMYK JPEGs with an Adobe marker; PDFs can set one) is honoured when the picture is
/// drawn, but not necessarily by every consumer, so such a picture is turned into plain RGB pixels first.
enum PlainPixels {
    /// `image` itself when it needs no decode array, else its pixels as drawn, the long edge at most `maxSide`
    /// (as for pictures drawn from a PDF page). `nil` if it cannot be drawn.
    static func ensure(_ image: CGImage, maxSide: Int = 2048) -> CGImage? {
        image.decode == nil ? image : flattened(image, maxSide: maxSide)
    }

    static func flattened(_ image: CGImage, maxSide: Int = 2048) -> CGImage? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
