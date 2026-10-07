import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

extension Fixtures {
    /// A picture file of the given type. `orientation` is the EXIF value (6 = the stored pixels must be turned
    /// 90 degrees clockwise to show upright).
    func imageFile(_ image: CGImage, type: UTType = .jpeg, orientation: Int = 1, name: String) -> URL {
        let target = url(name)
        let destination = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination), "could not write \(name)")
        return target
    }

    /// A solid-colour picture with a band on the left, so a wrong rotation is detectable from the size alone.
    static func picture(width: Int, height: Int, red: CGFloat = 0.8) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: 0.4, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 5, height: height))
        return context.makeImage()!
    }
}

/// What to draw on one page of a generated PDF. Rectangles are in PDF points, origin bottom left, on a 612 x 792 page.
struct PDFPageSpec {
    var texts: [(text: String, rect: CGRect, size: CGFloat)] = []
    var images: [(image: CGImage, rect: CGRect)] = []
    /// Draw the images inside a transparency layer, which PDF writes as a Form XObject.
    var wrapInForm = false
    /// A full-page bitmap of this text and no text layer, like a scanned page.
    var scannedText: String?
}

extension Fixtures {
    /// A picture whose JPEG bytes are embedded in a PDF unchanged (a DCTDecode stream), as in real manuals.
    static func jpegBacked(_ image: CGImage) -> CGImage {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return CGImage(jpegDataProviderSource: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// A multi-page PDF with images placed at known positions.
    func pdf(layout pages: [PDFPageSpec], name: String = "figures.pdf") -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for spec in pages {
            context.beginPDFPage(nil)
            if let scanned = spec.scannedText { context.draw(Self.bitmap(of: scanned, size: box.size), in: box) }
            for item in spec.texts { Self.drawText(item.text, in: context, rect: item.rect, size: item.size) }
            if spec.wrapInForm { context.beginTransparencyLayer(auxiliaryInfo: nil); context.setAlpha(0.9) }
            for item in spec.images { context.draw(item.image, in: item.rect) }
            if spec.wrapInForm { context.endTransparencyLayer() }
            context.endPDFPage()
        }
        context.closePDF()
        return write(data as Data, as: name)
    }

    /// Overwrites the first bytes of every embedded JPEG, so ImageIO cannot decode it while the PDF itself stays valid.
    func damageJPEGStreams(in url: URL) throws {
        var bytes = try Data(contentsOf: url)
        var searchFrom = bytes.startIndex
        while let start = bytes.range(of: Data([0xFF, 0xD8, 0xFF]), in: searchFrom..<bytes.endIndex)?.lowerBound {
            bytes.replaceSubrange(start..<start + 4, with: Data([0, 0, 0, 0]))
            searchFrom = start + 4
        }
        try bytes.write(to: url)
    }
}

extension Fixtures {
    /// A .docx package with pictures: `media` maps a path under `word/` (such as `media/a.png`) to its bytes, and
    /// `relationships` maps relationship IDs to those paths.
    func docx(body: String, media: [String: Data], relationships: [String: String], name: String = "pictures.docx") -> URL {
        let target = url(name)
        try? FileManager.default.removeItem(at: target)
        let documentXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
            """
        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>
            <Default Extension="emf" ContentType="image/x-emf"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """
        let rels = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            \(relationships.sorted { $0.key < $1.key }.map { "<Relationship Id=\"\($0.key)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"\($0.value)\"/>" }.joined())
            </Relationships>
            """
        let archive = (try? Archive(url: target, accessMode: .create))!
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)), ("word/document.xml", Data(documentXML.utf8)),
            ("word/_rels/document.xml.rels", Data(rels.utf8)),
        ]
        entries += media.sorted { $0.key < $1.key }.map { ("word/" + $0.key, $0.value) }
        for (path, bytes) in entries {
            try! archive.addEntry(with: path, type: .file, uncompressedSize: UInt32(bytes.count)) { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return target
    }

    /// A paragraph holding one inline picture, as Word writes it.
    static func drawing(_ relationship: String, alt: String? = nil, style: String? = nil) -> String {
        let props = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        let descr = alt.map { " descr=\"\($0)\"" } ?? ""
        return """
            <w:p>\(props)<w:r><w:drawing><wp:inline><wp:extent cx="3000000" cy="2000000"/><wp:docPr id="1" name="Picture 1"\(descr)/>\
            <a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="\(relationship)"/></pic:blipFill></pic:pic></a:graphicData></a:graphic>\
            </wp:inline></w:drawing></w:r></w:p>
            """
    }

    /// PNG bytes of a generated picture.
    static func pngData(side: Int, seed: UInt64 = 1) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, Fixtures.scene(seed, size: side), nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

extension Fixtures {
    /// A deterministic scene of overlapping coloured shapes. `variant` shifts, scales and re-lights the same
    /// scene a little, standing in for a second photo of the same object.
    static func scene(_ seed: UInt64, variant: Int = 0, size: Int = 320) -> CGImage {
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        func next() -> CGFloat {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return CGFloat(state % 10_000) / 10_000
        }
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(size)
        context.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let shift = CGFloat(variant) * 6, zoom = 1 + CGFloat(variant) * 0.04, light = 1 - CGFloat(variant) * 0.05
        context.translateBy(x: shift, y: -shift)
        context.scaleBy(x: zoom, y: zoom)
        for _ in 0..<9 {
            context.setFillColor(red: next() * light, green: next() * light, blue: next() * light, alpha: 1)
            let rect = CGRect(x: next() * s * 0.7, y: next() * s * 0.7, width: 30 + next() * s * 0.4, height: 30 + next() * s * 0.4)
            if next() > 0.5 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        return context.makeImage()!
    }
}
