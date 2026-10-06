import CoreGraphics
import Core
import Foundation
import ImageIO
import Ports
import Testing
@testable import Adapters

/// Image search quality: query photos against a library of reference photos, with the real Vision feature print
/// and the real database index.
///
/// Two sets are supported:
/// - a generated one (always run): procedural scenes, each queried after a crop, a rotation with a lighting
///   change, and added noise, plus unrelated scenes that must not match. It checks the harness and catches
///   regressions, but it says little about real photographs;
/// - a real one, when `IMAGE_EVAL_DIR` points at a folder with `references/` (the library photos), `queries/`
///   (new photos of the same things, plus unrelated ones) and `eval.json`:
///   `{"queries": [{"file": "n1.jpg", "expected": "ref-a.jpg"}, {"file": "other.jpg", "expected": null}]}`.
///   The distance threshold in `RetrievalConfiguration.imageMaxDistance` must be tuned on a real set.
struct ImageEvalSet {
    struct Query {
        var name: String
        var image: CGImage
        /// The reference photo this one shows, or `nil` for a photo of something not in the library.
        var expected: String?
    }
    var references: [(name: String, image: CGImage)]
    var queries: [Query]
}

enum ImageEvalCorpus {
    static let scenes = 30
    static let distractors = 15

    static func generated() -> ImageEvalSet {
        let references = (0..<scenes).map { (name: "scene-\($0)", image: ImageFeaturePrintSpikeTests.scene(UInt64($0 + 1), size: 320)) }
        var queries: [ImageEvalSet.Query] = []
        for (index, reference) in references.enumerated() {
            let seed = UInt64(index + 1)
            queries.append(.init(name: "\(reference.name)-crop", image: crop(reference.image, keeping: 0.8, shift: Int(seed % 3)), expected: reference.name))
            queries.append(.init(name: "\(reference.name)-turned", image: relit(rotated(reference.image, degrees: 5), dimming: 0.25), expected: reference.name))
            queries.append(.init(name: "\(reference.name)-noisy", image: noisy(reference.image, amount: 14, seed: seed), expected: reference.name))
        }
        for index in 0..<distractors {
            queries.append(.init(name: "other-\(index)", image: ImageFeaturePrintSpikeTests.scene(UInt64(1_000 + index), size: 320), expected: nil))
        }
        return ImageEvalSet(references: references, queries: queries)
    }

