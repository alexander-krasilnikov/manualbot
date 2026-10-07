import Core
import Foundation
import Ports
import Testing
@testable import Adapters

/// The answer evaluation (design D11 of litert-embeddinggemma-2): every question of the evaluation suite, and its follow-up
/// pairs, through the whole chat pipeline with a real language model on the real retrieval stack, scored on what the answer
/// says and cites. Slow, and it needs both models:
///
///     EMBEDDER_MODEL_PATH=…/embeddinggemma-2-text-vision-440m.litertlm \
///     GENERATOR_MODEL_PATH=…/gemma-4-E2B-it.litertlm \
///     ANSWER_EVAL_REPORT=…/answer-eval-e2b.md swift test --filter AnswerEvalTests
///
/// `ANSWER_EVAL_MODEL` names the model in the report (default: the file name). The sampler seed is fixed, so a run repeats.
///
/// To choose between two language models, set `ANSWER_EVAL_BASELINE_MODEL_PATH` (the current one) as well: the baseline
/// runs first, then the candidate in `GENERATOR_MODEL_PATH`, on the same suite and settings, and the test prints which of
/// the criteria of design D11 the candidate fails (none means it may replace the baseline). `ANSWER_EVAL_BASELINE_MODEL`
/// and `ANSWER_EVAL_BASELINE_REPORT` name and save the baseline's report.
private let embedderPath = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"]
private let generatorPath = ProcessInfo.processInfo.environment["GENERATOR_MODEL_PATH"]

@Suite(.serialized, .enabled(if: embedderPath != nil && generatorPath != nil))
struct AnswerEvalTests {
    private let fx = Fixtures()

    /// A library of the evaluation documents, indexed with the real embedder, to run language models against.
    private struct Library {
        let repo: CouchbaseDocumentRepository
        let retriever: Retriever
        let suite: EvalSuite
        let root: URL
    }

    private func makeLibrary(embedder: LiteRTEmbedder) async throws -> Library {
        let suite = try EvalCorpus.suite()
        let urls = try EvalCorpus.build(in: fx, suite: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("answer-eval-\(UUID().uuidString)")
        let repo = try CouchbaseDocumentRepository(
            directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("o"), embedding: embedder.identity)
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: repo, jobs: repo,
            chunker: Chunker(configuration: .embeddingGemma2), supportedType: FileDocumentExtractor.documentType(for:))
        for url in urls { try await ingestion.enqueue(fileURL: url) }
        await ingestion.run()
        #expect(try await repo.jobs().allSatisfy { $0.state == .ready })
        return Library(repo: repo, retriever: Retriever(embedder: embedder, search: repo, repository: repo), suite: suite, root: root)
    }

    private static let settings = "temperature 0.2, at most 512 answer tokens, top-k 40, top-p 0.95, sampler seed 0, GPU; "
        + "retrieval with EmbeddingGemma 2 (256 dimensions, passages of about 130 tokens, relevance threshold 0.28, six passages)"

    private func evaluate(modelPath: String, name: String, reportPath: String?, in library: Library) async throws -> AnswerEvalReport {
        let generator = LiteRTGenerator(modelPath: modelPath, seed: 0)
        // Load the model before the first question, so its time to first text is not the model's load time.
        for try await _ in generator.generate(GenerationRequest(system: "Be terse.", prompt: "Say ok.", maxTokens: 4, temperature: 0)) {}
        let report = try await AnswerEvalRunner(chats: library.repo, retriever: library.retriever, generator: generator)
            .run(library.suite) { print("ANSWEREVAL [\(name)] asking: \($0)") }
        print(report.description(model: name))
        if let reportPath { try report.markdown(model: name, settings: Self.settings).write(toFile: reportPath, atomically: true, encoding: .utf8) }
        await generator.unload()
        return report
    }

    @Test func theChosenLanguageModelAnswersTheEvaluationQuestions() async throws {
        let env = ProcessInfo.processInfo.environment
        let embedder = LiteRTEmbedder(modelPath: try #require(embedderPath))
        let library = try await makeLibrary(embedder: embedder)
        defer { try? FileManager.default.removeItem(at: library.root) }

        var baseline: AnswerEvalReport?
        if let baselinePath = env["ANSWER_EVAL_BASELINE_MODEL_PATH"] {
            baseline = try await evaluate(
                modelPath: baselinePath, name: env["ANSWER_EVAL_BASELINE_MODEL"] ?? URL(fileURLWithPath: baselinePath).lastPathComponent,
                reportPath: env["ANSWER_EVAL_BASELINE_REPORT"], in: library)
        }
        let path = try #require(generatorPath)
        let name = env["ANSWER_EVAL_MODEL"] ?? URL(fileURLWithPath: path).lastPathComponent
        let report = try await evaluate(modelPath: path, name: name, reportPath: env["ANSWER_EVAL_REPORT"], in: library)

        let summary = report.summary
        #expect(summary.answerable == 25 + 12 && summary.unanswerable == 6, "the whole suite ran: \(summary)")
        #expect(summary.followUps == 6)
        if let baseline {
            let failed = report.failedCriteria(comparedWith: baseline)
            print("ANSWEREVAL decision for \(name) against the baseline: \(failed.isEmpty ? "ADOPT, every criterion is met" : "KEEP THE BASELINE")")
            for criterion in failed { print("ANSWEREVAL criterion failed: \(criterion)") }
        }
    }
}
