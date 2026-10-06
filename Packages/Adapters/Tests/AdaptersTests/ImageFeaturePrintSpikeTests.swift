import CoreGraphics
import CouchbaseLiteSwift
import Foundation
import Testing
import Vision
@testable import Adapters

/// Spike for design D1/D6 of image-import-and-search: how Vision's feature print behaves as a vector in
/// Couchbase Lite. Run with `RUN_SPIKES=1 swift test --filter ImageFeaturePrintSpikeTests`.
///
/// Findings (macOS 27, Vision feature print revision 2, Couchbase Lite 4.1.2, synthetic scenes):
/// - The feature print is 768 floats (`elementType == .float`, 3,072 bytes), so `dimensions` is read from the
///   observation, never hard-coded.
/// - L2-normalized cosine distance gives the same top-3 order as `computeDistance` (20/20 queries), so vectors are
///   normalized before storing and the index uses the cosine metric (D1).
/// - A re-shot (shifted, zoomed, dimmer) scene was the top-1 match in 20/20 cases.
/// - `images_vec` was created and used by the query plan at 10, 100 and 1,000 rows, with 8 and 16 centroids, and
///   returned the stored image as top-1 for every probe. Latency was about 1.5 ms (10 and 100 rows) and 5.5 ms
///   (1,000 rows), with no meaningful difference between 8 and 16 centroids. So: 8 centroids, and no brute-force
///   fallback below a row count (D6 risk did not materialize). The spike creates the index after loading rows; the
///   app creates it on an empty collection at launch, as `chunks_vec` already does, so tests for task 3.3 repeat
///   the check in that order.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_SPIKES"] == "1"))
struct ImageFeaturePrintSpikeTests {
    // MARK: Synthetic photos

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

    static func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return try #require(request.results?.first)
    }

    static func floats(_ observation: VNFeaturePrintObservation) -> [Float] {
        observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
        Double(1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 })
    }

    // MARK: Format and ranking

    @Test func featurePrintFormatAndRankOrder() throws {
        let observations = try (0..<20).map { try Self.featurePrint(Self.scene(UInt64($0 + 1))) }
        let first = observations[0]
        print("SPIKE featureprint revision=\(VNGenerateImageFeaturePrintRequest.currentRevision) "
            + "elementCount=\(first.elementCount) elementType=\(first.elementType.rawValue) bytes=\(first.data.count)")
        #expect(first.elementType == .float)
        let vectors = observations.map { Self.normalized(Self.floats($0)) }

        var agreeing = 0
        var checked = 0
        for q in 0..<observations.count {
            let others = (0..<observations.count).filter { $0 != q }
            func order(_ d: (Int) -> Double) -> [Int] { others.sorted { d($0) < d($1) } }
            var visionDistance: (Int) -> Double = { _ in 0 }
            visionDistance = { i in
                var out: Float = 0
                try? observations[q].computeDistance(&out, to: observations[i])
                return Double(out)
            }
            let byVision = order(visionDistance)
            let byCosine = order { Self.cosineDistance(vectors[q], vectors[$0]) }
            checked += 1
            if Array(byVision.prefix(3)) == Array(byCosine.prefix(3)) { agreeing += 1 }
        }
        print("SPIKE top-3 order agrees between computeDistance and normalized cosine for \(agreeing)/\(checked) queries")
        #expect(agreeing >= checked * 9 / 10)
    }

    @Test func variantOfSameSceneIsNearerThanOtherScenes() throws {
        let library = try (0..<20).map { Self.normalized(Self.floats(try Self.featurePrint(Self.scene(UInt64($0 + 1))))) }
        var hits = 0
        for scene in 0..<20 {
            let query = Self.normalized(Self.floats(try Self.featurePrint(Self.scene(UInt64(scene + 1), variant: 2))))
            let best = library.indices.min { Self.cosineDistance(query, library[$0]) < Self.cosineDistance(query, library[$1]) }
            if best == scene { hits += 1 }
        }
        print("SPIKE re-shot scene found as top-1 in \(hits)/20 cases")
        #expect(hits >= 16)
    }

    // MARK: Couchbase Lite index behaviour

    @Test(arguments: [10, 100, 1_000], [8, 16])
    func vectorIndexAnswersAtLibrarySize(rows: Int, centroids: Int) throws {
        try CouchbaseBootstrap.enableVectorSearch()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cbl-img-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = DatabaseConfiguration()
        config.directory = dir.path
        let db = try Database(name: "spike", config: config)
        defer { try? db.close() }
        let images = try db.createCollection(name: "images", scope: "manualbot")

        var vectors: [[Float]] = []
        for i in 0..<rows { vectors.append(Self.normalized(Self.floats(try Self.featurePrint(Self.scene(UInt64(i + 1), size: 160))))) }
        let dimensions = vectors[0].count
        try db.inBatch {
            for (i, vector) in vectors.enumerated() {
                let doc = MutableDocument(id: "d:1:img:\(i)")
                doc.setValue(vector, forKey: "features")
                try images.save(document: doc)
            }
        }

        var index = VectorIndexConfiguration(expression: "features", dimensions: UInt32(dimensions), centroids: UInt32(centroids))
        index.metric = .cosine
        index.encoding = .scalarQuantizer(type: .SQ8)
        var created = true
        do { try images.createIndex(withName: "images_vec", config: index) } catch { created = false }

        let sql = """
            SELECT meta().id AS id, APPROX_VECTOR_DISTANCE(features, $vector, "cosine") AS dist
            FROM manualbot.images
            ORDER BY APPROX_VECTOR_DISTANCE(features, $vector, "cosine")
            LIMIT 5
            """
        let query = try db.createQuery(sql)
        var correct = 0
        var returned = 0
        let probes = Array(0..<min(rows, 20))
        let started = ContinuousClock.now
        for i in probes {
            query.parameters = Parameters().setValue(vectors[i], forName: "vector")
            let result = try query.execute().allResults()
            returned += result.count
            if result.first?.string(forKey: "id") == "d:1:img:\(i)" { correct += 1 }
        }
        let millis = started.duration(to: .now) / .milliseconds(1) / Double(probes.count)
        let plan = try query.explain()
        print("SPIKE rows=\(rows) centroids=\(centroids) indexCreated=\(created) usesIndex=\(plan.contains("images_vec")) "
            + "top1Self=\(correct)/\(probes.count) avgRowsReturned=\(Double(returned) / Double(probes.count)) avgMs=\(millis)")
        #expect(correct >= probes.count * 9 / 10)
    }
}
