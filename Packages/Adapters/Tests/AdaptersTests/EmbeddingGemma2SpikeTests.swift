import CoreGraphics
import Core
import Foundation
import ImageIO
import LiteRTLM
import Ports
import Testing
import UniformTypeIdentifiers
@testable import Adapters

/// Spike for design D2 of litert-embeddinggemma-2: how EmbeddingGemma 2 Text Vision 440M behaves through LiteRT-LM's
/// `EmbeddingEngine`. Run with
/// `RUN_SPIKES=1 EMBEDDER_MODEL_PATH=…/embeddinggemma-2-text-vision-440m.litertlm swift test --filter EmbeddingGemma2SpikeTests`
/// (add `GENERATOR_MODEL_PATH=…/gemma-4-E4B-it.litertlm` for the memory measurement, and `TEST_RUNNER_` prefixes in the
/// iOS Simulator). The `SPIKE` lines it prints are the findings, recorded below and in design D3/D4.
///
/// FINDINGS (LiteRT-LM v0.18.0, macOS 27 on Apple silicon and the iOS Simulator on the same Mac, 2026-10-06):
/// 1. Loading and embedding work on CPU and GPU (Mac) and on CPU in the simulator, for text and for images, with
///    distinct vectors for distinct inputs. The simulator's numbers are identical to the Mac's CPU numbers.
///    Load: CPU about 1 s, GPU about 4.4 s (first use compiles shaders).
/// 2. `EmbeddingOptions(normalize: true, outputSize: 256)` returns 256 floats of unit length. The engine's default
///    is already normalized (768 floats, norm 1.0); `normalize: false` gives norms of about 520. Asking for 256 equals
///    the first 256 values of the 768-dimension vector, renormalized (cosine 1.0), so the output size is a true
///    Matryoshka truncation. The app sets both options explicitly.
/// 3. The Swift API has no tokenizer or token count. Input longer than the largest signature does not get truncated:
///    it throws `INVALID_ARGUMENT … Input sequence length (N) exceeds maximum supported signature length (M)`. The
///    default maximum is 1024 tokens (not 8,192) and `maxInputLength` lowers it. English prose measured at about
///    1.26 tokens per word, so `ApproximateTokenCounter` (1.35 per word) over-counts by about 6%: 400 words, which it
///    counts as 539 tokens, was 503 real tokens including the 7-token prompt, and fit under `maxInputLength` 512.
///    Identifier-heavy text tokenizes much worse (part numbers and codes reached about 4 tokens per word), so the
///    approximation can under-count by a factor of three on such text, and the embedder must shrink and retry.
/// 4. Templates (13 passages of the 6 evaluation documents, 25 answerable questions, recall@6 was 25/25 for every
///    variant): with the documented query `task: search query | text: Q`, passages as `task: search result | text: P`
///    gave MRR 0.908 and a gap of 0.003 between the worst answerable best-distance (0.306) and the nearest
///    unanswerable one (0.309). Adding the title as `task: search result | title: T | text: P` gave MRR 0.933 and a gap
///    of 0.027; the title in the text, `… | text: T. P`, MRR 0.953 and a gap of 0.018; no template, MRR 0.910 and
///    no gap in the right direction. So passages carry their title, and queries use the documented template. The set
///    is small; the full evaluation (task 6.1) can revisit it.
///    Photos (18 drawn scenes, colour x shape, described in words): image alone, with a search-result prefix and
///    with a search-query prefix all matched 18/18 in both directions. Prefixed photos sit nearer to words (own mean
///    0.11 against 0.175) but the gap to other photos is the same (about 0.10), so photos are embedded alone.
///    70 against 140 vision tokens: both 18/18, own mean 0.168 against 0.175, 445 against 954 ms per image on the
///    CPU. The default (140) is kept; 70 can be tried on real photos in task 6.2.
/// 5. Latency (batch of 8 passages of about 300 tokens / one image / one query): GPU 414 / 174 / 22 ms, CPU
///    2,331 / 973 / 74 ms (the simulator matches the CPU). Process footprint with both engines loaded was about
///    1.2 to 1.6 GB (embedder 0.6 to 1.1 GB on its own, as measured in a long-lived test process), the embedder
///    still returned identical vectors while the Gemma 4 E4B engine was resident, and its latency was unchanged
///    (407 ms GPU, 2,393 ms CPU).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_SPIKES"] == "1"
    && ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"] != nil))
struct EmbeddingGemma2SpikeTests {
    static let modelPath = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"] ?? ""

    // MARK: Helpers