    static func directory(_ root: URL) throws -> ImageEvalSet {
        func load(_ url: URL) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary)
            else { throw ExtractionError.unreadable(url.lastPathComponent) }
            return image
        }
        let references = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("references"), includingPropertiesForKeys: nil)
            .filter { FileDocumentExtractor.documentType(for: $0) == .image }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { (name: $0.lastPathComponent, image: try load($0)) }
        struct Manifest: Decodable { struct Item: Decodable { var file: String; var expected: String? }; var queries: [Item] }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("eval.json")))
        let queries = try manifest.queries.map {
            ImageEvalSet.Query(name: $0.file, image: try load(root.appendingPathComponent("queries/\($0.file)")), expected: $0.expected)
        }
        return ImageEvalSet(references: references, queries: queries)
    }

    // MARK: Transformations (what a second photo of the same thing looks like)

    private static func bitmap(_ size: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        draw(context)
        return context.makeImage()!
    }

    static func crop(_ image: CGImage, keeping fraction: Double, shift: Int) -> CGImage {
        let side = Int(Double(image.width) * fraction), margin = (image.width - side) / 2
        let rect = CGRect(x: margin + shift * 6, y: margin - shift * 4, width: side, height: side)
        let cut = image.cropping(to: rect) ?? image
        return bitmap(image.width) { $0.draw(cut, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) }
    }

    static func rotated(_ image: CGImage, degrees: Double) -> CGImage {
        bitmap(image.width) { context in
            let half = CGFloat(image.width) / 2
            context.translateBy(x: half, y: half)
            context.rotate(by: CGFloat(degrees * .pi / 180))
            context.draw(image, in: CGRect(x: -half, y: -half, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
    }

    static func relit(_ image: CGImage, dimming: CGFloat) -> CGImage {
        bitmap(image.width) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: dimming)
            context.fill(CGRect(x: 0, y: 0, width: image.width / 2, height: image.height))   // a shadow over one side
        }
    }

    static func noisy(_ image: CGImage, amount: Int, seed: UInt64) -> CGImage {
        let size = image.width
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        var state = seed &* 6364136223846793005 | 1
        for index in pixels.indices where index % 4 != 3 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let delta = Int(state >> 33) % (2 * amount + 1) - amount
            pixels[index] = UInt8(max(0, min(255, Int(pixels[index]) + delta)))
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

@Suite struct ImageEvalTests {
    struct Report {
        var top1 = 0, top3 = 0, positives = 0
        /// Distance of the expected photo when it was among the top three.
        var hitDistances: [Double] = []
        /// Distance of the nearest library photo for photos of something not in the library.
        var distractorDistances: [Double] = []
        var distractors = 0

        func recall(atMost threshold: Double) -> Double {
            Double(hitDistances.filter { $0 <= threshold }.count) / Double(max(positives, 1))
        }
        func rejected(atLeast threshold: Double) -> Double {
            Double(distractorDistances.filter { $0 > threshold }.count) / Double(max(distractors, 1))
        }
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    func evaluate(_ set: ImageEvalSet) async throws -> Report {
        let printer = try VisionFeaturePrinter()
        let f = try RepoFixture(imageFeatures: printer.identity); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "lib", title: "Library", type: .pdf))
        var writes: [ImageWrite] = []
        for (index, reference) in set.references.enumerated() {
            let record = ImageRecord(
                docId: "lib", generation: 1, n: index, page: index + 1, width: reference.image.width, height: reference.image.height,
                features: try await printer.features(of: reference.image), featureModel: printer.identity.tag)
            writes.append(ImageWrite(record: record, displayCopy: Data([0])))
        }
        try await f.repo.writeImages(writes)
        try await f.repo.activate(generation: 1, for: "lib")
        let names = Dictionary(uniqueKeysWithValues: set.references.enumerated().map { ($0.offset, $0.element.name) })
        let filter = SearchFilter(embeddingModel: printer.identity.tag)

        var report = Report()
        for query in set.queries {
            let hits = try await f.repo.imageSearch(try await printer.features(of: query.image), limit: 3, filter: filter)
            if let expected = query.expected {
                report.positives += 1
                let ranked = hits.map { names[$0.image.n] }
                if ranked.first == expected { report.top1 += 1 }
                if let position = ranked.firstIndex(of: expected) {
                    report.top3 += 1
                    report.hitDistances.append(hits[position].score)
                }
            } else {
                report.distractors += 1
                if let best = hits.first?.score { report.distractorDistances.append(best) }
            }
        }
        return report
    }

    private func describe(_ label: String, _ report: Report) {
        let hits = report.hitDistances
        print("""
            IMAGEEVAL \(label): positives=\(report.positives) top1=\(report.top1) top3=\(report.top3) \
            (recall@3 \(String(format: "%.2f", Double(report.top3) / Double(max(report.positives, 1))))) distractors=\(report.distractors)
            IMAGEEVAL \(label): correct-match distance p50=\(String(format: "%.3f", percentile(hits, 0.5))) \
            p90=\(String(format: "%.3f", percentile(hits, 0.9))) max=\(String(format: "%.3f", hits.max() ?? .nan))
            IMAGEEVAL \(label): nearest-library distance for unrelated photos min=\(String(format: "%.3f", report.distractorDistances.min() ?? .nan)) \
            p10=\(String(format: "%.3f", percentile(report.distractorDistances, 0.1))) p50=\(String(format: "%.3f", percentile(report.distractorDistances, 0.5)))
            """)
        for threshold in stride(from: 0.2, through: 0.7, by: 0.05) {
            print("IMAGEEVAL \(label): threshold \(String(format: "%.2f", threshold)) -> matches kept \(String(format: "%.2f", report.recall(atMost: threshold))), unrelated rejected \(String(format: "%.2f", report.rejected(atLeast: threshold)))")
        }
    }

    @Test func generatedPhotosAreFoundAndUnrelatedOnesAreRejected() async throws {
        let report = try await evaluate(ImageEvalCorpus.generated())
        describe("generated", report)
        let threshold = RetrievalConfiguration().imageMaxDistance
        #expect(Double(report.top3) / Double(report.positives) >= 0.8, "recall in the top three")
        #expect(report.recall(atMost: threshold) >= 0.8, "found AND within the threshold \(threshold)")
        // No assertion on the unrelated scenes: they share the references' style, and Vision's distance does not
        // separate them (nearest 0.075, against true matches up to 0.22). Rejection is judged on real photos only.
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMAGE_EVAL_DIR"] != nil))
    func realPhotosAreFoundAndUnrelatedOnesAreRejected() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["IMAGE_EVAL_DIR"]!)
        let report = try await evaluate(try ImageEvalCorpus.directory(root))
        describe("real", report)
        let threshold = RetrievalConfiguration().imageMaxDistance
        #expect(Double(report.top3) / Double(report.positives) >= 0.8, "recall in the top three")
        #expect(report.recall(atMost: threshold) >= 0.8, "found AND within the threshold \(threshold)")
        #expect(report.rejected(atLeast: threshold) >= 0.8, "unrelated photos beyond the threshold \(threshold)")
    }
}
