import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit

/// An image XObject drawn on a PDF page, with where it was drawn.
struct PDFImagePlacement {
    /// Where the image lands on the page, in PDF points with the origin at the bottom left.
    var rect: CGRect
    var stream: CGPDFStreamRef
    /// Size of the stored picture in pixels (not of its place on the page).
    var pixelWidth: Int
    var pixelHeight: Int
    /// Identifies the picture, so one drawn on many pages (a logo) can be told from different photos.
    var digest: String
}

/// Finds the raster images a PDF page draws, by interpreting its content stream: the `q`, `Q` and `cm`
/// operators keep track of the current transformation, and `Do` draws an image or a form (which is entered,
/// because figures are often wrapped in one). Inline images and stencil masks are not photos and are ignored.
final class PDFImageScanner {
    private static let maxDepth = 4
    private static let maxPlacements = 2_000

    private final class Context {
        let owner: PDFImageScanner
        let stream: CGPDFContentStreamRef
        let depth: Int
        var ctm: CGAffineTransform
        var saved: [CGAffineTransform] = []

        init(owner: PDFImageScanner, stream: CGPDFContentStreamRef, depth: Int, ctm: CGAffineTransform) {
            self.owner = owner
            self.stream = stream
            self.depth = depth
            self.ctm = ctm
        }
    }

    private let table: CGPDFOperatorTableRef
    private var found: [PDFImagePlacement] = []

    private init() {
        table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let context = PDFImageScanner.context(info) else { return }
            context.saved.append(context.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let context = PDFImageScanner.context(info), let last = context.saved.popLast() else { return }
            context.ctm = last
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let context = PDFImageScanner.context(info), let matrix = PDFImageScanner.popMatrix(scanner) else { return }
            context.ctm = matrix.concatenating(context.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let context = PDFImageScanner.context(info) else { return }
            context.owner.draw(scanner, in: context)
        }
    }

    deinit { CGPDFOperatorTableRelease(table) }

    /// The images `page` draws, in the order they are drawn.
    static func placements(on page: CGPDFPage) -> [PDFImagePlacement] {
        let scanner = PDFImageScanner()
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        scanner.scan(stream, depth: 0, ctm: .identity)
        return scanner.found
    }

    // MARK: Scanning

    private func scan(_ stream: CGPDFContentStreamRef, depth: Int, ctm: CGAffineTransform) {
        let context = Context(owner: self, stream: stream, depth: depth, ctm: ctm)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(context).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        CGPDFScannerScan(scanner)
        withExtendedLifetime(context) {}
    }

    private func draw(_ scanner: CGPDFScannerRef, in context: Context) {
        var namePointer: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &namePointer), let namePointer,
            let object = CGPDFContentStreamGetResource(context.stream, "XObject", namePointer)
        else { return }
        var xobject: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
            let dictionary = CGPDFStreamGetDictionary(xobject)
        else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }

