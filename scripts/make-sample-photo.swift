// Makes App/Resources/sample-photo.jpg: the Eventing debugger screenshot on page 28 of "Couchbase Under the Hood", as if
// photographed (the page rendered at another scale, cropped with a margin of the page, turned about 2° and warmed).
// It is the demo's sample photo: sent alone, it finds that page. Run from the repository root:
//   swift scripts/make-sample-photo.swift
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

let pdfPath = "App/Resources/DemoSamples/Couchbase Under the Hood.pdf"
let outputPath = "App/Resources/sample-photo.jpg"
let pageNumber = 28

guard let document = CGPDFDocument(URL(fileURLWithPath: pdfPath) as CFURL), let page = document.page(at: pageNumber) else {
    fatalError("cannot open page \(pageNumber) of \(pdfPath)")
}

// Where the page draws its largest image: follow q/Q/cm and take the transformed unit square of each image `Do`.
final class Scan {
    var stack: [CGAffineTransform] = [.identity]
    var largest = CGRect.null
    var imageNames: Set<String> = []
}
let scan = Scan()
if let pageDict = page.dictionary {
    var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
    if CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources), let resources,
       CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects {
        CGPDFDictionaryApplyBlock(xobjects, { key, value, _ in
            var stream: CGPDFStreamRef?, subtype: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(value, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream),
               CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                scan.imageNames.insert(String(cString: key))
            }
            return true
        }, nil)
    }
}
let table = CGPDFOperatorTableCreate()!
CGPDFOperatorTableSetCallback(table, "q") { _, info in
    let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
    scan.stack.append(scan.stack.last!)
}
CGPDFOperatorTableSetCallback(table, "Q") { _, info in
    let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
    if scan.stack.count > 1 { scan.stack.removeLast() }
}
CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
    let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
    var v = [CGPDFReal](repeating: 0, count: 6)
    for i in (0..<6).reversed() { CGPDFScannerPopNumber(scanner, &v[i]) }
    let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    scan.stack[scan.stack.count - 1] = m.concatenating(scan.stack.last!)
}
CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
    let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name, scan.imageNames.contains(String(cString: name)) else { return }
    let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(scan.stack.last!)
    if scan.largest.isNull || rect.width * rect.height > scan.largest.width * scan.largest.height { scan.largest = rect }
}
let content = CGPDFContentStreamCreateWithPage(page)
let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(scan).toOpaque())
CGPDFScannerScan(scanner)
guard !scan.largest.isNull else { fatalError("page \(pageNumber) draws no image") }

// Render the page at 2.4 pixels per point, so the photo does not reuse the stored picture's pixels.
let scale: CGFloat = 2.4
let box = page.getBoxRect(.mediaBox)
let width = Int(box.width * scale), height = Int(box.height * scale)
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.scaleBy(x: scale, y: scale)
context.translateBy(x: -box.minX, y: -box.minY)
context.drawPDFPage(page)
guard let rendered = context.makeImage() else { fatalError("render failed") }

// Crop the figure with a margin of the page around it, then turn, warm and soften it a little. Keep the warming slight:
// the figure is mostly grey and white, and a strong tint changes it more than a photo of a screen would.
let figure = scan.largest.offsetBy(dx: -box.minX, dy: -box.minY)
let margin = figure.width * 0.06
let crop = figure.insetBy(dx: -margin, dy: -margin).applying(CGAffineTransform(scaleX: scale, y: scale))
var image = CIImage(cgImage: rendered).cropped(to: crop)
image = image.transformed(by: CGAffineTransform(translationX: -crop.midX, y: -crop.midY)
    .concatenating(CGAffineTransform(rotationAngle: 2 * .pi / 180)))
image = image.applyingFilter("CITemperatureAndTint", parameters: [
    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6200, y: 0),
])
image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.92, kCIInputBrightnessKey: -0.02])
// Clamp first: a blur samples beyond the edges, and the empty outside would darken the border.
image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8])
// Keep the turned picture's inside, so there are no empty corners.
let inner = CGRect(x: -crop.width * 0.46, y: -crop.height * 0.40, width: crop.width * 0.92, height: crop.height * 0.80)
image = image.cropped(to: inner)
let longest = max(inner.width, inner.height)
if longest > 1600 { image = image.transformed(by: CGAffineTransform(scaleX: 1600 / longest, y: 1600 / longest)) }

// Render to an opaque bitmap and encode it with ImageIO.
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
guard let bitmap = CIContext().createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: sRGB),
      let opaque = CGContext(data: nil, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("render failed") }
opaque.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
let jpeg = NSMutableData()
guard let flat = opaque.makeImage(), let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else {
    fatalError("JPEG encoding failed")
}
CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
guard CGImageDestinationFinalize(destination) else { fatalError("JPEG encoding failed") }
try (jpeg as Data).write(to: URL(fileURLWithPath: outputPath))
print("figure at \(scan.largest.integral) on page \(pageNumber); wrote \(outputPath) (\(jpeg.length / 1024) KB)")
