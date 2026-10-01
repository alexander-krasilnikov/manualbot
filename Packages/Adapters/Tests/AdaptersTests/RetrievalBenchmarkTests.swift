import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// Retrieval latency over a 20,000-passage library (spec: p95 <= 500 ms, excluding one-time index training).
/// Slow to seed, so it runs only when RUN_BENCHMARKS is set:
///   RUN_BENCHMARKS=1 swift test --filter RetrievalBenchmarkTests
///   TEST_RUNNER_RUN_BENCHMARKS=1 xcodebuild test ...   (simulator or device)
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_BENCHMARKS"] != nil))
struct RetrievalBenchmarkTests {
    /// Small deterministic generator so every run measures the same corpus.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    @Test func retrievalP95StaysUnderHalfASecondAt20kPassages() async throws {
        let passageCount = 20_000, documents = 40
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let embedder = FakeEmbedder(identity: RepoFixture.identity)  // 768 dimensions, hashed bag-of-words
        var rng = SplitMix(state: 42)
        let vocabulary = (0..<3_000).map { "term\($0)" } + (0..<20).map { "PN-\(7000 + $0)" }

        // Seed
        let seedStart = ContinuousClock.now
        for d in 0..<documents {
            let id = "doc\(d)"
            try await f.repo.upsert(DocumentRecord(id: id, title: "Manual \(d)", type: .pdf))
            var batch: [Chunk] = []
            let texts = (0..<(passageCount / documents)).map { _ in
                (0..<60).map { _ in vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
            }
            let vectors = try await embedder.embed(texts, kind: .passage(title: id))
            for (i, text) in texts.enumerated() {
                batch.append(Chunk(docId: id, generation: 1, ordinal: i, page: i / 4 + 1, text: text,
                                   embedding: vectors[i], embeddingModel: embedder.identity.tag))
            }
            try await f.repo.writeChunks(batch)
            try await f.repo.activate(generation: 1, for: id)
        }
        let seedTime = ContinuousClock.now - seedStart

        let retriever = Retriever(embedder: embedder, search: f.repo, repository: f.repo)
        func question() -> String {
            (0..<6).map { _ in vocabulary.randomElement(using: &rng)! }.joined(separator: " ")
        }

        // The first query pays for index training; it is reported but not part of the p95.
        let warmStart = ContinuousClock.now
        _ = try await retriever.retrieve(question())
        let warmTime = ContinuousClock.now - warmStart

        var timings: [Double] = []
        for i in 0..<100 {
            let scope: Set<String>? = i % 4 == 0 ? Set((0..<3).map { "doc\($0)" }) : nil  // a quarter are scoped
            let q = question()
            let start = ContinuousClock.now
            let result = try await retriever.retrieve(q, scope: scope)
            timings.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15
                + Double((ContinuousClock.now - start).components.seconds) * 1000)
            #expect(result.passages.count <= 6)
        }
        timings.sort()
        let p50 = timings[timings.count / 2], p95 = timings[Int(Double(timings.count) * 0.95) - 1], worst = timings.last!
        print("BENCHMARK passages=\(passageCount) seed=\(seedTime) firstQuery(training)=\(warmTime) p50=\(p50)ms p95=\(p95)ms max=\(worst)ms")
        #expect(p95 <= 500, "p95 was \(p95) ms")
    }
}
