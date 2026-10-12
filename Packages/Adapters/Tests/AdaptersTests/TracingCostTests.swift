import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// The app now traces every operation. Importing the sample documents and asking the evaluation questions with the
/// tracer on must cost about the same as with none, on the real database with fake models.
@Suite(.serialized) struct TracingCostTests {
    private let fx = Fixtures()
    private static let documents = ["x200-manual.md", "warranty.txt", "bike-repair.md"]

    private func time(tracer: any Tracer) async throws -> (importing: Duration, asking: Duration) {
        let files = try Self.documents.map {
            fx.write(try Data(contentsOf: EvalCorpus.directory.appendingPathComponent($0)), as: $0)
        }
        let questions = try EvalCorpus.suite().cases.map(\.question)
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        let embedder = FakeEmbedder(identity: RepoFixture.identity)
        let ingestion = IngestionService(
            extractor: FileDocumentExtractor(), embedder: embedder, repository: f.repo, jobs: f.repo,
            chunker: Chunker(), supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer)
        let clock = ContinuousClock()
        let importing = try await clock.measure {
            for file in files { _ = try await ingestion.enqueue(fileURL: file) }
            await ingestion.run()
        }
        let retriever = Retriever(embedder: embedder, search: f.repo, repository: f.repo, tracer: tracer)
        let asking = try await clock.measure {
            for question in questions { _ = try await retriever.retrieve(question) }
        }
        return (importing, asking)
    }

    private func median(_ values: [Duration]) -> Double { values.map(\.seconds).sorted()[values.count / 2] }

    @Test func tracingCostsAboutNothing() async throws {
        let rounds = 7
        var plain: [(importing: Duration, asking: Duration)] = []
        var traced: [(importing: Duration, asking: Duration)] = []
        _ = try await time(tracer: NoTracer())   // warm up
        for _ in 0..<rounds {
            plain.append(try await time(tracer: NoTracer()))
            traced.append(try await time(tracer: RecordingTracer()))
        }
        let (importOff, importOn) = (median(plain.map(\.importing)), median(traced.map(\.importing)))
        let (askOff, askOn) = (median(plain.map(\.asking)), median(traced.map(\.asking)))
        print(String(format: "TRACING COST import: off %.3f s, on %.3f s; ask: off %.3f s, on %.3f s", importOff, importOn, askOff, askOn))
        // Loose, because the machine is noisy: tracing must not double either, or add more than 50 ms.
        #expect(importOn < importOff * 2 + 0.05)
        #expect(askOn < askOff * 2 + 0.05)
    }
}
