import Foundation
import Ports
import Testing
@testable import Adapters

/// Photo search latency over a 5,000-image library (spec: p95 <= 300 ms for the photo's feature vector plus the
/// image index search, excluding one-time index training). Slow to seed, so it runs only when RUN_BENCHMARKS is set:
///   RUN_BENCHMARKS=1 swift test --filter ImageBenchmarkTests
///   TEST_RUNNER_RUN_BENCHMARKS=1 xcodebuild test ...   (simulator or device)
///
/// Needs the real model (EMBEDDER_MODEL_PATH): the query photo is embedded by EmbeddingGemma 2 on the GPU, which is most of
/// the time. Measured on a Mac (Apple silicon, debug build, 2026-10-06): 5,000 images, first query (index training)
/// 0.32 s, then p50 203 ms, p95 223 ms, max 237 ms (the earlier Vision feature print: p95 61 ms). About 175 ms of that
/// is embedding the 1024-pixel photo (spike); the index search is a few tens of ms. **Not yet measured on an iPad**:
/// run it on a device before quoting a figure for the target hardware, where the margin to 300 ms may be thinner.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] != nil
    && ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"] != nil))
struct ImageBenchmarkTests {
    @Test func photoSearchP95StaysUnderThreeHundredMillisecondsAt5kImages() async throws {
        let imageCount = 5_000, documents = 50
        let printer = LiteRTEmbedder(modelPath: ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"] ?? "")
        _ = try await printer.embed(["warm up"], kind: .query)   // loading the model is not part of a search
        let f = try RepoFixture(imageFeatures: printer.identity); defer { Task { await f.cleanUp() } }
        var rng = RetrievalBenchmarkTests.SplitMix(state: 7)
        func unitVector() -> [Float] {
            var v = (0..<printer.identity.dimensions).map { _ in Float(Double(rng.next() % 2_000_000) / 1_000_000 - 1) }
            let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            for i in v.indices { v[i] /= norm }
            return v
        }

        let seedStart = ContinuousClock.now
        let copy = Data(repeating: 0xAB, count: 20_000)                       // about the size of a small display copy
        for d in 0..<documents {
            let id = "doc\(d)"
            try await f.repo.upsert(DocumentRecord(id: id, title: "Manual \(d)", type: .pdf))
            try await f.repo.writeImages((0..<(imageCount / documents)).map { n in
                ImageWrite(
                    record: ImageRecord(docId: id, generation: 1, n: n, page: n + 1, width: 640, height: 480, features: unitVector(),
                                        featureModel: printer.identity.tag),
                    displayCopy: copy)
            })
            try await f.repo.activate(generation: 1, for: id)
        }
        let seedTime = ContinuousClock.now - seedStart

        let photo = Fixtures.scene(99, size: 1024)         // a phone-photo-sized query
        let filter = SearchFilter(embeddingModel: printer.identity.tag)

        // The first query pays for index training; it is reported but not part of the p95.
        let warmStart = ContinuousClock.now
        _ = try await f.repo.imageSearch(try await printer.features(of: photo), limit: 10, filter: filter)
        let warmTime = ContinuousClock.now - warmStart

        var timings: [Double] = []
        for i in 0..<100 {
            let scoped = i % 4 == 0 ? SearchFilter(documentIDs: Set((0..<3).map { "doc\($0)" }), embeddingModel: printer.identity.tag) : filter
            let start = ContinuousClock.now
            let vector = try await printer.features(of: photo)
            let hits = try await f.repo.imageSearch(vector, limit: 10, filter: scoped)
            let elapsed = ContinuousClock.now - start
            timings.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            #expect(!hits.isEmpty)
        }
        timings.sort()
        let p50 = timings[timings.count / 2], p95 = timings[Int(Double(timings.count) * 0.95) - 1], worst = timings.last!
        print("IMAGEBENCHMARK embedder=EmbeddingGemma 2 images=\(imageCount) seed=\(seedTime) firstQuery(training)=\(warmTime) p50=\(p50)ms p95=\(p95)ms max=\(worst)ms")
        #expect(p95 <= 300, "p95 was \(p95) ms")
    }
}
