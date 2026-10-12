import CoreGraphics
import CoreText
import Foundation
import ZIPFoundation

/// Generates small real documents for extractor tests, so no binary fixtures live in the repo.
/// Each instance owns a unique temporary directory that is removed when the instance is released,
/// so tests running in parallel never touch each other's files.
final class Fixtures: @unchecked Sendable {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fixtures-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: directory) }

    func url(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func write(_ data: Data, as name: String) -> URL {
        let target = url(name)
        try? data.write(to: target)
        return target
    }

    // MARK: PDF

    /// One PDF page per string. `scanned` pages contain only an image of the text (no text layer).
    func pdf(pages: [String], scanned: Bool = false, password: String? = nil, name: String = "doc.pdf") -> URL {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var aux: [CFString: Any] = [:]
        if let password {
            aux[kCGPDFContextUserPassword] = password
            aux[kCGPDFContextOwnerPassword] = password
        }
        let context = CGContext(consumer: consumer, mediaBox: &box, aux as CFDictionary)!
        for text in pages {
            context.beginPDFPage(nil)
            if scanned {
                context.draw(Self.bitmap(of: text, size: box.size), in: box)
            } else {
                Self.drawText(text, in: context, rect: box.insetBy(dx: 54, dy: 54), size: 20)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return write(data as Data, as: name)
    }

    static func drawText(_ text: String, in context: CGContext, rect: CGRect, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        context.setFillColor(gray: 0, alpha: 1)
        CTFrameDraw(frame, context)
    }

    /// A page-sized bitmap of black text on white, at 2x so OCR has enough pixels.
    static func bitmap(of text: String, size: CGSize) -> CGImage {
        let scale: CGFloat = 2
        let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        context.scaleBy(x: scale, y: scale)
        drawText(text, in: context, rect: CGRect(origin: .zero, size: size).insetBy(dx: 54, dy: 54), size: 28)
        return context.makeImage()!
    }

    // MARK: ZIP

    /// A zip with the given entries; entry paths are stored exactly as written (including unsafe ones).
    func zip(_ entries: [(path: String, data: Data)], name: String = "model.zip") -> URL {
        let target = url(name)
        try? FileManager.default.removeItem(at: target)
        let archive = (try? Archive(url: target, accessMode: .create))!
        for entry in entries {
            try! archive.addEntry(with: entry.path, type: .file, uncompressedSize: UInt32(entry.data.count)) { position, size in
                entry.data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return target
    }

    // MARK: DOCX

    /// Wraps `body` (the inside of `<w:body>`) in a minimal, valid .docx package.
    func docx(body: String, name: String = "doc.docx") -> URL {
        let target = url(name)
        try? FileManager.default.removeItem(at: target)
        let documentXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)</w:body></w:document>
            """
        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            </Types>
            """
        let archive = (try? Archive(url: target, accessMode: .create))!
        for (path, text) in [("[Content_Types].xml", contentTypes), ("word/document.xml", documentXML)] {
            let bytes = Data(text.utf8)
            try! archive.addEntry(with: path, type: .file, uncompressedSize: UInt32(bytes.count)) { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return target
    }

    static func paragraph(_ text: String, style: String? = nil, list: Bool = false) -> String {
        let props = (style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? "") + (list ? "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>" : "")
        return "<w:p><w:pPr>\(props)</w:pPr><w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p>"
    }

    static func table(_ rows: [[String]]) -> String {
        "<w:tbl>" + rows.map { row in
            "<w:tr>" + row.map { "<w:tc>\(paragraph($0))</w:tc>" }.joined() + "</w:tr>"
        }.joined() + "</w:tbl>"
    }
}
