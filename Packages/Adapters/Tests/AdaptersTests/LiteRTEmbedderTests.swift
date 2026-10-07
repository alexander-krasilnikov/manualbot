import CoreGraphics
import Core
import Foundation
import ImageIO
import LiteRTLM
import Ports
import Testing
@testable import Adapters

/// Runs against the real EmbeddingGemma 2 file. Set EMBEDDER_MODEL_PATH to `embeddinggemma-2-text-vision-440m.litertlm`
/// (for the simulator: TEST_RUNNER_EMBEDDER_MODEL_PATH).
private let modelPath = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"]

/// Pure helpers: no model needed.
struct LiteRTEmbedderHelperTests {
    @Test func identityNamesTheModelAndTheVectorSize() {
        #expect(LiteRTEmbedder.modelIdentity.tag == "embeddinggemma-2-text-vision-440m@1/256")
    }

    @Test func queriesAndPassagesUseTheDocumentedTemplates() {
        #expect(LiteRTEmbedder.prompt(for: "  how do I reset it \n", kind: .query) == "task: search query | text: how do I reset it")
        #expect(LiteRTEmbedder.prompt(for: "Hold the button.", kind: .passage(title: " X200 Manual "))
            == "task: search result | title: X200 Manual | text: Hold the button.")
        #expect(LiteRTEmbedder.prompt(for: "Hold the button.", kind: .passage(title: "  "))
            == "task: search result | text: Hold the button.")
    }

    @Test func aLongTitleIsCut() {
        let prompt = LiteRTEmbedder.prompt(for: "x", kind: .passage(title: String(repeating: "T", count: 200)))
        #expect(prompt == "task: search result | title: \(String(repeating: "T", count: 60)) | text: x")
    }

    @Test func shrinkingKeepsFourFifthsOfTheWordsAndEventuallyGivesUp() {
        #expect(LiteRTEmbedder.shrunk("a b c d e f g h i j") == "a b c d e f g h")
        #expect(LiteRTEmbedder.shrunk("one two") == "one")
        #expect(LiteRTEmbedder.shrunk("abcdefghij") == "abcdefgh")   // no spaces: by characters
        #expect(LiteRTEmbedder.shrunk("a") == nil)
        var text = String(repeating: "word ", count: 500), steps = 0
        while let shorter = LiteRTEmbedder.shrunk(text) { text = shorter; steps += 1; if steps > 100 { break } }
        #expect(steps <= 100, "must terminate")
    }

    @Test func onlyTheLengthErrorTriggersAShrink() {
        struct Failure: Error, CustomStringConvertible { let description: String }
        #expect(LiteRTEmbedder.isTooLong(Failure(description: "INVALID_ARGUMENT: Input sequence length (1099) exceeds maximum supported signature length (1024).")))
        #expect(!LiteRTEmbedder.isTooLong(Failure(description: "INTERNAL: out of memory")))
    }

    @Test func aMissingModelFileIsReported() async {
        let embedder = LiteRTEmbedder(modelPath: "/nonexistent/model.litertlm")
        await #expect(throws: LiteRTEmbedderError.modelMissing("/nonexistent/model.litertlm")) { _ = try await embedder.embed(["x"], kind: .query) }
        await #expect(throws: LiteRTEmbedderError.modelMissing("/nonexistent/model.litertlm")) { _ = try await embedder.features(of: Fixtures.picture(width: 8, height: 8)) }
    }

    @Test func nothingToEmbedNeedsNoModel() async throws {
        #expect(try await LiteRTEmbedder(modelPath: "/nonexistent").embed([], kind: .query).isEmpty)
    }

    @Test func largePhotosAreScaledDownAndSmallOnesKept() throws {
        func size(of data: Data) throws -> (Int, Int) {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
        let big = try size(of: LiteRTEmbedder.encoded(Fixtures.picture(width: 4000, height: 3000)))
        #expect(big == (1024, 768))
        let small = try size(of: LiteRTEmbedder.encoded(Fixtures.picture(width: 300, height: 200)))
        #expect(small == (300, 200))
    }
}

@Suite(.serialized, .enabled(if: modelPath != nil))
struct LiteRTEmbedderTests {
    private static let embedder = LiteRTEmbedder(modelPath: modelPath ?? "")

    private func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    /// A coloured shape on a plain background, drawn so no image files are needed.
    static func scene(red: CGFloat, green: CGFloat, blue: CGFloat, shape: String) -> CGImage {
        let size = 320
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        let rect = CGRect(x: 60, y: 60, width: 200, height: 200)
        if shape == "circle" {
            context.fillEllipse(in: rect)
        } else {
            context.fill(rect)
        }
        return context.makeImage()!
    }

    @Test func producesUnitVectorsOfTheDeclaredDimension() async throws {
        let vectors = try await Self.embedder.embed(["hold the button", "replace the filter"], kind: .query)
        #expect(vectors.count == 2)
        for v in vectors {
            #expect(v.count == 256)
            #expect(abs(dot(v, v) - 1) < 1e-3)
        }
        #expect(vectors[0] != vectors[1])
    }

    @Test func isDeterministic() async throws {
        let a = try await Self.embedder.embed(["same text"], kind: .passage(title: "Manual"))
        let b = try await Self.embedder.embed(["same text"], kind: .passage(title: "Manual"))
        #expect(a == b)
    }

