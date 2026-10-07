import CoreGraphics
import Foundation
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
