import CoreGraphics
import Foundation
import Ports
import Testing
import UniformTypeIdentifiers
@testable import Adapters

@Suite struct VisionTextRecognizerTests {
    @Test func aNameplateCodeIsReadBackUncorrected() async throws {
        let image = Fixtures.bitmap(of: "MODEL X200-B", size: CGSize(width: 612, height: 300))
        let lines = try await VisionTextRecognizer().recognize(image, correctLanguage: false)
        let text = lines.map(\.text).joined(separator: " ")
        #expect(text.contains("X200-B"), "recognized: \(text)")
        #expect(lines.allSatisfy { $0.box.width > 0 && $0.box.height > 0 && $0.box.maxX <= 1.001 })
    }

    @Test func proseIsRecognizedWithCorrectionOn() async throws {
        let image = Fixtures.bitmap(of: "Hold the reset button", size: CGSize(width: 612, height: 300))
        let lines = try await VisionTextRecognizer().recognize(image, correctLanguage: true)
        #expect(lines.map(\.text).joined(separator: " ").localizedCaseInsensitiveContains("reset button"))
    }

    @Test func aBlankImageHasNoLines() async throws {
        let image = Fixtures.bitmap(of: "", size: CGSize(width: 300, height: 300))
        #expect(try await VisionTextRecognizer().recognize(image, correctLanguage: false).isEmpty)
    }

    @Test func pdfOCRGoesThroughTheRecognizerPort() async throws {
        let fx = Fixtures()
        let scan = fx.pdf(pages: ["anything"], scanned: true, name: "port.pdf")
        let recognizer = FakeCountingRecognizer()
        let result = try await PDFExtractor(recognizer: recognizer).extract(from: scan) { _ in }
        #expect(recognizer.calls == [true])                       // prose pages keep language correction
        #expect(result.blocks.map(\.text) == ["scripted line"])
    }
}

private final class FakeCountingRecognizer: TextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var calls: [Bool] { lock.withLock { recorded } }

    func recognize(_ image: CGImage, correctLanguage: Bool) async throws -> [RecognizedLine] {
        lock.withLock { recorded.append(correctLanguage) }
        return [RecognizedLine(text: "scripted line")]
    }
}

@Suite struct ImageExtractorTests {
    let fx = Fixtures()

    @Test(arguments: [("photo.jpg", UTType.jpeg), ("photo.JPEG", UTType.jpeg), ("photo.png", UTType.png), ("photo.heic", UTType.heic)])
    func eachPhotoTypeBecomesOneImageWithNoText(name: String, type: UTType) async throws {
        let url = fx.imageFile(Fixtures.picture(width: 400, height: 300), type: type, name: name)
        let result = try await FileDocumentExtractor().extract(from: url) { _ in }
        #expect(result.blocks.isEmpty && result.pageCount == nil)
        let image = try #require(result.images.first)
        #expect(result.images.count == 1 && image.image.width == 400 && image.image.height == 300)
        #expect(image.page == nil && image.caption == nil && image.captionSource == .none)
        #expect(FileDocumentExtractor.documentType(for: url) == .image)
    }

    @Test func aRotatedHEICIsReturnedUpright() async throws {
        // Stored 400 wide by 200 tall with orientation 6: shown upright it is 200 wide by 400 tall.
        let url = fx.imageFile(Fixtures.picture(width: 400, height: 200), type: .heic, orientation: 6, name: "turned.heic")
        let image = try #require(try await ImageExtractor().extract(from: url) { _ in }.images.first).image
        #expect(image.width == 200 && image.height == 400)
    }

    @Test func aHugeImageIsLimitedToTheLongestSide() async throws {
        let url = fx.imageFile(Fixtures.picture(width: 3000, height: 1500), type: .png, name: "huge.png")
        let image = try #require(try await ImageExtractor(maxPixelSize: 1000).extract(from: url) { _ in }.images.first).image
        #expect(max(image.width, image.height) == 1000)
    }

    @Test func aFileThatIsNotAnImageIsRejectedWithAReason() async {
        let url = fx.write(Data("not a picture".utf8), as: "fake.jpg")
        await #expect(throws: ExtractionError.unreadable("not a valid image")) {
            try await ImageExtractor().extract(from: url) { _ in }
        }
    }
}
