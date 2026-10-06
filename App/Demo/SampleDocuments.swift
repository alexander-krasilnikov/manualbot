import CoreText
import Foundation

/// The documents a demo starts from: three bundled text files and a small generated PDF.
enum SampleDocuments {
    /// Bundled file, and the name it is imported under (which becomes the document title).
    private static let bundled: [(resource: String, ext: String, importedAs: String)] = [
        ("x200-manual", "md", "X200 Manual.md"),
        ("bike-repair", "md", "Bike Repair.md"),
        ("warranty", "txt", "Warranty.txt"),
    ]

    static let filterGuidePages = [
        "This guide explains how to look after the filter of the purifier.",
        "Replace the HEPA filter every six months by opening the rear panel and sliding out the old filter.",
        "Dispose of the used filter with household waste and record the date in the service log.",
    ]

    /// Writes the sample files into a new folder under `parent` and returns their URLs.
    static func write(into parent: URL, bundle: Bundle = .main) throws -> [URL] {
        let folder = parent.appendingPathComponent("DemoSamples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = try bundled.compactMap { sample in
            guard let source = bundle.url(forResource: sample.resource, withExtension: sample.ext) else { return nil }
            let target = folder.appendingPathComponent(sample.importedAs)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
        let pdf = folder.appendingPathComponent("Filter Guide.pdf")
        try makePDF(pages: filterGuidePages).write(to: pdf)
        urls.append(pdf)
        return urls
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