    static func engine(
        _ backend: Backend, vision: Backend? = nil, maxInputLength: Int? = nil, visionTokens: Int? = nil
    ) async throws -> EmbeddingEngine {
        let engine = EmbeddingEngine(config: EmbeddingEngineConfig(
            modelPath: modelPath, backend: backend, visionBackend: vision ?? backend,
            cacheDir: NSTemporaryDirectory(), maxInputLength: maxInputLength, visionTokensPerImage: visionTokens))
        try await engine.initialize()
        return engine
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    static func norm(_ a: [Float]) -> Float { dot(a, a).squareRoot() }
    static func unit(_ a: [Float]) -> [Float] { let n = norm(a); return n > 0 ? a.map { $0 / n } : a }

    static func text(_ engine: EmbeddingEngine, _ texts: [String], size: Int? = 256, normalize: Bool? = true) async throws -> [[Float]] {
        let options = EmbeddingOptions(normalize: normalize, outputSize: size)
        return try await engine.computeEmbeddingBatch(contentsBatch: texts.map { [.text($0)] }, options: options).map(\.embedding)
    }

    static func image(_ engine: EmbeddingEngine, _ data: Data, prefix: String? = nil, size: Int? = 256) async throws -> [Float] {
        let contents: [Content] = prefix.map { [.text($0), .imageData(data)] } ?? [.imageData(data)]
        return try await engine.computeEmbedding(contents: contents, options: EmbeddingOptions(normalize: true, outputSize: size)).embedding
    }

    static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    /// A simple drawn scene: a coloured shape on a plain background.
    static let colours: [(name: String, r: CGFloat, g: CGFloat, b: CGFloat)] = [
        ("red", 0.9, 0.1, 0.1), ("blue", 0.1, 0.2, 0.9), ("green", 0.1, 0.7, 0.2), ("yellow", 0.95, 0.85, 0.1),
        ("black", 0.05, 0.05, 0.05), ("orange", 0.95, 0.5, 0.1),
    ]
    static let shapes = ["circle", "square", "triangle"]

    static func picture(colour: Int, shape: String) -> Data {
        let size = 320
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let c = colours[colour]
        context.setFillColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        let rect = CGRect(x: 60, y: 60, width: 200, height: 200)
        switch shape {
        case "circle": context.fillEllipse(in: rect)
        case "square": context.fill(rect)
        default:
            context.move(to: CGPoint(x: 160, y: 260)); context.addLine(to: CGPoint(x: 60, y: 60)); context.addLine(to: CGPoint(x: 260, y: 60))
            context.closePath(); context.fillPath()
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    // MARK: Q1 and Q2: load, embed, output size, normalization (CPU and GPU)

    @Test(arguments: ["cpu", "gpu"])
    func loadsEmbedsAndSizesOutput(backendName: String) async throws {
        #if targetEnvironment(simulator)
        if backendName == "gpu" { return }
        #endif
        let backend: Backend = backendName == "gpu" ? .gpu : .cpu()
        let loadStart = ContinuousClock.now
        let engine = try await Self.engine(backend)
        print("SPIKE[\(backendName)] load \(String(format: "%.0f", Self.ms(ContinuousClock.now - loadStart))) ms, footprint \(Int(Self.residentMB())) MB")

        let texts = ["how do I reset the unit", "replace the filter every six months", "the warranty lasts two years"]
        let firstStart = ContinuousClock.now
        let raw = try await Self.text(engine, texts, size: nil, normalize: nil)
        print("SPIKE[\(backendName)] first text batch \(String(format: "%.0f", Self.ms(ContinuousClock.now - firstStart))) ms; default size \(raw[0].count), norms \(raw.map { String(format: "%.4f", Self.norm($0)) })")
        for (label, size, normalize) in [("size256 normalize=nil", 256, nil), ("size256 normalize=true", 256, true), ("size256 normalize=false", 256, false)] as [(String, Int, Bool?)] {
            let v = try await Self.text(engine, texts, size: size, normalize: normalize)
            print("SPIKE[\(backendName)] \(label): count \(v[0].count), norms \(v.map { String(format: "%.4f", Self.norm($0)) })")
        }
        let v256 = try await Self.text(engine, texts, size: 256, normalize: true)
        #expect(v256.allSatisfy { $0.count == 256 })
        #expect(v256.allSatisfy { abs(Self.norm($0) - 1) < 1e-3 }, "normalize:true should give unit vectors")
        #expect(Self.dot(v256[0], v256[1]) < 0.95, "different texts must give different vectors")
        // Truncating the full vector and renormalizing should match asking for 256 directly (Matryoshka).
        let full = try await Self.text(engine, texts, size: 768, normalize: true)
        let truncated = Self.unit(Array(full[0].prefix(256)))
        print("SPIKE[\(backendName)] cosine(768-truncated-to-256, size256) = \(Self.dot(truncated, v256[0]))")

        let a = Self.picture(colour: 0, shape: "circle"), b = Self.picture(colour: 1, shape: "square")
        let imageStart = ContinuousClock.now
        let ia = try await Self.image(engine, a), ib = try await Self.image(engine, b)
        print("SPIKE[\(backendName)] two images \(String(format: "%.0f", Self.ms(ContinuousClock.now - imageStart))) ms; count \(ia.count), norms \(String(format: "%.4f", Self.norm(ia))); cosine(a,b) \(Self.dot(ia, ib))")
        #expect(ia.count == 256 && ib.count == 256)
        #expect(Self.dot(ia, ib) < 0.99, "different pictures must give different vectors")
        await engine.close()
    }

    // MARK: Q3: no token count in the Swift API, so find where a long passage is cut

    /// Natural English (the evaluation documents, repeated), so the word-to-token ratio is realistic; the first
    /// `words` words, each numbered at the end so no two lengths share a tail.
    static func longText(words: Int) -> String {
        let directory = EvalCorpus.directory
        let source = ["x200-manual.md", "warranty.txt", "bike-repair.md"]
            .compactMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }.joined(separator: " ")
        let base = source.split(whereSeparator: \.isWhitespace).map(String.init)
        return (0..<words).map { base[$0 % base.count] }.joined(separator: " ")
    }

    @Test func findsWhereLongPassagesAreCut() async throws {
        let counter = ApproximateTokenCounter()
        for maxLength in [nil, 256, 512, 1024] as [Int?] {
            let engine = try await Self.engine(.cpu(), maxInputLength: maxLength)
            var previous: [Float]?
            var previousWords = 0
            var line = "SPIKE truncation maxInputLength=\(maxLength.map(String.init) ?? "default"):"
            for words in [60, 100, 150, 200, 250, 300, 400, 500, 650, 800, 1000, 1500] {
                let prompt = "task: search result | text: " + Self.longText(words: words)
                let v: [Float]
                do { v = try await Self.text(engine, [prompt])[0] } catch {
                    line += " \(words)w(~\(counter.count(Self.longText(words: words)))t) ERROR \(String(describing: error).suffix(90));"
                    continue
                }
                if let previous {
                    // 1.0 = the extra words changed nothing: they were beyond the input limit and dropped.
                    line += " \(previousWords)→\(words)w(~\(counter.count(Self.longText(words: words)))t) cos=\(String(format: "%.4f", Self.dot(previous, v)));"
                }
                previous = v
                previousWords = words
            }
            print(line)
            await engine.close()
        }
    }

    // MARK: Q4: prompt variants on the real evaluation documents

    struct Passage { let doc: String; let text: String }

    static func evalPassages(config: ChunkerConfiguration) async throws -> (passages: [Passage], suite: EvalSuite) {
        let fx = Fixtures()
        let suite = try EvalCorpus.suite()
        let urls = try EvalCorpus.build(in: fx, suite: suite)
        let extractor = FileDocumentExtractor()
        let chunker = Chunker(configuration: config)
        var passages: [Passage] = []
        for url in urls {
            let document = try await extractor.extract(from: url) { _ in }
            let stem = url.deletingPathExtension().lastPathComponent
            passages += chunker.chunk(document.blocks).map { Passage(doc: stem, text: $0.text) }
        }
        return (passages, suite)
    }

    static func squash(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    @Test func comparesPassageAndQueryTemplates() async throws {
        let engine = try await Self.engine(.cpu(), maxInputLength: 512)
        let (passages, suite) = try await Self.evalPassages(config: ChunkerConfiguration(targetTokens: 300, maxTokens: 380, overlapTokens: 40, minTailTokens: 60))
        print("SPIKE templates: \(passages.count) passages from \(Set(passages.map(\.doc)).count) documents")
        let variants: [(String, (Passage) -> String)] = [
            ("documented  `task: search result | text: P`", { "task: search result | text: \($0.text)" }),
            ("with title  `task: search result | title: T | text: P`", { "task: search result | title: \($0.doc) | text: \($0.text)" }),
            ("title inline `task: search result | text: T. P`", { "task: search result | text: \($0.doc). \($0.text)" }),
            ("no template  `P`", { $0.text }),
        ]
        let queryTemplates: [(String, (String) -> String)] = [
            ("documented `task: search query | text: Q`", { "task: search query | text: \($0)" }),
            ("no template `Q`", { $0 }),
        ]
        for (queryLabel, queryTemplate) in queryTemplates {
            for (label, template) in variants {
                var vectors: [[Float]] = []
                for start in stride(from: 0, to: passages.count, by: 8) {
                    vectors += try await Self.text(engine, passages[start..<min(start + 8, passages.count)].map(template))
                }
                var hits = 0, reciprocal = 0.0, answerable = 0
                var bestDistances: [(answerable: Bool, distance: Float)] = []
                for c in suite.cases {
                    let q = try await Self.text(engine, [queryTemplate(c.question)])[0]
                    let ranked = vectors.indices.sorted { Self.dot(q, vectors[$0]) > Self.dot(q, vectors[$1]) }
                    bestDistances.append((c.isAnswerable, 1 - Self.dot(q, vectors[ranked[0]])))
                    guard c.isAnswerable, let expected = c.contains.map(Self.squash) else { continue }
                    answerable += 1
                    if let rank = ranked.firstIndex(where: { Self.squash(passages[$0].text).contains(expected) }) {
                        if rank < 6 { hits += 1 }
                        reciprocal += 1 / Double(rank + 1)
                    }
                }
                let yes = bestDistances.filter(\.answerable).map(\.distance), no = bestDistances.filter { !$0.answerable }.map(\.distance)
                print("SPIKE templates [\(queryLabel)] [\(label)]: recall@6 \(hits)/\(answerable), MRR \(String(format: "%.3f", reciprocal / Double(answerable))); best distance answerable max \(String(format: "%.3f", yes.max() ?? 0)) / unanswerable min \(String(format: "%.3f", no.min() ?? 0))")
            }
        }
        await engine.close()
    }

    // MARK: Q4: how to embed a photo

    @Test func comparesPhotoTreatments() async throws {
        let engine = try await Self.engine(.cpu())
        var scenes: [(colour: Int, shape: String, data: Data)] = []
        for colour in Self.colours.indices { for shape in Self.shapes { scenes.append((colour, shape, Self.picture(colour: colour, shape: shape))) } }
        let descriptions = scenes.map { "a \(Self.colours[$0.colour].name) \($0.shape)" }
        let prefixes: [(String, String?)] = [
            ("image alone", nil), ("with `task: search result | text: `", "task: search result | text: "),
            ("with `task: search query | text: `", "task: search query | text: "),
        ]
        let queryVectors = try await Self.text(engine, descriptions.map { "task: search query | text: \($0)" })
        let documentVectors = try await Self.text(engine, descriptions.map { "task: search result | text: \($0)" })
        for (label, prefix) in prefixes {
            var imageVectors: [[Float]] = []
            for scene in scenes { imageVectors.append(try await Self.image(engine, scene.data, prefix: prefix)) }
            var wordsToPhoto = 0, photoToWords = 0, photoToPhoto = 0
            var matched: [Float] = [], unmatched: [Float] = []
            for i in scenes.indices {
                let byWords = imageVectors.indices.max { Self.dot(queryVectors[i], imageVectors[$0]) < Self.dot(queryVectors[i], imageVectors[$1]) }
                if byWords == i { wordsToPhoto += 1 }
                let byPhoto = documentVectors.indices.max { Self.dot(imageVectors[i], documentVectors[$0]) < Self.dot(imageVectors[i], documentVectors[$1]) }
                if byPhoto == i { photoToWords += 1 }
                let nearest = imageVectors.indices.filter { $0 != i }.max { Self.dot(imageVectors[i], imageVectors[$0]) < Self.dot(imageVectors[i], imageVectors[$1]) }
                if let nearest, scenes[nearest].colour == scenes[i].colour || scenes[nearest].shape == scenes[i].shape { photoToPhoto += 1 }
                matched.append(1 - Self.dot(queryVectors[i], imageVectors[i]))
                unmatched += imageVectors.indices.filter { $0 != i }.map { 1 - Self.dot(queryVectors[i], imageVectors[$0]) }
            }
            print("SPIKE photos [\(label)]: words→photo top-1 \(wordsToPhoto)/\(scenes.count), photo→words top-1 \(photoToWords)/\(scenes.count), nearest photo shares colour or shape \(photoToPhoto)/\(scenes.count); words→photo distance own mean \(String(format: "%.3f", matched.reduce(0, +) / Float(matched.count))) (max \(String(format: "%.3f", matched.max() ?? 0))) vs other min \(String(format: "%.3f", unmatched.min() ?? 0)) mean \(String(format: "%.3f", unmatched.reduce(0, +) / Float(unmatched.count)))")
        }
        // Same scenes with 70 and 140 vision soft tokens per image (the two documented choices).
        await engine.close()
        for tokens in [70, 140] {
            let e = try await Self.engine(.cpu(), visionTokens: tokens)
            let q = try await Self.text(e, descriptions.map { "task: search query | text: \($0)" })
            var imageVectors: [[Float]] = []
            let start = ContinuousClock.now
            for scene in scenes { imageVectors.append(try await Self.image(e, scene.data)) }
            let per = Self.ms(ContinuousClock.now - start) / Double(scenes.count)
            var top1 = 0, own: [Float] = [], other: [Float] = []
            for i in scenes.indices {
                if imageVectors.indices.max(by: { Self.dot(q[i], imageVectors[$0]) < Self.dot(q[i], imageVectors[$1]) }) == i { top1 += 1 }
                own.append(1 - Self.dot(q[i], imageVectors[i]))
                other += imageVectors.indices.filter { $0 != i }.map { 1 - Self.dot(q[i], imageVectors[$0]) }
            }
            print("SPIKE photos visionTokens=\(tokens): words→photo top-1 \(top1)/\(scenes.count), own distance mean \(String(format: "%.3f", own.reduce(0, +) / Float(own.count))) max \(String(format: "%.3f", own.max() ?? 0)), other min \(String(format: "%.3f", other.min() ?? 0)); \(String(format: "%.0f", per)) ms per image")
            await e.close()
        }
    }

    // MARK: Q5: latency and memory, alongside a loaded Gemma 4 engine

    @Test func measuresLatencyAndMemoryNextToTheGenerator() async throws {
        let passages = (0..<16).map { "task: search result | text: " + Self.longText(words: 220 + $0) }
        let png = Self.picture(colour: 2, shape: "triangle")
        for (name, backend) in [("cpu", Backend.cpu()), ("gpu", Backend.gpu)] {
            #if targetEnvironment(simulator)
            if name == "gpu" { continue }
            #endif
            let engine = try await Self.engine(backend, maxInputLength: 512)
            _ = try await Self.text(engine, ["warm up"]); _ = try await Self.image(engine, png)
            let batchStart = ContinuousClock.now
            _ = try await Self.text(engine, Array(passages.prefix(8)))
            let batch = Self.ms(ContinuousClock.now - batchStart)
            let imageStart = ContinuousClock.now
            for _ in 0..<5 { _ = try await Self.image(engine, png) }
            let image = Self.ms(ContinuousClock.now - imageStart) / 5
            let queryStart = ContinuousClock.now
            for _ in 0..<5 { _ = try await Self.text(engine, ["task: search query | text: how do I reset the unit"]) }
            let query = Self.ms(ContinuousClock.now - queryStart) / 5
            print("SPIKE latency[\(name)]: batch of 8 passages (~300 tokens) \(String(format: "%.0f", batch)) ms, one image \(String(format: "%.0f", image)) ms, one query \(String(format: "%.0f", query)) ms, footprint \(Int(Self.residentMB())) MB")

            if let generatorPath = ProcessInfo.processInfo.environment["GENERATOR_MODEL_PATH"] {
                let before = Self.residentMB()
                let generator = LiteRTGenerator(modelPath: generatorPath)
                var answer = ""
                for try await piece in generator.generate(GenerationRequest(system: "Be terse.", prompt: "Name two colours.", maxTokens: 16, temperature: 0, stop: [])) { answer += piece }
                let both = Self.residentMB()
                // The embedder must still work, and give the same vectors, with the generator resident.
                let again = try await Self.text(engine, [passages[0]])[0]
                let reference = try await Self.text(engine, [passages[0]])[0]
                print("SPIKE memory[\(name)]: embedder alone \(Int(before)) MB, with generator loaded \(Int(both)) MB; generator said “\(answer.prefix(40))”; embedder still consistent: cos \(Self.dot(again, reference))")
                let afterStart = ContinuousClock.now
                _ = try await Self.text(engine, Array(passages.prefix(8)))
                print("SPIKE latency[\(name)] with generator loaded: batch of 8 \(String(format: "%.0f", Self.ms(ContinuousClock.now - afterStart))) ms")
                await generator.unload()
            }
            await engine.close()
        }
    }
}
