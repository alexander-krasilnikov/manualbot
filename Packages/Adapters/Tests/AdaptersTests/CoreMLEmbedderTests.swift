import Core
import Foundation
import Ports
import Testing
@testable import Adapters

/// Runs against the real EmbeddingGemma files. Point EMBEDDER_MODEL_DIR at a folder containing
/// `encoder.mlmodelc/` and `hf_model/` (for the simulator: TEST_RUNNER_EMBEDDER_MODEL_DIR).
private let modelDir = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_DIR"].map { URL(fileURLWithPath: $0) }

@Suite(.serialized, .enabled(if: modelDir != nil))
struct CoreMLEmbedderTests {
    static let identity = EmbeddingModelIdentity(id: "embeddinggemma-300m", version: "1", dimensions: 768)

    private func make() async throws -> (CoreMLEmbedder, GemmaTokenizer) {
        let dir = try #require(modelDir)
        let tokenizer = try await GemmaTokenizer(folder: dir.appendingPathComponent("hf_model"))
        let embedder = CoreMLEmbedder(modelURL: dir.appendingPathComponent("encoder.mlmodelc"), tokenizer: tokenizer, identity: Self.identity)
        return (embedder, tokenizer)
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    @Test func producesUnitVectorsOfTheDeclaredDimension() async throws {
        let (embedder, _) = try await make()
        let vectors = try await embedder.embed(["hold the button", "replace the filter"], kind: .query)
        #expect(vectors.count == 2)
        for v in vectors {
            #expect(v.count == 768)
            #expect(abs(dot(v, v) - 1) < 1e-4)
        }
        #expect(vectors[0] != vectors[1])
    }

    @Test func isDeterministic() async throws {
        let (embedder, _) = try await make()
        let a = try await embedder.embed(["same text"], kind: .passage(title: "Manual"))
        let b = try await embedder.embed(["same text"], kind: .passage(title: "Manual"))
        #expect(a == b)
    }

    @Test func relevantPassagesAreCloserThanUnrelatedOnes() async throws {
        let (embedder, _) = try await make()
        let query = try await embedder.embed(["how do I reset the unit to factory settings"], kind: .query)[0]
        let passages = try await embedder.embed([
            "To restore factory defaults, hold the power button for ten seconds until the light blinks.",
            "Replace the air filter every six months to keep airflow strong.",
            "The warranty covers manufacturing defects for two years from the purchase date.",
        ], kind: .passage(title: "X200 Manual"))
        let scores = passages.map { dot(query, $0) }
        #expect(scores[0] > scores[1] && scores[0] > scores[2], "scores: \(scores)")
        #expect(scores[0] - max(scores[1], scores[2]) > 0.1, "should be clearly separated: \(scores)")
    }

    @Test func aMiniLibraryRanksTheRightPassageFirstForEachQuestion() async throws {
        let (embedder, _) = try await make()
        let corpus = [
            "Error E-042 means the motor has overheated. Switch the unit off and wait thirty minutes.",
            "To replace the filter, open the rear panel, pull out the old filter and slide in a new one.",
            "Connect the device to Wi-Fi by holding the network button until the light turns blue.",
            "The maximum supported load is 25 kilograms. Never exceed this limit.",
            "Clean the exterior with a soft, slightly damp cloth. Do not use solvents.",
        ]
        let cases = [
            ("what does error E-042 mean", 0), ("how do I change the filter", 1), ("how to connect to wifi", 2),
            ("what weight can it carry", 3), ("how should I clean it", 4),
        ]
        let vectors = try await embedder.embed(corpus, kind: .passage(title: "Guide"))
        for (question, expected) in cases {
            let q = try await embedder.embed([question], kind: .query)[0]
            let best = vectors.indices.max { dot(q, vectors[$0]) < dot(q, vectors[$1]) }
            #expect(best == expected, "“\(question)” ranked passage \(String(describing: best)), wanted \(expected)")
        }
    }

    @Test func veryLongTextIsTruncatedNotRejected() async throws {
        let (embedder, _) = try await make()
        let long = String(repeating: "calibration procedure ", count: 600)
        let v = try await embedder.embed([long], kind: .passage(title: String(repeating: "Very long title ", count: 20)))[0]
        #expect(v.count == 768)
        #expect(abs(dot(v, v) - 1) < 1e-4)
    }

    @Test func unloadingAndReloadingGivesTheSameVectors() async throws {
        let (embedder, _) = try await make()
        let before = try await embedder.embed(["stable"], kind: .query)
        await embedder.unload()
        let after = try await embedder.embed(["stable"], kind: .query)
        #expect(before == after)
    }

    @Test func emptyInputStillEmbeds() async throws {
        let (embedder, _) = try await make()
        #expect(try await embedder.embed([""], kind: .query)[0].count == 768)
        #expect(try await embedder.embed([], kind: .query).isEmpty)
    }

    @Test func promptTemplatesMatchTheModelConfig() {
        #expect(CoreMLEmbedder.prompt(for: "q", kind: .query) == "task: search result | query: q")
        #expect(CoreMLEmbedder.prompt(for: "t", kind: .passage(title: "Manual A")) == "title: Manual A | text: t")
        #expect(CoreMLEmbedder.prompt(for: "t", kind: .passage(title: "  ")) == "title: none | text: t")
        #expect(CoreMLEmbedder.prompt(for: "t", kind: .passage(title: String(repeating: "x", count: 200))).count < 100)
    }

    @Test func tokenCountsMatchTheModelsView() async throws {
        let (_, tokenizer) = try await make()
        #expect(tokenizer.count("hello world") == 2)
        #expect(tokenizer.count(String(repeating: "word ", count: 400)) >= 400)
        #expect(tokenizer.encode(String(repeating: "word ", count: 400), limit: 256).count == 256)
        #expect(tokenizer.encode(String(repeating: "word ", count: 400), limit: 256).last == GemmaTokenizer.eos)
        #expect(tokenizer.encode("short", limit: 256).first == GemmaTokenizer.bos)
    }

    @Test func chunksFromTheEmbeddingGemmaConfigurationFitTheModelInput() async throws {
        let (_, tokenizer) = try await make()
        let text = (0..<200).map { "Step \($0) requires checking valve number \($0) and recording the pressure reading carefully." }.joined(separator: " ")
        let chunks = Chunker(configuration: .embeddingGemma, counter: tokenizer).chunk([Block(text: text, page: 1)])
        #expect(chunks.count > 5)
        for chunk in chunks {
            let prompt = CoreMLEmbedder.prompt(for: chunk.text, kind: .passage(title: String(repeating: "T", count: 60)))
            #expect(tokenizer.encode(prompt, limit: 10_000).count <= CoreMLEmbedder.sequenceLength, "chunk \(chunk.ordinal) would be truncated")
        }
    }
}

/// The whole provisioning-to-embedding path on the real archive: verify, unpack, load, embed.
/// Set EMBEDDER_ZIP to the packaged model archive.
private let embedderZip = ProcessInfo.processInfo.environment["EMBEDDER_ZIP"].map { URL(fileURLWithPath: $0) }

@Suite(.serialized, .enabled(if: embedderZip != nil))
struct EmbedderArchiveInstallTests {
    @Test func installedArchiveLoadsAndEmbeds() async throws {
        let zip = try #require(embedderZip)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)
        let files = FileModelFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("real-embedder-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: files.root) }
        let spec = ModelSpec(id: "embeddinggemma-300m", version: "1", role: .embedder, url: URL(string: "https://example.invalid/e.zip")!,
                             bytes: size.int64Value, sha256: try await files.sha256(of: zip), fileName: "encoder.mlmodelc", packaging: .zip)

        // A copy, because installing consumes the archive.
        let copy = files.root.appendingPathComponent("incoming.zip")
        try FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: zip, to: copy)
        try files.install(copy, for: spec)
        #expect(files.isInstalled(spec))

        let modelURL = files.installedURL(for: spec)
        let tokenizer = try await GemmaTokenizer(folder: modelURL.deletingLastPathComponent().appendingPathComponent("hf_model"))
        let embedder = CoreMLEmbedder(modelURL: modelURL, tokenizer: tokenizer, identity: CoreMLEmbedderTests.identity)
        let v = try await embedder.embed(["installed from the archive"], kind: .query)[0]
        #expect(v.count == 768)
        #expect(abs(v.reduce(0) { $0 + $1 * $1 } - 1) < 1e-3)
    }
}
