import CoreGraphics
import Foundation
import Ports
import Vision

/// On-device text recognition with Vision. Used for scanned PDF pages, for every image kept from a document,
/// and for photos attached to a question.
public struct VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(_ image: CGImage, correctLanguage: Bool) async throws -> [RecognizedLine] {
        try await VisionQueue.run {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // Codes such as "X200-B" are "corrected" into words, so correction is for prose only.
            request.usesLanguageCorrection = correctLanguage
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, box: observation.boundingBox) }
            }
        }
    }
}
