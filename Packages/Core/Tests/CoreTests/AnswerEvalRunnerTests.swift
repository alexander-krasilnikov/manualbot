import Foundation
import Ports
import PortsTesting
import Synchronization
import Testing
@testable import Core

/// Embeds nothing real: it only remembers the text it was asked to embed, so the stand-in search can answer by question.
private final class ProbeEmbedder: Embedder, Sendable {
    let identity = EmbeddingModelIdentity(id: "probe", version: "1", dimensions: 4)
    let lastQuery = Mutex("")
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        if case .query = kind, let text = texts.first { lastQuery.withLock { $0 = text } }
        return texts.map { _ in [1, 0, 0, 0] }
    }
}

/// Vector hits chosen by the text of the last query (a substring match), as a library would.
private struct ProbeSearch: ChunkSearching {
    let embedder: ProbeEmbedder
    let table: [(contains: String, hits: [ScoredChunk])]

    func vectorSearch(_ vector: [Float], limit: Int, filter: SearchFilter) async throws -> [ScoredChunk] {
        let query = embedder.lastQuery.withLock { $0 }.lowercased()
        return table.first { query.contains($0.contains.lowercased()) }?.hits ?? []
    }
    func keywordSearch(terms: [String], limit: Int, filter: SearchFilter) async throws -> [ScoredChunk] { [] }
}

@Suite struct AnswerEvalRunnerTests {
    private func chunk(_ ordinal: Int, _ text: String) -> Chunk {
        Chunk(docId: "manual", generation: 1, ordinal: ordinal, page: ordinal + 1, text: text,
              embedding: [1, 0, 0, 0], embeddingModel: "probe@1/4")
    }
    private func hit(_ ordinal: Int, _ text: String, _ distance: Double) -> ScoredChunk { ScoredChunk(chunk: chunk(ordinal, text), score: distance) }

    private let reset = "Hold the power button for ten seconds until the light blinks."
    private let erase = "A reset erases the saved Wi-Fi network and the filter timer."

    /// `answers` maps a passage text in the prompt to the scripted reply; `rewrites` maps a follow-up to its standalone query.
    private func run(
        _ suite: EvalSuite, table: [(contains: String, hits: [ScoredChunk])], answers: [(prompt: String, reply: String)],
        rewrites: [String: String] = [:]
    ) async throws -> AnswerEvalReport {
        let repo = InMemoryDocumentRepository()
        try await repo.upsert(DocumentRecord(id: "manual", title: "manual", type: .pdf, activeGeneration: 1))
        let embedder = ProbeEmbedder()
        let retriever = Retriever(embedder: embedder, search: ProbeSearch(embedder: embedder, table: table), repository: repo)
        let generator = ScriptedGenerator { request in
            if request.maxTokens == 64 {
                let last = request.prompt.components(separatedBy: "Last question: ").last?.components(separatedBy: "\n").first ?? ""
                return [rewrites[last] ?? last]
            }
            let question = request.prompt.components(separatedBy: "Question: ").last ?? ""
            return [answers.first { question.contains($0.prompt) }?.reply ?? PromptBuilder.notFoundMarker]
        }
        return try await AnswerEvalRunner(chats: repo, retriever: retriever, generator: generator).run(suite)
    }

