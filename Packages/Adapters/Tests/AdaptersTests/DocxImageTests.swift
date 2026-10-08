import Foundation
import ImageIO
import Ports
import Testing
@testable import Adapters

@Suite struct DocxImageTests {
    let fx = Fixtures()
    let png = Fixtures.pngData(side: 320)

    private func extract(_ url: URL) async throws -> ExtractedDocument {
        try await DocxExtractor().extract(from: url) { _ in }
    }

    /// A CMYK JPEG on its own is shown the way ImageIO reads it, Adobe inversion included; the extracted picture
    /// must have those colours as plain pixels, so text recognition and features cannot read it differently.
    @Test func aCMYKPhotoInAWordFileHasPlainPixelsWithItsOwnColours() async throws {
        let jpeg = Fixtures.cmykJPEG(cyan: 0.9, magenta: 0.2, yellow: 0.1, black: 0, side: 320)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let reference = Fixtures.averageRGB(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let url = fx.docx(body: Fixtures.drawing("rId5"), media: ["media/image1.jpg": jpeg], relationships: ["rId5": "media/image1.jpg"])
        let image = try #require(try await extract(url).images.first).image
        let colour = Fixtures.averageRGB(image)
        #expect(image.decode == nil)
        #expect(abs(colour.red - reference.red) < 0.1 && abs(colour.green - reference.green) < 0.1 && abs(colour.blue - reference.blue) < 0.1,
                "extracted \(colour), file shows \(reference)")
    }

    @Test func aCMYKPhotoFileHasPlainPixelsWithItsOwnColours() async throws {
        let jpeg = Fixtures.cmykJPEG(cyan: 0.9, magenta: 0.2, yellow: 0.1, black: 0, side: 320)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let reference = Fixtures.averageRGB(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let url = fx.write(jpeg, as: "plate.jpg")
        let image = try #require(try await ImageExtractor().extract(from: url) { _ in }.images.first).image
        let colour = Fixtures.averageRGB(image)
        #expect(image.decode == nil)
        #expect(abs(colour.red - reference.red) < 0.1 && abs(colour.green - reference.green) < 0.1 && abs(colour.blue - reference.blue) < 0.1,
                "extracted \(colour), file shows \(reference)")
    }

    @Test func aPictureKeepsItsHeadingAndAltText() async throws {
        let body = Fixtures.paragraph("Installation", style: "Heading1") + Fixtures.paragraph("Mount the pump.")
            + Fixtures.drawing("rId5", alt: "Pump, front view")
        let url = fx.docx(body: body, media: ["media/image1.png": png], relationships: ["rId5": "media/image1.png"])
        let result = try await extract(url)
        let image = try #require(result.images.first)
        #expect(result.images.count == 1 && image.image.width == 320)
        #expect(image.heading == "Installation" && image.caption == "Pump, front view" && image.captionSource == .alt)
        #expect(image.page == nil)
        #expect(result.blocks.map(\.text) == ["Installation", "Mount the pump."])
    }

    @Test func aCaptionParagraphIsUsedWhenTheAltTextIsMachineMade() async throws {
        let body = Fixtures.paragraph("Service", style: "Heading1")
            + Fixtures.drawing("rId5", alt: "A picture containing text, Description automatically generated")
            + Fixtures.paragraph("Figure 2: Drain plug", style: "Caption") + Fixtures.paragraph("Open the plug.")
        let url = fx.docx(body: body, media: ["media/image1.png": png], relationships: ["rId5": "media/image1.png"])
        let image = try #require(try await extract(url).images.first)
        #expect(image.caption == "Figure 2: Drain plug" && image.captionSource == .nearby)
    }

    @Test func aParagraphThatStartsLikeAFigureLabelIsACaptionEvenWithoutTheStyle() async throws {
        let body = Fixtures.drawing("rId5") + Fixtures.paragraph("Figure 1. Rear panel")
        let url = fx.docx(body: body, media: ["media/image1.png": png], relationships: ["rId5": "media/image1.png"])
        #expect(try await extract(url).images.first?.caption == "Figure 1. Rear panel")
    }

