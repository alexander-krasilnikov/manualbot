import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The documents a demo starts from: two Couchbase whitepapers, bundled as PDFs, and a sample photo of the Eventing
/// debugger screenshot on page 28 of *Couchbase Under the Hood*, the one technical picture in them (their diagrams are
/// vector drawings, which are not stored as photos).
///
/// The generated X200 documents below (a service manual whose figure is a nameplate, and nameplates drawn in code) are
/// what the UI-test stub seeds and the tests are built on; Reset demo no longer imports them.
enum SampleDocuments {
    /// Bundled file, and the name it is imported under (which becomes the document title).
    private static let bundled: [(resource: String, ext: String, importedAs: String)] = [
        ("Couchbase Under the Hood", "pdf", "Couchbase Under the Hood.pdf"),
        ("Capella Architecture Overview", "pdf", "Capella Architecture Overview.pdf"),
    ]

    /// The Eventing debugger screenshot of *Couchbase Under the Hood*, page 28, as photographed
    /// (`scripts/make-sample-photo.swift` makes it from the PDF). What the chat's sample-photo button attaches.
    static let samplePhoto: Data? = Bundle.main.url(forResource: "sample-photo", withExtension: "jpg").flatMap { try? Data(contentsOf: $0) }

    /// The identity of a sample: the same on every device, so samples loaded on several iPads that share a library are one
    /// document each ("X200 Service Manual.pdf" is `sample-x200-service-manual`).
    static func id(for sample: URL) -> String {
        let name = sample.deletingPathExtension().lastPathComponent.lowercased()
        let slug = name.split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        return "sample-" + slug
    }

