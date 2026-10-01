import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

@Suite(.serialized) struct EvalFixtureTests {
    private let fx = Fixtures()

    @Test func theSuiteIsWellFormed() throws {
        let suite = try EvalCorpus.suite()
        #expect(suite.cases.count >= 30)
        let answerable = suite.cases.filter(\.isAnswerable)
        #expect(answerable.count >= 24 && suite.cases.count - answerable.count >= 5, "needs both answerable and unanswerable questions")
        let stems = Set(suite.documents.map { ($0 as NSString).deletingPathExtension })
        for c in answerable {
            #expect(stems.contains(c.doc!), "unknown document “\(c.doc!)” for: \(c.question)")
            #expect(c.contains?.isEmpty == false, "answerable cases need expected text: \(c.question)")
        }
        #expect(Set(suite.cases.map(\.question)).count == suite.cases.count, "duplicate questions")
        for ext in ["md", "txt", "docx", "pdf"] { #expect(suite.documents.contains { $0.hasSuffix(".\(ext)") }, "no .\(ext) document") }
    }

    @Test func everyDocumentIsExtractableAndContainsItsExpectedAnswers() async throws {
        let suite = try EvalCorpus.suite()
        let urls = try EvalCorpus.build(in: fx, suite: suite)
        let extractor = FileDocumentExtractor()
        var textByDoc: [String: String] = [:]
        for url in urls {
            let doc = try await extractor.extract(from: url) { _ in }
            textByDoc[url.deletingPathExtension().lastPathComponent] = doc.blocks.map(\.text).joined(separator: " ").lowercased()
        }
        #expect(textByDoc.count == suite.documents.count)
        for c in suite.cases where c.isAnswerable {
            let text = try #require(textByDoc[c.doc!])
            #expect(text.contains(c.contains!.lowercased()), "“\(c.contains!)” is not in \(c.doc!) (extracted text may be wrong): \(c.question)")
        }
    }

    @Test func theRunnerScoresTheWholePipelineOnAStandInEmbedder() async throws {
        let suite = try EvalCorpus.suite()
        let urls = try EvalCorpus.build(in: fx, suite: suite)
        let identity = RepoFixture.identity
        let embedder = FakeEmbedder(identity: identity)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CouchbaseDocumentRepository(directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("o"), embedding: identity)
        let ingestion = IngestionService(extractor: FileDocumentExtractor(), embedder: embedder, repository: repo, jobs: repo,
                                         supportedType: FileDocumentExtractor.documentType(for:))
        for url in urls { try await ingestion.enqueue(fileURL: url) }
        await ingestion.run()
        #expect(try await repo.jobs().allSatisfy { $0.state == .ready }, "all documents should index")

        let report = try await EvalRunner(retriever: Retriever(embedder: embedder, search: repo, repository: repo)).run(suite)
        print(report.description)
        #expect(report.results.count == suite.cases.count)
        #expect(report.recall > 0.3, "even a word-hashing stand-in should find many answers; got \(report.recall)")
    }
}

/// Retrieval quality with the real embedding model. Set EMBEDDER_MODEL_DIR.
private let evalModelDir = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_DIR"]

@Suite(.serialized, .enabled(if: evalModelDir != nil))
struct RealEvalTests {
    private let fx = Fixtures()