    @Test func ordinaryTextAfterAPictureIsNotItsCaption() async throws {
        let body = Fixtures.drawing("rId5") + Fixtures.paragraph("Open the cover and remove the filter.")
            + Fixtures.paragraph("Figure 9 is far away.")
        let url = fx.docx(body: body, media: ["media/image1.png": png], relationships: ["rId5": "media/image1.png"])
        let image = try #require(try await extract(url).images.first)
        #expect(image.caption == nil && image.captionSource == .none)
    }

    @Test func smallRepeatedBrokenAndUnsupportedPicturesAreSkipped() async throws {
        let body = [
            Fixtures.drawing("rIcon"),                                             // too small
            Fixtures.drawing("rLogo"), Fixtures.drawing("rLogo"), Fixtures.drawing("rLogo"), Fixtures.drawing("rLogo"),  // used 4 times
            Fixtures.drawing("rMetafile"),                                         // not decodable
            Fixtures.drawing("rMissing"),                                          // no such file in the package
            Fixtures.drawing("rGood", alt: "Control panel"),
            Fixtures.paragraph("Text."),
        ].joined()
        let url = fx.docx(
            body: body,
            media: ["media/icon.png": Fixtures.pngData(side: 64, seed: 2), "media/logo.png": Fixtures.pngData(side: 200, seed: 3),
                    "media/old.emf": Data("not an image".utf8), "media/good.png": png],
            relationships: ["rIcon": "media/icon.png", "rLogo": "media/logo.png", "rMetafile": "media/old.emf",
                            "rMissing": "media/gone.png", "rGood": "media/good.png"])
        let result = try await extract(url)
        #expect(result.images.map(\.caption) == ["Control panel"])
    }

    @Test func aPictureUsedThreeTimesIsKept() async throws {
        let body = (0..<3).map { _ in Fixtures.drawing("rA") }.joined() + Fixtures.paragraph("Text.")
        let url = fx.docx(body: body, media: ["media/a.png": png], relationships: ["rA": "media/a.png"])
        #expect(try await extract(url).images.count == 3)
    }

    @Test func aDocumentWithOnlyAPictureIsNotEmpty() async throws {
        let url = fx.docx(body: Fixtures.drawing("rA", alt: "Wiring"), media: ["media/a.png": png], relationships: ["rA": "media/a.png"])
        let result = try await extract(url)
        #expect(result.blocks.isEmpty && result.images.count == 1)
    }

    @Test func absoluteAndParentRelativeTargetsResolve() async throws {
        #expect(DocxExtractor.path(of: "media/image1.png") == "word/media/image1.png")
        #expect(DocxExtractor.path(of: "/word/media/image1.png") == "word/media/image1.png")
        #expect(DocxExtractor.path(of: "../word/media/image1.png") == "word/media/image1.png")
        let url = fx.docx(body: Fixtures.drawing("rA", alt: "Panel"), media: ["media/a.png": png], relationships: ["rA": "/word/media/a.png"])
        #expect(try await extract(url).images.count == 1)
    }

    @Test func textOnlyDocumentsAreUnchanged() async throws {
        let url = fx.docx(body: Fixtures.paragraph("Hello"))
        let result = try await extract(url)
        #expect(result.images.isEmpty && result.blocks.count == 1)
    }

    @Test func altTextThatSaysNothingIsRecognized() {
        for useless in ["", "  ", "image1.png", "Picture 3", "A picture containing text", "Chart, Description automatically generated", "IMG_2041.JPG"] {
            #expect(!DocxExtractor.isMeaningful(alt: useless), "\(useless)")
        }
        for useful in ["Pump, front view", "Control panel with three buttons"] {
            #expect(DocxExtractor.isMeaningful(alt: useful), "\(useful)")
        }
    }
}