    /// Writes the sample files into a new folder under `parent` and returns their URLs.
    static func write(into parent: URL, bundle: Bundle = .main) throws -> [URL] {
        let folder = parent.appendingPathComponent("DemoSamples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try bundled.compactMap { sample in
            guard let source = bundle.url(forResource: sample.resource, withExtension: sample.ext) else { return nil }
            let target = folder.appendingPathComponent(sample.importedAs)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
    }

    // MARK: Photos

    /// The X200's nameplate, as the user would photograph it.
    static let x200Nameplate: Data = nameplatePhoto(model: "X200-B", serial: "4471-22")

    /// The two looks the sample plates come in, so that the X200's does not resemble the X100's.
    enum NameplateStyle { case steel, label }

    /// A nameplate with its text, as JPEG: a steel plate with stamped text, or a white sticker on a red housing.
    static func nameplatePhoto(model: String, serial: String, style: NameplateStyle = .steel) -> Data {
        let width = 1200, height = 800
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        switch style {
        case .steel: drawSteelPlate(in: context, width: width, height: height)
        case .label: drawLabel(in: context, width: width, height: height)
        }
        let lines: [(String, CGFloat, CGFloat)] = style == .steel
            ? [("ACME PURIFIERS", 62, 590), ("MODEL \(model)", 84, 480), ("S/N \(serial)", 62, 370), ("230V~  50Hz  IP54", 52, 275), ("MADE IN GERMANY", 40, 190)]
            : [("ACME PURIFIERS", 60, 585), ("MODEL \(model)", 74, 440), ("S/N \(serial)", 56, 345), ("120V  60Hz", 46, 262)]
        for (text, size, y) in lines {
            let onBand = style == .label && y > 560
            drawText(text, size: size, baselineY: y, in: context, width: CGFloat(width), color: onBand ? 1 : 0.1, stamped: style == .steel)
        }
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func drawSteelPlate(in context: CGContext, width: Int, height: Int) {
        context.setFillColor(red: 0.22, green: 0.24, blue: 0.27, alpha: 1)               // the housing behind the plate
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let plate = CGRect(x: 90, y: 110, width: 1020, height: 580)
        context.saveGState()
        context.addPath(CGPath(roundedRect: plate, cornerWidth: 28, cornerHeight: 28, transform: nil))
        context.clip()
        let steel = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [
            CGColor(gray: 0.86, alpha: 1), CGColor(gray: 0.66, alpha: 1), CGColor(gray: 0.82, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
        context.drawLinearGradient(steel, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
        context.restoreGState()
        context.setStrokeColor(gray: 0.35, alpha: 1)
        context.setLineWidth(6)
        context.addPath(CGPath(roundedRect: plate.insetBy(dx: 3, dy: 3), cornerWidth: 26, cornerHeight: 26, transform: nil))
        context.strokePath()
        context.setFillColor(gray: 0.3, alpha: 1)
        for point in [CGPoint(x: 150, y: 170), CGPoint(x: 1050, y: 170), CGPoint(x: 150, y: 630), CGPoint(x: 1050, y: 630)] {
            context.fillEllipse(in: CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32))
        }
    }

    /// A white sticker with a blue band and a barcode, on a red housing.
    private static func drawLabel(in context: CGContext, width: Int, height: Int) {
        context.setFillColor(red: 0.5, green: 0.1, blue: 0.08, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0.97, alpha: 1)
        context.fill(CGRect(x: 160, y: 120, width: 880, height: 560))
        context.setFillColor(red: 0.08, green: 0.25, blue: 0.62, alpha: 1)
        context.fill(CGRect(x: 160, y: 540, width: 880, height: 140))
        context.setFillColor(gray: 0.05, alpha: 1)
        var x: CGFloat = 220
        for (index, bar) in [6, 3, 9, 4, 4, 8, 3, 7, 5, 3, 9, 4, 6, 3, 8, 4, 3, 7].enumerated() {
            if index % 2 == 0 { context.fill(CGRect(x: x, y: 150, width: CGFloat(bar) * 4, height: 70)) }
            x += CGFloat(bar) * 4
        }
    }

    private static func drawText(
        _ text: String, size: CGFloat, baselineY: CGFloat, in context: CGContext, width: CGFloat, color: CGFloat, stamped: Bool
    ) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let x = (width - CTLineGetBoundsWithOptions(line, []).width) / 2
        if stamped {                                                                 // a highlight under the stamp
            context.setFillColor(gray: 0.97, alpha: 0.9)
            context.textPosition = CGPoint(x: x + 2, y: baselineY - 2)
            CTLineDraw(line, context)
        }
        context.setFillColor(gray: color, alpha: 1)
        context.textPosition = CGPoint(x: x, y: baselineY)
        CTLineDraw(line, context)
    }

    /// Three pages of text; the second has a figure: the X200's nameplate, cropped and slightly turned, as a
    /// manual would print it, under a caption. With `cropFigure` off the figure is the plate as photographed, which
    /// is what the stand-in image features of stub mode need in order to recognize it.
    static func makeServiceManual(cropFigure: Bool = true) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        func text(_ string: String, in rect: CGRect, size: CGFloat) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributed = NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(), CGPath(rect: rect, transform: nil), nil)
            context.setFillColor(gray: 0, alpha: 1)
            CTFrameDraw(frame, context)
        }
        context.beginPDFPage(nil)
        text("X200 Service Manual. This manual covers installation, maintenance and repair of the X200-B air purifier.",
             in: box.insetBy(dx: 54, dy: 54), size: 20)
        context.endPDFPage()

        context.beginPDFPage(nil)
        text("Maintenance of the X200-B. Find the model number on the nameplate at the rear of the unit. "
             + "Descale the X200-B every six months with the supplied descaler. Replace the HEPA filter PN-7731 every six months.",
             in: CGRect(x: 54, y: 590, width: 504, height: 150), size: 16)
        if let figure = figure(cropped: cropFigure) {
            context.draw(figure, in: CGRect(x: 96, y: 250, width: 420, height: 290))
        }
        text("Figure 1: Nameplate of the X200-B, rear panel", in: CGRect(x: 96, y: 200, width: 420, height: 36), size: 12)
        context.endPDFPage()

        context.beginPDFPage(nil)
        text("Troubleshooting. If the indicator blinks twice, switch the unit off at the wall and call the service line.",
             in: box.insetBy(dx: 54, dy: 54), size: 20)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// The nameplate cropped to its middle and turned a few degrees, kept as JPEG so the PDF embeds the file as is.
    private static func figure(cropped: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(x200Nameplate as CFData, nil),
            let plate = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        guard cropped else { return CGImage(jpegDataProviderSource: CGDataProvider(data: x200Nameplate as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent) }
        let crop = plate.cropping(to: CGRect(x: 90, y: 80, width: 1020, height: 680)) ?? plate
        let width = 840, height = 580
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(gray: 0.25, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: 4 * .pi / 180)
        context.draw(crop, in: CGRect(x: -CGFloat(width) / 2 - 10, y: -CGFloat(height) / 2 - 10, width: CGFloat(width) + 20, height: CGFloat(height) + 20))
        guard let turned = context.makeImage() else { return nil }
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, turned, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return CGImage(jpegDataProviderSource: CGDataProvider(data: jpeg)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A small text PDF, one paragraph per page.
    static func makePDF(pages: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(),
                                                 CGPath(rect: box.insetBy(dx: 54, dy: 54), transform: nil), nil)
            context.setFillColor(gray: 0, alpha: 1)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
