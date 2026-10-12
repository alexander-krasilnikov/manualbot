import CoreGraphics
import Ports

/// Deterministic image features: the picture shrunk to 8 x 8 colour cells, centred and normalized. A slightly
/// cropped or re-lit copy of a picture stays close to it and a different picture is far. Not a real model.
public struct FakeImageFeaturer: ImageFeaturing {
    public let identity: EmbeddingModelIdentity
    private static let side = 8

    public init(identity: EmbeddingModelIdentity = .init(id: "fake-image-features", version: "1", dimensions: 8 * 8 * 3)) {
        self.identity = identity
    }

    public func features(of image: CGImage) async throws -> [Float] { Self.vector(of: image) }

    /// The same vector, without waiting; the joint stand-in uses it to anchor words to a picture.
    static func vector(of image: CGImage) -> [Float] {
        let side = Self.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var v: [Float] = []
        for i in 0..<(side * side) { v += [Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2])] }
        let mean = v.reduce(0, +) / Float(v.count)
        v = v.map { $0 - mean }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm == 0 { v[0] = 1 } else { for i in v.indices { v[i] /= norm } }
        return v
    }
}
