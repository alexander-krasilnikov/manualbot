import CoreGraphics
import Foundation
import Ports
import Vision

public enum ImageFeatureError: Error, Equatable, LocalizedError {
    case noFeatures
    /// The system returned the same vector for different pictures, as the iOS Simulator does.
    case unusable
    case unexpectedDimensions(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .noFeatures: "The image could not be analyzed."
        case .unusable: "Image similarity is not available on this device."
        case .unexpectedDimensions(let expected, let got): "The image analysis returned \(got) values where \(expected) were expected."
        }
    }
}

/// Image similarity vectors from Vision's feature print, which ships with the OS: no model is bundled or
/// downloaded. The identity (revision and size) is read from the system once, when this is created, so an OS
/// update that changes the revision shows up as a different model tag and old vectors are no longer compared.
public struct VisionFeaturePrinter: ImageFeaturing {
    public let identity: EmbeddingModelIdentity
    private let revision: Int

    public init() throws {
        let revision = VNGenerateImageFeaturePrintRequest.currentRevision
        let probe = try Self.observation(for: Self.probeImage(), revision: revision)
        guard probe.elementType == .float else { throw ImageFeatureError.noFeatures }
        // The iOS Simulator has no usable image model and gives every picture the same vector, which would make
        // every photo "match" every other. Better to have no photo search than a wrong one.
        let other = try Self.observation(for: Self.probeImage(inverted: true), revision: revision)
        var distance: Float = 0
        try probe.computeDistance(&distance, to: other)
        guard distance > 0.001 else { throw ImageFeatureError.unusable }
        self.revision = revision
        identity = EmbeddingModelIdentity(id: "vision-featureprint", version: String(revision), dimensions: probe.elementCount)
    }

    public func features(of image: CGImage) async throws -> [Float] {
        let revision = revision, dimensions = identity.dimensions
        return try await VisionQueue.run {
            let values = Self.floats(of: try Self.observation(for: image, revision: revision))
            guard values.count == dimensions else {
                throw ImageFeatureError.unexpectedDimensions(expected: dimensions, got: values.count)
            }
            return Self.normalized(values)
        }
    }

    // MARK: Helpers

    private static func observation(for image: CGImage, revision: Int) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = revision
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { throw ImageFeatureError.noFeatures }
        return observation
    }

    private static func floats(of observation: VNFeaturePrintObservation) -> [Float] {
        observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Unit length, so the database's cosine metric ranks images the way Vision's own distance does.
    private static func normalized(_ values: [Float]) -> [Float] {
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? values.map { $0 / norm } : values
    }

    private static func probeImage(inverted: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: inverted ? 0.9 : 0.2, green: inverted ? 0.8 : 0.5, blue: inverted ? 0.1 : 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(red: inverted ? 0.2 : 0.9, green: inverted ? 0.5 : 0.8, blue: inverted ? 0.8 : 0.1, alpha: 1)
        context.fillEllipse(in: CGRect(x: inverted ? 4 : 16, y: inverted ? 28 : 16, width: inverted ? 56 : 32, height: inverted ? 20 : 32))
        return context.makeImage()!
    }
}