    @Test func paraphrasesAreNearerThanUnrelatedText() async throws {
        let query = try await Self.embedder.embed(["how do I reset the unit to factory settings"], kind: .query)[0]
        let passages = try await Self.embedder.embed([
            "To restore factory defaults, hold the power button for ten seconds until the light blinks.",
            "Replace the air filter every six months to keep airflow strong.",
            "The warranty covers manufacturing defects for two years from the purchase date.",
        ], kind: .passage(title: "X200 Manual"))
        let scores = passages.map { dot(query, $0) }
        #expect(scores[0] > scores[1] && scores[0] > scores[2], "scores: \(scores)")
        #expect(scores[0] - max(scores[1], scores[2]) > 0.1, "should be clearly separated: \(scores)")
    }

    @Test func aBatchGivesTheSameVectorsAsOneAtATime() async throws {
        let texts = (0..<11).map { "Passage number \($0) about valve \($0 * 3) and the pressure gauge." }
        let batch = try await Self.embedder.embed(texts, kind: .passage(title: "Manual"))
        #expect(batch.count == 11, "more than one native batch")
        for i in [0, 8, 10] {
            let single = try await Self.embedder.embed([texts[i]], kind: .passage(title: "Manual"))[0]
            #expect(dot(batch[i], single) > 0.999, "text \(i) differs between batch and single")
        }
    }

    @Test func aPhotoIsNearerToItsOwnDescriptionThanToAnUnrelatedOne() async throws {
        let redCircle = try await Self.embedder.features(of: Self.scene(red: 0.9, green: 0.1, blue: 0.1, shape: "circle"))
        let descriptions = try await Self.embedder.embed(["a red circle", "a blue square"], kind: .passage(title: ""))
        #expect(redCircle.count == 256 && abs(dot(redCircle, redCircle) - 1) < 1e-3)
        #expect(dot(redCircle, descriptions[0]) > dot(redCircle, descriptions[1]) + 0.05,
                "own \(dot(redCircle, descriptions[0])) vs other \(dot(redCircle, descriptions[1]))")
        let asked = try await Self.embedder.embed(["a red circle"], kind: .query)[0]
        #expect(dot(redCircle, asked) > 0.5, "words and photo should share the vector space: \(dot(redCircle, asked))")
    }

    @Test func differentPhotosGiveDifferentVectors() async throws {
        let a = try await Self.embedder.features(of: Self.scene(red: 0.9, green: 0.1, blue: 0.1, shape: "circle"))
        let b = try await Self.embedder.features(of: Self.scene(red: 0.1, green: 0.2, blue: 0.9, shape: "square"))
        #expect(dot(a, b) < 0.95, "similarity \(dot(a, b))")
        let again = try await Self.embedder.features(of: Self.scene(red: 0.9, green: 0.1, blue: 0.1, shape: "circle"))
        #expect(dot(a, again) > 0.999)
    }

    @Test func aPassageLongerThanTheInputLimitIsEmbeddedFromItsStartNotRejected() async throws {
        // About 4 tokens per word: far more than 512 tokens, which the engine would reject outright.
        let codes = (0..<400).map { "PN-\($0 * 7919 % 9973)/X\($0)" }.joined(separator: " ")
        let long = try await Self.embedder.embed([codes], kind: .passage(title: "Parts list"))[0]
        #expect(long.count == 256)
        // It still works next to ordinary passages in the same batch.
        let mixed = try await Self.embedder.embed(["short passage", codes, "another short passage"], kind: .passage(title: "Parts list"))
        #expect(mixed.count == 3 && mixed.allSatisfy { $0.count == 256 })
        #expect(dot(mixed[0], mixed[2]) < 0.9999)
    }

    /// The engine rejects input beyond its limit instead of truncating, so embedding every passage of the evaluation
    /// documents straight through the engine (no shrink-and-retry) proves none is cut, including the longest.
    @Test func noPassageOfTheEvaluationDocumentsExceedsTheInputLimit() async throws {
        let suite = try EvalCorpus.suite()
        let fx = Fixtures()   // removes its files when released, so keep it for the whole test
        let urls = try EvalCorpus.build(in: fx, suite: suite)
        let extractor = FileDocumentExtractor()
        let chunker = Chunker(configuration: .embeddingGemma2)
        var prompts: [String] = []
        for url in urls {
            let document = try await extractor.extract(from: url) { _ in }
            let title = url.deletingPathExtension().lastPathComponent
            prompts += chunker.chunk(document.blocks).map { LiteRTEmbedder.prompt(for: $0.text, kind: .passage(title: title)) }
        }
        #expect(prompts.count >= 6)
        let engine = EmbeddingEngine(config: EmbeddingEngineConfig(
            modelPath: try #require(modelPath), backend: .cpu(), cacheDir: NSTemporaryDirectory(), maxInputLength: LiteRTEmbedder.maxInputLength))
        try await engine.initialize()
        for prompt in prompts {
            _ = try await engine.computeEmbedding(contents: [.text(prompt)], options: EmbeddingOptions(normalize: true, outputSize: 256))
        }
        await engine.close()
        withExtendedLifetime(fx) {}
    }

    @Test func canBeUnloadedAndStillWorks() async throws {
        let before = try await Self.embedder.embed(["same text"], kind: .query)[0]
        await Self.embedder.unload()
        let after = try await Self.embedder.embed(["same text"], kind: .query)[0]
        #expect(dot(before, after) > 0.999)
    }
}