    @Test func eachMeasureIsCountedOnItsOwn() async throws {
        let suite = EvalSuite(documents: [], cases: [
            EvalCase(question: "How do I reset it?", doc: "manual", contains: "hold the power button for ten seconds"),     // states and cites
            EvalCase(question: "Why is the light blinking?", doc: "manual", contains: "hold the power button for ten seconds"), // cites, but does not state it
            EvalCase(question: "What is the part number?", doc: "manual", contains: "PN-7731"),                              // nothing relevant: refused
            EvalCase(question: "How do I clean it?", doc: "manual", contains: "cotton swab"),                                // the model says NOT_FOUND
            EvalCase(question: "Where is the serial number?", doc: "manual", contains: "back of the unit"),                  // the model answers without a citation
            EvalCase(question: "What is the capital of France?", doc: nil, contains: nil),                                   // refused: correct
            EvalCase(question: "Who invented the kettle?", doc: nil, contains: nil),                                         // answered anyway
        ])
        let report = try await run(suite, table: [
            (contains: "reset", hits: [hit(0, reset, 0.1)]),
            (contains: "blinking", hits: [hit(0, reset, 0.1)]),
            (contains: "part number", hits: [hit(1, "Unrelated text.", 0.9)]),
            (contains: "clean", hits: [hit(2, "Wipe the sensor window with a cotton swab.", 0.1)]),
            (contains: "serial", hits: [hit(3, "The serial number is on the back of the unit.", 0.1)]),
            (contains: "kettle", hits: [hit(4, "Kettles are mentioned here.", 0.1)]),
        ], answers: [
            (prompt: "How do I reset it?", reply: "Hold the power button for ten seconds [1]."),
            (prompt: "Why is the light blinking?", reply: "It is blinking because of the reset [1]."),
            (prompt: "Where is the serial number?", reply: "It is at the back of the unit."),   // no [n]: not grounded
            (prompt: "Who invented the kettle?", reply: "Nobody knows [1]."),
        ])

        let byQuestion = Dictionary(uniqueKeysWithValues: report.results.map { ($0.testCase.question, $0) })
        func result(_ q: String) throws -> AnswerEvalResult { try #require(byQuestion[q]) }

        let good = try result("How do I reset it?")
        #expect(good.states && good.cites && !good.wronglyRefused && !good.groundingFailure && !good.notFound)

        let cited = try result("Why is the light blinking?")
        #expect(!cited.states && cited.cites && !cited.wronglyRefused)

        let refused = try result("What is the part number?")
        #expect(refused.wronglyRefused && refused.notFound && !refused.groundingFailure && !refused.states && !refused.cites)

        let modelSaidNo = try result("How do I clean it?")
        #expect(modelSaidNo.wronglyRefused && !modelSaidNo.groundingFailure, "NOT_FOUND from the model is a refusal, not a grounding failure")

        let ungrounded = try result("Where is the serial number?")
        #expect(ungrounded.groundingFailure && ungrounded.wronglyRefused && ungrounded.notFound)

        let correct = try result("What is the capital of France?")
        #expect(!correct.answeredWhenUnanswerable && correct.notFound)
        let wrong = try result("Who invented the kettle?")
        #expect(wrong.answeredWhenUnanswerable && !wrong.notFound)

        let s = report.summary
        #expect(s.answerable == 5 && s.unanswerable == 2)
        #expect(s.states == 1 && s.cites == 2 && s.wronglyRefused == 3)
        #expect(s.answeredWhenUnanswerable == 1 && s.groundingFailures == 1)
        #expect(s.followUps == 0)
        #expect(abs(s.statesRate - 0.2) < 1e-9 && abs(s.citesRate - 0.4) < 1e-9)
    }

    @Test func aFollowUpIsRewrittenAndTheRewriteIsCheckedAgainstTheLibrary() async throws {
        let suite = EvalSuite(documents: [], cases: [], followUps: [
            EvalFollowUp(
                first: EvalCase(question: "How do I reset the X200?", doc: "manual", contains: "ten seconds"),
                followUp: EvalCase(question: "What does that erase?", doc: "manual", contains: "saved wi-fi network")),
            EvalFollowUp(
                first: EvalCase(question: "How do I reset the router?", doc: "manual", contains: "ten seconds"),
                followUp: EvalCase(question: "And what about the filter?", doc: "manual", contains: "saved wi-fi network")),
        ])
        let report = try await run(suite, table: [
            (contains: "reset erase", hits: [hit(1, erase, 0.1)]),          // the good rewrite finds the passage
            (contains: "reset", hits: [hit(0, reset, 0.1)]),
            (contains: "filter", hits: [hit(0, reset, 0.1)]),               // the bad rewrite finds only the wrong one
        ], answers: [
            (prompt: "How do I reset", reply: "Hold the power button for ten seconds [1]."),
            (prompt: "reset erase", reply: "It erases the saved Wi-Fi network [1]."),
        ], rewrites: ["What does that erase?": "What does a reset erase?" , "And what about the filter?": "And what about the filter?"])

        #expect(report.results.map(\.kind) == [.pairFirst, .followUp, .pairFirst, .followUp])
        let followUps = report.results.filter { $0.kind == .followUp }
        #expect(followUps[0].searchedFor == "What does a reset erase?" && followUps[0].followUpHit == true)
        #expect(followUps[1].followUpHit == false)
        #expect(report.results.filter { $0.kind != .followUp }.allSatisfy { $0.followUpHit == nil })
        #expect(report.summary.followUps == 2 && report.summary.followUpHits == 1)
        #expect(followUps[0].states && followUps[0].cites)
    }

    @Test func speedIsMeasuredFromTheStreamedAnswer() async throws {
        let suite = EvalSuite(documents: [], cases: [EvalCase(question: "How do I reset it?", doc: "manual", contains: "ten seconds")])
        let report = try await run(suite, table: [(contains: "reset", hits: [hit(0, reset, 0.1)])],
                                   answers: [(prompt: "reset", reply: "Hold the power button for ten seconds [1].")])
        let r = try #require(report.results.first)
        #expect((r.timeToFirstText ?? -1) >= 0)
        #expect(report.summary.medianTimeToFirstText != nil)
    }

    @Test func aRunsDescriptionNamesEveryMeasureAndEveryProblem() async throws {
        let suite = EvalSuite(documents: [], cases: [
            EvalCase(question: "What is the part number?", doc: "manual", contains: "PN-7731"),
        ])
        let report = try await run(suite, table: [], answers: [])
        let text = report.description(model: "Gemma 4 E4B")
        for line in ["model: Gemma 4 E4B", "states the expected fact", "cites a passage", "wrongly refused: 1/1", "answered when unanswerable",
                     "grounding failures", "follow-up hits", "median time to first text", "wrongly refused: What is the part number?"] {
            #expect(text.contains(line) || text.contains("What is the part number? — wrongly refused"), "missing “\(line)” in:\n\(text)")
        }
        let markdown = report.markdown(model: "Gemma 4 E4B", settings: "temperature 0.2, 512 tokens")
        #expect(markdown.hasPrefix("# Answer evaluation: Gemma 4 E4B") && markdown.contains("| Wrongly refused | 1/1 |"))
    }

    // MARK: The criteria for choosing a model (design D11)

    private func report(
        answerable: Int = 20, states: Int = 18, cites: Int = 18, refused: Int = 0, answeredUnanswerable: Int = 0, grounding: Int = 0,
        followUps: Int = 6, hits: Int = 6
    ) -> AnswerEvalReport {
        var results: [AnswerEvalResult] = []
        for i in 0..<answerable {
            results.append(AnswerEvalResult(
                testCase: EvalCase(question: "q\(i)", doc: "d", contains: "x"), kind: .single, answer: "a", notFound: i < refused,
                searchedFor: nil, states: i < states, cites: i < cites, wronglyRefused: i < refused, answeredWhenUnanswerable: false,
                groundingFailure: i < grounding, followUpHit: i >= answerable - followUps ? (i - (answerable - followUps)) < hits : nil,
                timeToFirstText: 1, fragmentsPerSecond: 10))
        }
        for i in 0..<5 {
            results.append(AnswerEvalResult(
                testCase: EvalCase(question: "u\(i)", doc: nil, contains: nil), kind: .single, answer: "", notFound: i >= answeredUnanswerable,
                searchedFor: nil, states: false, cites: false, wronglyRefused: false, answeredWhenUnanswerable: i < answeredUnanswerable,
                groundingFailure: false, followUpHit: nil, timeToFirstText: nil, fragmentsPerSecond: nil))
        }
        return AnswerEvalReport(results: results)
    }

    @Test func aCandidateAsGoodAsTheBaselineMeetsEveryCriterion() {
        #expect(report().failedCriteria(comparedWith: report()).isEmpty)
        // Within the allowed slack: 5 points of states and cites, one more refusal, one more grounding failure, one fewer hit.
        let slightlyWorse = report(states: 17, cites: 17, refused: 1, grounding: 1, hits: 5)
        #expect(slightlyWorse.failedCriteria(comparedWith: report()).isEmpty, "\(slightlyWorse.failedCriteria(comparedWith: report()))")
    }

    @Test func eachCriterionCanFailOnItsOwn() {
        let baseline = report()
        #expect(report(cites: 16).failedCriteria(comparedWith: baseline).map { $0.prefix(2) } == ["1."], "cites 80% but more than 5 points under 90%")
        #expect(report(states: 16).failedCriteria(comparedWith: baseline).map { $0.prefix(2) } == ["2."])
        #expect(report(refused: 2).failedCriteria(comparedWith: baseline).map { $0.prefix(2) } == ["3."])
        #expect(report(answeredUnanswerable: 1).failedCriteria(comparedWith: baseline).map { $0.prefix(2) } == ["4."])
        #expect(report(grounding: 2).failedCriteria(comparedWith: baseline).map { $0.prefix(2) } == ["5."])
        #expect(report(hits: 4).failedCriteria(comparedWith: baseline).map { $0.prefix(2) } == ["6."])
    }

    @Test func citingLessThanEightyPercentFailsEvenWhenTheBaselineIsNoBetter() {
        let weak = report(cites: 15)   // 75%
        #expect(weak.failedCriteria(comparedWith: weak).map { $0.prefix(2) } == ["1."])
    }
}