    private func report(threshold: Double = 0.80, limit: Int = 6) async throws -> EvalReport {
        let dir = URL(fileURLWithPath: try #require(evalModelDir))
        let identity = EmbeddingModelIdentity(id: "embeddinggemma-300m", version: "1", dimensions: 768)
        let tokenizer = try await GemmaTokenizer(folder: dir.appendingPathComponent("hf_model"))
        let embedder = CoreMLEmbedder(modelURL: dir.appendingPathComponent("encoder.mlmodelc"), tokenizer: tokenizer, identity: identity)
        let suite = try EvalCorpus.suite()
        let urls = try EvalCorpus.build(in: fx, suite: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CouchbaseDocumentRepository(directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("o"), embedding: identity)
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: repo, jobs: repo,
            chunker: Chunker(configuration: .embeddingGemma, counter: tokenizer), supportedType: FileDocumentExtractor.documentType(for:))
        for url in urls { try await ingestion.enqueue(fileURL: url) }
        await ingestion.run()
        let jobs = try await repo.jobs()
        #expect(jobs.allSatisfy { $0.state == .ready }, "\(jobs.filter { $0.state != .ready })")
        let retriever = Retriever(embedder: embedder, search: repo, repository: repo,
                                  configuration: RetrievalConfiguration(resultLimit: limit, maxDistance: threshold))
        return try await EvalRunner(retriever: retriever).run(suite)
    }

    @Test func retrievalMeetsTheQualityTargets() async throws {
        let report = try await report()
        print(report.description)
        let range = stride(from: 0.50, through: 1.00, by: 0.02).map { $0 }
        for t in stride(from: 0.60, through: 0.95, by: 0.05) {
            print(String(format: "EVAL sweep threshold %.2f: answers %.0f%%  refuses %.0f%%", t,
                         report.answerRate(atThreshold: t) * 100, report.refusalRate(atThreshold: t) * 100))
        }
        let perfect = report.perfectThresholds(in: range)
        print("EVAL thresholds with 100% answered and 100% refused: \(perfect.map { String(format: "%.2f", $0) })")

        #expect(report.recall >= 0.85, "recall@6 was \(report.recall)")
        #expect(report.answerRate >= 0.9, "too many answerable questions would be refused: \(report.answerRate)")
        #expect(report.refusalRate >= 0.9, "too many off-topic questions would be answered: \(report.refusalRate)")
    }
}

/// Indexing a 300-page PDF with the real embedder: progress must be reported throughout, and memory must stay modest.
@Suite(.serialized, .enabled(if: evalModelDir != nil))
struct LargeDocumentTests {
    private let fx = Fixtures()

    private func peakMemoryMB() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    @Test func aThreeHundredPagePdfIndexesWithVisibleProgress() async throws {
        let dir = URL(fileURLWithPath: try #require(evalModelDir))
        let identity = EmbeddingModelIdentity(id: "embeddinggemma-300m", version: "1", dimensions: 768)
        let tokenizer = try await GemmaTokenizer(folder: dir.appendingPathComponent("hf_model"))
        let embedder = CoreMLEmbedder(modelURL: dir.appendingPathComponent("encoder.mlmodelc"), tokenizer: tokenizer, identity: identity)
        _ = try await embedder.embed(["warm up"], kind: .query)   // exclude the one-time model specialization

        let pages = (1...300).map { page in
            "Page \(page) of the service manual. Section \(page) explains procedure \(page * 7) for unit model K\(page). "
            + "Check valve \(page % 40) and record the pressure reading in the log. Torque the fasteners to \(20 + page % 30) newton metres. "
            + "Inspect the gasket for wear and replace it if the surface is cracked or hardened."
        }
        let pdf = fx.pdf(pages: pages, name: "big.pdf")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CouchbaseDocumentRepository(directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("o"), embedding: identity)
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: repo, jobs: repo,
            chunker: Chunker(configuration: .embeddingGemma, counter: tokenizer), supportedType: FileDocumentExtractor.documentType(for:))

        let updates = await ingestion.updates()
        let id = try await ingestion.enqueue(fileURL: pdf)
        let start = ContinuousClock.now
        await ingestion.run()
        let elapsed = ContinuousClock.now - start

        var embeddingProgress: [Double] = [], states = Set<IngestState>()
        for await job in updates {
            guard job.docId == id else { continue }
            states.insert(job.state)
            if job.state == .embedding { embeddingProgress.append(job.progress) }
            if job.state == .ready { break }
        }
        let chunks = try await repo.activeChunks(docId: id)
        print("LARGE 300 pages -> \(chunks.count) passages in \(elapsed); \(embeddingProgress.count) embedding progress updates; peak memory \(Int(peakMemoryMB())) MB")

        #expect(try await repo.job(docId: id)?.state == .ready)
        #expect(try await repo.document(id: id)?.pageCount == 300)
        #expect(Set(chunks.compactMap(\.page)).count == 300, "every page should yield passages")
        #expect(embeddingProgress.count >= 10, "progress must be visible while indexing, got \(embeddingProgress.count) updates")
        #expect(embeddingProgress == embeddingProgress.sorted())
        #expect(states.isSuperset(of: [.extracting, .embedding, .ready]))
    }
}