        switch String(cString: subtype) {
        case "Image":
            guard found.count < Self.maxPlacements else { return }
            var isMask: CGPDFBoolean = 0
            if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isMask), isMask != 0 { return }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
                width > 0, height > 0
            else { return }
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(context.ctm)
            found.append(PDFImagePlacement(
                rect: rect, stream: xobject, pixelWidth: width, pixelHeight: height, digest: Self.digest(of: xobject)))
        case "Form":
            guard context.depth < Self.maxDepth else { return }
            var matrix = CGAffineTransform.identity
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, let parsed = Self.matrix(from: array) {
                matrix = parsed
            }
            var resources: CGPDFDictionaryRef?
            // A form that relies on its parent's resources (legacy files) is not entered.
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return }
            let child = CGPDFContentStreamCreateWithStream(xobject, resources, context.stream)
            defer { CGPDFContentStreamRelease(child) }
            scan(child, depth: context.depth + 1, ctm: matrix.concatenating(context.ctm))
        default:
            break
        }
    }

    // MARK: Operands

    private static func context(_ info: UnsafeMutableRawPointer?) -> Context? {
        info.map { Unmanaged<Context>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Operands are popped last first: f e d c b a.
    private static func popMatrix(_ scanner: CGPDFScannerRef) -> CGAffineTransform? {
        var v: [CGPDFReal] = []
        for _ in 0..<6 {
            var number: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &number) else { return nil }
            v.append(number)
        }
        return CGAffineTransform(a: v[5], b: v[4], c: v[3], d: v[2], tx: v[1], ty: v[0])
    }

    private static func matrix(from array: CGPDFArrayRef) -> CGAffineTransform? {
        guard CGPDFArrayGetCount(array) == 6 else { return nil }
        var v: [CGPDFReal] = []
        for index in 0..<6 {
            var number: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &number) else { return nil }
            v.append(number)
        }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }

    private static func digest(of stream: CGPDFStreamRef) -> String {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return "" }
        return SHA256.hash(data: data as Data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Decoding

    enum Decoded {
        case image(CGImage)
        /// The stored data is unreadable (a corrupt stream): the image is skipped.
        case damaged
        /// A colour format or bit depth this scanner does not decode itself: draw it from the page instead.
        case unsupported
    }

    /// The picture as stored: JPEG and JPEG 2000 streams are decoded by ImageIO, and raw RGB or gray samples
    /// are wrapped directly. A picture never leaves here depending on a decode array, so text recognition, image
    /// features and the stored copy all see the same pixels.
    static func decode(_ stream: CGPDFStreamRef) -> Decoded {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return .damaged }
        switch format {
        case .jpegEncoded, .JPEG2000:
            // ImageIO knows nothing of spot, indexed or Lab colour: it would read the components as gray, RGB or CMYK.
            guard hasPlainColorSpace(stream) else { return .unsupported }
            // The picture stays compressed until it is analyzed, so a manual with hundreds of photos does not hold
            // hundreds of decoded bitmaps. A tiny decode up front is enough to tell that the stream is readable.
            guard let source = CGImageSourceCreateWithData(data, nil), CGImageSourceGetCount(source) > 0,
                CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32] as CFDictionary) != nil,
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return .damaged }
            guard image.decode != nil || pdfDecode(stream) != nil else { return .image(image) }
            // ImageIO inverts CMYK JPEGs that carry an Adobe marker (it gives the image a decode array), but inside a
            // PDF only the image dictionary's /Decode says how samples become colour. Without this, print brochures'
            // CMYK photos come out as negatives. (JPEG 2000 cannot be re-wrapped that way: draw it from the page.)
            guard format == .jpegEncoded else { return .unsupported }
            let components = image.colorSpace?.numberOfComponents ?? 0
            let decode = pdfDecode(stream, components: components) ?? Array(repeating: [CGFloat(0), 1], count: components).flatMap { $0 }
            guard let provider = CGDataProvider(data: data),
                let corrected = CGImage(jpegDataProviderSource: provider, decode: decode, shouldInterpolate: true, intent: .defaultIntent),
                let flat = PlainPixels.flattened(corrected)
            else { return .damaged }
            return .image(flat)
        case .raw:
            guard let layout = rawLayout(stream) else { return .unsupported }
            let decode = pdfDecode(stream, components: layout.components)
            guard let image = rawImage(layout, data: data, decode: decode) else { return .damaged }
            guard decode != nil else { return .image(image) }
            return PlainPixels.flattened(image).map(Decoded.image) ?? .damaged
        @unknown default:
            return .unsupported
        }
    }

    /// Colour spaces whose components ImageIO reads correctly on its own: device, calibrated and ICC-based ones.
    /// A JPEG 2000 stream may leave the colour space to the codestream.
    private static func hasPlainColorSpace(_ stream: CGPDFStreamRef) -> Bool {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return false }
        let plain: Set<String> = ["DeviceGray", "DeviceRGB", "DeviceCMYK", "CalGray", "CalRGB", "ICCBased"]
        var name: UnsafePointer<CChar>?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name { return plain.contains(String(cString: name)) }
        if CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array {
            var kind: UnsafePointer<CChar>?
            return CGPDFArrayGetName(array, 0, &kind) && kind.map { plain.contains(String(cString: $0)) } == true
        }
        var object: CGPDFObjectRef?
        return !CGPDFDictionaryGetObject(dictionary, "ColorSpace", &object)
    }

    /// The image's /Decode array, if it has one with two numbers per colour component.
    private static func pdfDecode(_ stream: CGPDFStreamRef, components: Int? = nil) -> [CGFloat]? {
        var array: CGPDFArrayRef?
        guard let dictionary = CGPDFStreamGetDictionary(stream), CGPDFDictionaryGetArray(dictionary, "Decode", &array), let array
        else { return nil }
        let values: [CGFloat] = (0..<CGPDFArrayGetCount(array)).compactMap { index in
            var number: CGPDFReal = 0
            return CGPDFArrayGetNumber(array, index, &number) ? CGFloat(number) : nil
        }
        guard values.count == CGPDFArrayGetCount(array), values.count.isMultiple(of: 2), !values.isEmpty else { return nil }
        if let components, values.count != 2 * components { return nil }
        return values
    }

    private static func rawLayout(_ stream: CGPDFStreamRef) -> (components: Int, width: Int, height: Int)? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
            CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits), bits == 8
        else { return nil }
        var components = 0
        var name: UnsafePointer<CChar>?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            switch String(cString: name) {
            case "DeviceRGB": components = 3
            case "DeviceGray": components = 1
            default: return nil
            }
        } else if CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array, CGPDFArrayGetCount(array) >= 2 {
            var kind: UnsafePointer<CChar>?
            var profile: CGPDFStreamRef?
            guard CGPDFArrayGetName(array, 0, &kind), let kind, String(cString: kind) == "ICCBased",
                CGPDFArrayGetStream(array, 1, &profile), let profile, let profileDictionary = CGPDFStreamGetDictionary(profile)
            else { return nil }
            var n: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(profileDictionary, "N", &n), n == 1 || n == 3 else { return nil }
            components = n
        } else {
            return nil
        }
        return (components, width, height)
    }

    private static func rawImage(_ layout: (components: Int, width: Int, height: Int), data: CFData, decode: [CGFloat]? = nil) -> CGImage? {
        guard CFDataGetLength(data) >= layout.width * layout.height * layout.components, let provider = CGDataProvider(data: data)
        else { return nil }
        return CGImage(
            width: layout.width, height: layout.height, bitsPerComponent: 8, bitsPerPixel: 8 * layout.components,
            bytesPerRow: layout.width * layout.components,
            space: layout.components == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: decode,
            shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The part of the page under `rect`, drawn as the reader sees it. Used for pictures that are stored in a
    /// form this scanner does not decode.
    static func render(_ rect: CGRect, of page: PDFPage, maxSide: CGFloat = 2048) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        let scale = min(3, maxSide / max(rect.width, rect.height))
        let width = Int((rect.width * scale).rounded(.up)), height = Int((rect.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
