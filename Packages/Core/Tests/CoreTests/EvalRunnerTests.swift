import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

@Suite struct EvalRunnerTests {
    private func chunk(_ doc: String, _ text: String) -> Chunk {
        Chunk(docId: doc, generation: 1, ordinal: 0, text: text, embedding: [], embeddingModel: "m")
    }

    private func runner(_ hits: [ScoredChunk], keyword: [ScoredChunk] = []) async throws -> EvalRunner {
        let repo = InMemoryDocumentRepository()
        try await repo.upsert(DocumentRecord(id: "manual", title: "manual", type: .pdf, activeGeneration: 1))
        try await repo.upsert(DocumentRecord(id: "other", title: "other", type: .pdf, activeGeneration: 1))
        return EvalRunner(retriever: Retriever(embedder: FakeEmbedder(), search: FakeChunkSearch(vectorHits: hits, keywordHits: keyword), repository: repo, configuration: .standIn))
    }

    @Test func suiteJSONDecodes() throws {
        let json = #"{"documents":["a.md"],"cases":[{"question":"q?","doc":"a","contains":"x"},{"question":"off topic","doc":null,"contains":null}]}"#
        let suite = try EvalSuite.decode(from: Data(json.utf8))
        #expect(suite.cases.map(\.isAnswerable) == [true, false])
    }

    @Test func scoresRecallAndRefusal() async throws {
        let hit = ScoredChunk(chunk: chunk("manual", "Hold the power button for ten seconds."), score: 0.3)
        let runner = try await runner([hit])
        let suite = EvalSuite(documents: [], cases: [
            EvalCase(question: "how to reset", doc: "manual", contains: "power button"),   // retrieved and relevant
            EvalCase(question: "how to clean", doc: "manual", contains: "cotton swab"),    // relevant but the answer chunk was not retrieved
            EvalCase(question: "poem please", doc: nil, contains: nil),                    // gate lets it through here (distance 0.3)
        ])
        let report = try await runner.run(suite)
        #expect(report.recall == 0.5)
        #expect(report.results[0].hitRank == 1)
        #expect(report.results[1].hitRank == nil)
        #expect(report.answerRate == 1)
        #expect(report.refusalRate == 0, "a close match to an off-topic question is not refused at this distance")
        #expect(report.description.contains("recall@6: 50%"))
        #expect(report.description.contains("answered off-topic"))
    }

    @Test func thresholdSweepFindsTheWorkingRange() async throws {
        // Answerable questions sit near, off-topic ones far: any threshold between works.
        let near = ScoredChunk(chunk: chunk("manual", "answer"), score: 0.5)
        let nearRunner = try await runner([near])
        let far = ScoredChunk(chunk: chunk("manual", "answer"), score: 0.9)
        let farRunner = try await runner([far])
        let a = try await nearRunner.run(EvalSuite(documents: [], cases: [EvalCase(question: "q", doc: "manual", contains: "answer")]))
        let u = try await farRunner.run(EvalSuite(documents: [], cases: [EvalCase(question: "unrelated", doc: nil, contains: nil)]))
        let combined = EvalReport(results: a.results + u.results, resultLimit: 6, threshold: 0.8)

        #expect(combined.answerRate(atThreshold: 0.6) == 1 && combined.refusalRate(atThreshold: 0.6) == 1)
        #expect(combined.answerRate(atThreshold: 0.4) == 0)
        #expect(combined.refusalRate(atThreshold: 0.95) == 0)
        let range = stride(from: 0.3, through: 1.0, by: 0.1).map { $0 }
        let ok = combined.perfectThresholds(in: range)
        #expect(ok.first.map { abs($0 - 0.5) < 1e-9 } == true && ok.last.map { abs($0 - 0.8) < 1e-9 } == true, "\(ok)")
        #expect(combined.description.contains("gap 0.400"))
    }

    @Test func aVerbatimCodePassesTheGateAtAnyThreshold() async throws {
        let far = ScoredChunk(chunk: chunk("manual", "Error E-042 means overheating."), score: 0.99)
        let runner = try await runner([far], keyword: [far])
        let report = try await runner.run(EvalSuite(documents: [], cases: [EvalCase(question: "what is E-042", doc: "manual", contains: "overheating")]))
        #expect(report.results[0].codeMatch)
        #expect(report.results[0].relevant(atThreshold: 0.1))
        #expect(report.answerRate == 1)
    }
}
