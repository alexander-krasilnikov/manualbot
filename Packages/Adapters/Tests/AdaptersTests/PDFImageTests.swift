import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Ports
import Testing
@testable import Adapters

@Suite struct PDFImageTests {
    let fx = Fixtures()
    let photo = Fixtures.jpegBacked(Fixtures.scene(21, size: 320))
    let photoRect = CGRect(x: 100, y: 420, width: 300, height: 250)

    private func extract(_ url: URL) async throws -> ExtractedDocument {
        try await PDFExtractor().extract(from: url) { _ in }
    }

    private var bodyText: (text: String, rect: CGRect, size: CGFloat) {
        ("Remove the housing before cleaning.", CGRect(x: 54, y: 700, width: 504, height: 50), 14)
    }

    // MARK: CMYK photos

    /// The picture as extracted must have the colours the page shows. Print PDFs embed CMYK JPEGs with an Adobe marker;
    /// ImageIO inverts those by itself, but inside a PDF only the image's /Decode array may invert them.
    @Test(arguments: [nil, "[1 0 1 0 1 0 1 0]"])
    func aCMYKPhotoKeepsTheColoursThePageShows(decode: String?) async throws {
        let jpeg = Fixtures.cmykJPEG(cyan: 1, magenta: 0.1, yellow: 0, black: 0, side: 320)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.decode != nil, "the fixture should carry ImageIO's Adobe inversion, as the brochures' photos do")
        let rect = CGRect(x: 100, y: 420, width: 300, height: 250)
        let url = fx.pdf(embeddingJPEG: jpeg, side: 320, decode: decode, rect: rect)
        try await expectExtractedMatchesPage(url, rect: rect)
    }

    /// Extracts the only picture of `url` and checks it has the colour the page shows under `rect`.
    private func expectExtractedMatchesPage(_ url: URL, rect: CGRect, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let image = try #require(try await extract(url).images.first, sourceLocation: sourceLocation)
        // Every consumer (text recognition, features, the stored copy) must see the same pixels: no decode array left.
        #expect(image.image.decode == nil, "the extracted picture must not depend on a decode array", sourceLocation: sourceLocation)
        let extracted = Fixtures.averageRGB(image.image)
        let page = try #require(PDFDocument(url: url)?.page(at: 0), sourceLocation: sourceLocation)
        let drawn = try #require(PDFImageScanner.render(rect.insetBy(dx: 20, dy: 20), of: page), sourceLocation: sourceLocation)
        let shown = Fixtures.averageRGB(drawn)
        #expect(abs(extracted.red - shown.red) < 0.12 && abs(extracted.green - shown.green) < 0.12 && abs(extracted.blue - shown.blue) < 0.12,
                "extracted \(extracted), page shows \(shown)", sourceLocation: sourceLocation)
    }

    @Test func rawGraySamplesWithAnInvertingDecodeArrayKeepThePagesColours() async throws {
        let rect = CGRect(x: 100, y: 420, width: 300, height: 250)
        let samples = Data(repeating: 40, count: 320 * 320)   // dark samples, shown light by /Decode [1 0]
        let url = fx.pdf(embeddingJPEG: samples, side: 320, colorSpace: "/DeviceGray", decode: "[1 0]", filter: nil, rect: rect)
        try await expectExtractedMatchesPage(url, rect: rect)
    }

    @Test func aJPEGInASpotColourIsDrawnFromThePage() async throws {
        let rect = CGRect(x: 100, y: 420, width: 300, height: 250)
        // A gray JPEG whose single component is a magenta spot ink: ImageIO alone would show it gray.
        let spot = "[/Separation /Magenta /DeviceCMYK << /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [0 1 0 0] /N 1 >>]"
        let url = fx.pdf(embeddingJPEG: Fixtures.grayJPEG(level: 0.3, side: 320), side: 320, colorSpace: spot, rect: rect)
        try await expectExtractedMatchesPage(url, rect: rect)
    }

    @Test(arguments: [0, 1])
    func aJPEGWhoseColorTransformParameterOverridesItsMarkerIsDrawnFromThePage(transform: Int) async throws {
        let rect = CGRect(x: 100, y: 420, width: 300, height: 250)
        let jpeg = Fixtures.cmykJPEG(cyan: 0.9, magenta: 0.2, yellow: 0.1, black: 0, side: 320)
        let url = fx.pdf(embeddingJPEG: jpeg, side: 320, decodeParms: "<< /ColorTransform \(transform) >>", rect: rect)
        try await expectExtractedMatchesPage(url, rect: rect)
    }

    // MARK: 4.4 placement, forms, captions, damage

    @Test func aCaptionedPhotoKeepsItsPageAndCaption() async throws {
        let caption = (text: "Figure 3: Filter housing, rear view", rect: CGRect(x: 100, y: 380, width: 300, height: 36), size: CGFloat(12))
        let url = fx.pdf(layout: [
            PDFPageSpec(texts: [bodyText]),
            PDFPageSpec(texts: [bodyText, caption], images: [(photo, photoRect)]),
        ])
        let result = try await extract(url)
        let image = try #require(result.images.first)
        #expect(result.images.count == 1)
        #expect(image.page == 2 && image.image.width == 320 && image.image.height == 320)
        #expect(image.caption == "Figure 3: Filter housing, rear view" && image.captionSource == .nearby)
        #expect(result.blocks.contains { $0.page == 1 })
    }

    @Test func aCaptionAboveTheImageIsUsedWhenNothingIsBelow() async throws {
        let above = (text: "Photo 2. Pump inlet", rect: CGRect(x: 100, y: 690, width: 300, height: 30), size: CGFloat(12))
        let url = fx.pdf(layout: [PDFPageSpec(texts: [above], images: [(photo, photoRect)])])
        #expect(try await extract(url).images.first?.caption == "Photo 2. Pump inlet")
    }

    @Test func aParagraphThatFillsTheBandUnderAnImageIsNotACaption() async throws {
        let paragraph = String(repeating: "The pump must be flushed with clean water after every use and dried completely. ", count: 6)
        let body = (text: paragraph, rect: CGRect(x: 100, y: 330, width: 300, height: 88), size: CGFloat(9))
        let url = fx.pdf(layout: [PDFPageSpec(texts: [body], images: [(photo, photoRect)])])
        let image = try #require(try await extract(url).images.first)
        #expect(image.caption == nil && image.captionSource == .none)
    }

    @Test func aPhotoInsideAFormObjectIsFound() async throws {
        let url = fx.pdf(layout: [PDFPageSpec(texts: [bodyText], images: [(photo, photoRect)], wrapInForm: true)])
        let bytes = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        try #require(bytes.contains("/Subtype /Form"), "the fixture should wrap the photo in a Form XObject")
        let image = try #require(try await extract(url).images.first)
        #expect(image.page == 1 && image.image.width == 320)
    }

    @Test func aPictureStoredAsRawSamplesIsDecoded() async throws {
        let plain = Fixtures.scene(22, size: 300)
        let url = fx.pdf(layout: [PDFPageSpec(texts: [bodyText], images: [(plain, photoRect)])])
        let image = try #require(try await extract(url).images.first)
        #expect(image.image.width == 300 && image.image.height == 300)
    }

    @Test func aDamagedImageIsSkippedAndTheDocumentStillIndexes() async throws {
        let url = fx.pdf(layout: [PDFPageSpec(texts: [bodyText], images: [(photo, photoRect)])])
        try fx.damageJPEGStreams(in: url)
        let result = try await extract(url)
        #expect(result.images.isEmpty)
        #expect(result.blocks.first?.text.contains("Remove the housing") == true)
    }

    @Test func imagesComeInReadingOrder() async throws {
        let low = CGRect(x: 100, y: 100, width: 200, height: 200), high = CGRect(x: 100, y: 500, width: 200, height: 200)
        let other = Fixtures.jpegBacked(Fixtures.scene(23, size: 320))
        let url = fx.pdf(layout: [PDFPageSpec(texts: [bodyText], images: [(photo, low), (other, high)])])
        let images = try await extract(url).images
        #expect(images.count == 2)
        #expect(images.map(\.page) == [1, 1])
    }

    @Test func aPdfWithOnlyPhotosIsNotEmpty() async throws {
        let url = fx.pdf(layout: [PDFPageSpec(images: [(photo, photoRect)])])
        let result = try await extract(url)
        #expect(result.blocks.isEmpty && result.images.count == 1 && result.pageCount == 1)
    }

    @Test func aPdfWithNothingIsStillEmpty() async throws {
        let url = fx.pdf(layout: [PDFPageSpec()])
        await #expect(throws: ExtractionError.empty) { try await extract(url) }
    }

    // MARK: 4.5 filters

    @Test func logosAndRepeatedPicturesAreNotKept() async throws {
        let logo = Fixtures.jpegBacked(Fixtures.scene(31, size: 100))          // under the size limit
        let letterhead = Fixtures.jpegBacked(Fixtures.scene(32, size: 200))   // big enough, on every page
        let pages = (0..<5).map { _ in
            PDFPageSpec(texts: [bodyText], images: [(logo, CGRect(x: 500, y: 700, width: 60, height: 60)), (letterhead, CGRect(x: 54, y: 740, width: 100, height: 40))])
        }
        let result = try await extract(fx.pdf(layout: pages))
        #expect(result.images.isEmpty)
        #expect(result.blocks.count == 5)
    }

    @Test func aPictureOnFewPagesIsKept() async throws {
        let figure = Fixtures.jpegBacked(Fixtures.scene(33, size: 200))
        let pages = (0..<3).map { _ in PDFPageSpec(texts: [bodyText], images: [(figure, photoRect)]) }
        #expect(try await extract(fx.pdf(layout: pages)).images.count == 3)
    }

    @Test func scannedPagesAndTheirLogosYieldNoImagesButStillGiveText() async throws {
        let logo = Fixtures.jpegBacked(Fixtures.scene(34, size: 100))
        let pages = (0..<2).map { _ in
            PDFPageSpec(images: [(logo, CGRect(x: 500, y: 700, width: 60, height: 60))], scannedText: "Hold the reset button")
        }
        let result = try await extract(fx.pdf(layout: pages))
        #expect(result.images.isEmpty)
        #expect(result.blocks.contains { $0.text.localizedCaseInsensitiveContains("reset button") })
    }

    @Test func aPhotoOnAScannedPageIsKeptWhenItIsNotThePageItself() async throws {
        let url = fx.pdf(layout: [PDFPageSpec(images: [(photo, CGRect(x: 100, y: 100, width: 150, height: 150))], scannedText: "Hold the reset button")])
        let result = try await extract(url)
        #expect(result.images.count == 1)
    }

    @Test func captionRulesAcceptShortLinesAndFigureLabels() {
        #expect(PDFExtractor.isCaption("Pump inlet", lineCount: 1))
        #expect(PDFExtractor.isCaption("Figure 4 shows the inlet, the outlet, the drain plug and the three mounting points of the unit in detail.", lineCount: 3))
        #expect(!PDFExtractor.isCaption("The pump must be flushed with clean water after every use and dried.", lineCount: 3))
        #expect(!PDFExtractor.isCaption("", lineCount: 1))
    }
}
