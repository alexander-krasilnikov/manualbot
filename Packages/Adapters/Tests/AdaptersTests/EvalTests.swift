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
        // Follow-up pairs: a question and one that needs it, each with an expected passage. The first question may repeat one
        // of the plain questions (it is asked again at the start of its own chat); the follow-up is its own.
        let pairs = suite.followUps ?? []
        #expect(pairs.count >= 6, "needs at least six follow-up pairs")
        #expect(Set(pairs.map(\.question)).count == pairs.count, "a pair starts with its own question")
        let followUpQuestions = pairs.map(\.followUp.question)
        #expect(Set(followUpQuestions).count == followUpQuestions.count && Set(followUpQuestions).isDisjoint(with: suite.cases.map(\.question)))
        for pair in pairs {
            for c in [pair.first, pair.followUp] {
                #expect(c.isAnswerable && stems.contains(c.doc!) && c.contains?.isEmpty == false, "incomplete pair: \(pair.question)")
            }
        }
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
        let pairCases = (suite.followUps ?? []).flatMap { [$0.first, $0.followUp] }
        for c in suite.cases + pairCases where c.isAnswerable {
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

/// Retrieval quality with the real embedding model. Set EMBEDDER_MODEL_PATH.
private let evalModelPath = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"]

@Suite(.serialized, .enabled(if: evalModelPath != nil))
struct RealEvalTests {
    private let fx = Fixtures()

    private func report(
        threshold: Double = RetrievalConfiguration().maxDistance, limit: Int = 6, chunking: ChunkerConfiguration = .embeddingGemma2
    ) async throws -> EvalReport {
        let embedder = LiteRTEmbedder(modelPath: try #require(evalModelPath))
        let identity = embedder.identity
        let suite = try EvalCorpus.suite()
        let urls = try EvalCorpus.build(in: fx, suite: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-eval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try CouchbaseDocumentRepository(directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("o"), embedding: identity)
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: repo, jobs: repo,
            chunker: Chunker(configuration: chunking), supportedType: FileDocumentExtractor.documentType(for:))
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
        for result in report.results.sorted(by: { ($0.bestDistance ?? 9) < ($1.bestDistance ?? 9) }) {
            let d = result.bestDistance.map { String(format: "%.3f", $0) } ?? "-"
            print("EVAL distance \(d) \(result.testCase.isAnswerable ? "answerable  " : "unanswerable") code=\(result.codeMatch) — \(result.testCase.question)")
        }
        let range = stride(from: 0.15, through: 0.60, by: 0.005).map { $0 }
        for t in stride(from: 0.20, through: 0.50, by: 0.02) {
            print(String(format: "EVAL sweep threshold %.2f: answers %.0f%%  refuses %.0f%%", t,
                         report.answerRate(atThreshold: t) * 100, report.refusalRate(atThreshold: t) * 100))
        }
        let perfect = report.perfectThresholds(in: range)
        print("EVAL thresholds with 100% answered and 100% refused: \(perfect.first.map { String(format: "%.3f", $0) } ?? "none") to \(perfect.last.map { String(format: "%.3f", $0) } ?? "none")")

        let chosen = RetrievalConfiguration().maxDistance
        #expect(report.recall >= 0.85, "recall@6 was \(report.recall)")
        #expect(report.answerRate >= 0.9, "too many answerable questions would be refused at \(chosen): \(report.answerRate)")
        #expect(report.refusalRate >= 0.9, "too many off-topic questions would be answered at \(chosen): \(report.refusalRate)")
    }

    /// How the passage size changes retrieval: recall, and the gap between the worst answerable question and the nearest
    /// off-topic one (the room a threshold has).
    @Test func comparesPassageSizes() async throws {
        let sizes: [(String, ChunkerConfiguration)] = [
            ("target 80 / max 120", ChunkerConfiguration(targetTokens: 80, maxTokens: 120, overlapTokens: 15, minTailTokens: 25)),
            ("target 100 / max 150", ChunkerConfiguration(targetTokens: 100, maxTokens: 150, overlapTokens: 20, minTailTokens: 30)),
            ("target 130 / max 180", ChunkerConfiguration(targetTokens: 130, maxTokens: 180, overlapTokens: 22, minTailTokens: 35)),
            ("target 150 / max 200", ChunkerConfiguration(targetTokens: 150, maxTokens: 200, overlapTokens: 25, minTailTokens: 40)),
            ("target 180 / max 240", ChunkerConfiguration(targetTokens: 180, maxTokens: 240, overlapTokens: 28, minTailTokens: 45)),
            ("target 220 / max 280", ChunkerConfiguration(targetTokens: 220, maxTokens: 280, overlapTokens: 30, minTailTokens: 45)),
            ("target 300 / max 380 (embeddingGemma2)", .embeddingGemma2),
            ("target 400 / max 480", ChunkerConfiguration(targetTokens: 400, maxTokens: 480, overlapTokens: 50, minTailTokens: 70)),
        ]
        for (label, config) in sizes {
            let report = try await report(chunking: config)
            let answerable = report.results.filter { $0.testCase.isAnswerable }.compactMap(\.bestDistance)
            let unanswerable = report.results.filter { !$0.testCase.isAnswerable }.compactMap(\.bestDistance)
            let gap = (unanswerable.min() ?? 0) - (answerable.max() ?? 0)
            print(String(format: "EVAL chunking [%@]: recall@6 %.0f%%, answerable max %.3f, unanswerable min %.3f, gap %.3f",
                         label, report.recall * 100, answerable.max() ?? 0, unanswerable.min() ?? 0, gap))
        }
    }
}

/// Indexing a 300-page PDF with the real embedder: progress must be reported throughout, and memory must stay modest.
@Suite(.serialized, .enabled(if: evalModelPath != nil))
struct LargeDocumentTests {
    private let fx = Fixtures()

    private func peakMemoryMB() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    @Test func aThreeHundredPagePdfIndexesWithVisibleProgress() async throws {
        let embedder = LiteRTEmbedder(modelPath: try #require(evalModelPath))
        let identity = embedder.identity
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
            chunker: Chunker(configuration: .embeddingGemma2), supportedType: FileDocumentExtractor.documentType(for:))

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
