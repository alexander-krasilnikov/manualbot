import Foundation
import Ports
import Synchronization

/// What one question did, end to end: retrieval, the language model, and the checks on the answer.
public struct AnswerEvalResult: Sendable, Equatable {
    public enum Kind: String, Sendable { case single, pairFirst, followUp }

    public var testCase: EvalCase
    public var kind: Kind
    /// The answer text shown to the user (empty for a not-found reply).
    public var answer: String
    /// Whether the reply was the not-found one, from retrieval or from the model.
    public var notFound: Bool
    /// The query the question was searched with (the rewrite, for a follow-up).
    public var searchedFor: String?
    /// The answer states the expected text (ignoring case and spacing).
    public var states: Bool
    /// A cited chunk contains the expected text.
    public var cites: Bool
    /// A question the documents can answer got the not-found reply.
    public var wronglyRefused: Bool
    /// A question the documents cannot answer got a generated answer.
    public var answeredWhenUnanswerable: Bool
    /// The model wrote an answer, but no valid citation remained, so it was replaced by the not-found reply.
    public var groundingFailure: Bool
    /// For a follow-up: the rewritten query retrieved the expected chunk.
    public var followUpHit: Bool?
    public var timeToFirstText: TimeInterval?
    /// Text fragments per second while the answer streamed (about tokens per second).
    public var fragmentsPerSecond: Double?
}

/// The measures of one run (design D11 of litert-embeddinggemma-2), and the rule for choosing between two runs.
public struct AnswerEvalReport: Sendable {
    public var results: [AnswerEvalResult]

    public init(results: [AnswerEvalResult]) { self.results = results }

    public struct Summary: Sendable, Equatable {
        public var answerable = 0, unanswerable = 0
        public var states = 0, cites = 0, wronglyRefused = 0, answeredWhenUnanswerable = 0
        public var groundingFailures = 0
        public var followUps = 0, followUpHits = 0
        public var medianTimeToFirstText: TimeInterval?
        public var medianFragmentsPerSecond: Double?

        public var statesRate: Double { Self.rate(states, answerable) }
        public var citesRate: Double { Self.rate(cites, answerable) }

        static func rate(_ a: Int, _ b: Int) -> Double { b == 0 ? 1 : Double(a) / Double(b) }
    }

    public var summary: Summary {
        var s = Summary()
        for r in results {
            if r.testCase.isAnswerable {
                s.answerable += 1
                if r.states { s.states += 1 }
                if r.cites { s.cites += 1 }
                if r.wronglyRefused { s.wronglyRefused += 1 }
            } else {
                s.unanswerable += 1
                if r.answeredWhenUnanswerable { s.answeredWhenUnanswerable += 1 }
            }
            if r.groundingFailure { s.groundingFailures += 1 }
            if let hit = r.followUpHit { s.followUps += 1; if hit { s.followUpHits += 1 } }
        }
        s.medianTimeToFirstText = Self.median(results.compactMap(\.timeToFirstText))
        s.medianFragmentsPerSecond = Self.median(results.compactMap(\.fragmentsPerSecond))
        return s
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    // MARK: Choosing a language model

    /// The criteria a candidate must meet against the current model, run on the same suite and settings. They were fixed
    /// in design D11 before the candidate was run. Returns what failed; empty means the candidate may replace it.
    public func failedCriteria(comparedWith baseline: AnswerEvalReport) -> [String] {
        let c = summary, b = baseline.summary
        var failed: [String] = []
        if !(c.citesRate >= b.citesRate - 0.05 && c.citesRate >= 0.80) {
            failed.append("1. Cites \(Self.pct(c.citesRate)) is not at least baseline \(Self.pct(b.citesRate)) − 5 points and at least 80%")
        }
        if !(c.statesRate >= b.statesRate - 0.05) {
            failed.append("2. States \(Self.pct(c.statesRate)) is below baseline \(Self.pct(b.statesRate)) − 5 points")
        }
        if !(c.wronglyRefused <= b.wronglyRefused + 1) {
            failed.append("3. Wrongly refused \(c.wronglyRefused) is more than baseline \(b.wronglyRefused) + 1")
        }
        if !(c.answeredWhenUnanswerable <= b.answeredWhenUnanswerable) {
            failed.append("4. Answered when unanswerable \(c.answeredWhenUnanswerable) is more than baseline \(b.answeredWhenUnanswerable)")
        }
        if !(c.groundingFailures <= b.groundingFailures + 1) {
            failed.append("5. Grounding failures \(c.groundingFailures) is more than baseline \(b.groundingFailures) + 1")
        }
        if !(c.followUpHits >= b.followUpHits - 1) {
            failed.append("6. Follow-up hits \(c.followUpHits) is fewer than baseline \(b.followUpHits) − 1")
        }
        return failed
    }

    // MARK: Report

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    public func description(model: String? = nil) -> String {
        let s = summary
        func seconds(_ v: Double?) -> String { v.map { String(format: "%.2f s", $0) } ?? "-" }
        var lines = [model.map { "ANSWEREVAL model: \($0)" }].compactMap { $0 }
        lines += [
            "ANSWEREVAL questions: \(s.answerable) answerable, \(s.unanswerable) unanswerable (\(s.followUps) of them follow-ups)",
            "ANSWEREVAL states the expected fact: \(Self.pct(s.statesRate)) (\(s.states)/\(s.answerable))",
            "ANSWEREVAL cites a chunk containing it: \(Self.pct(s.citesRate)) (\(s.cites)/\(s.answerable))",
            "ANSWEREVAL wrongly refused: \(s.wronglyRefused)/\(s.answerable)",
            "ANSWEREVAL answered when unanswerable: \(s.answeredWhenUnanswerable)/\(s.unanswerable)",
            "ANSWEREVAL grounding failures (answer replaced by not-found): \(s.groundingFailures)",
            "ANSWEREVAL follow-up hits (rewritten query retrieved the expected chunk): \(s.followUpHits)/\(s.followUps)",
            "ANSWEREVAL speed: median time to first text \(seconds(s.medianTimeToFirstText)), "
                + "median \(s.medianFragmentsPerSecond.map { String(format: "%.1f", $0) } ?? "-") text fragments per second",
        ]
        for r in results {
            var problems: [String] = []
            if r.testCase.isAnswerable {
                if r.wronglyRefused { problems.append("wrongly refused") } else {
                    if !r.states { problems.append("does not state it") }
                    if !r.cites { problems.append("does not cite it") }
                }
            } else if r.answeredWhenUnanswerable { problems.append("answered an unanswerable question") }
            if r.groundingFailure { problems.append("grounding failure") }
            if r.followUpHit == false { problems.append("rewrite missed: “\(r.searchedFor ?? "")”") }
            guard !problems.isEmpty else { continue }
            let text = r.notFound ? "(not found)" : r.answer.prefix(110).replacingOccurrences(of: "\n", with: " ")
            lines.append("ANSWEREVAL ✗ [\(r.kind.rawValue)] \(r.testCase.question) — \(problems.joined(separator: "; ")): \(text)")
        }
        return lines.joined(separator: "\n")
    }

    public var description: String { description() }

    /// The same facts as a Markdown report, to keep with the change that chose the language model.
    public func markdown(model: String, settings: String) -> String {
        let s = summary
        func seconds(_ v: Double?) -> String { v.map { String(format: "%.2f s", $0) } ?? "-" }
        var out = """
            # Answer evaluation: \(model)

            Settings: \(settings)

            | Measure | Result |
            |---|---|
            | Questions | \(s.answerable) answerable, \(s.unanswerable) unanswerable (\(s.followUps) follow-ups among them) |
            | States the expected fact | \(Self.pct(s.statesRate)) (\(s.states)/\(s.answerable)) |
            | Cites a chunk containing it | \(Self.pct(s.citesRate)) (\(s.cites)/\(s.answerable)) |
            | Wrongly refused | \(s.wronglyRefused)/\(s.answerable) |
            | Answered when unanswerable | \(s.answeredWhenUnanswerable)/\(s.unanswerable) |
            | Grounding failures | \(s.groundingFailures) |
            | Follow-up hits | \(s.followUpHits)/\(s.followUps) |
            | Median time to first text | \(seconds(s.medianTimeToFirstText)) |
            | Median text fragments per second | \(s.medianFragmentsPerSecond.map { String(format: "%.1f", $0) } ?? "-") |


            """
        out += "## Every question\n\n| Kind | Question | Outcome |\n|---|---|---|\n"
        for r in results {
            let outcome: String
            if r.testCase.isAnswerable {
                outcome = r.wronglyRefused ? "refused" : "\(r.states ? "states" : "no fact"), \(r.cites ? "cites" : "no citation")"
            } else {
                outcome = r.answeredWhenUnanswerable ? "ANSWERED" : "refused (correct)"
            }
            let extras = [r.groundingFailure ? "grounding failure" : nil, r.followUpHit.map { $0 ? "rewrite hit" : "rewrite missed" }]
                .compactMap { $0 }.joined(separator: ", ")
            out += "| \(r.kind.rawValue) | \(r.testCase.question) | \(outcome)\(extras.isEmpty ? "" : "; " + extras) |\n"
        }
        return out
    }
}

/// Runs every question of the suite through the whole chat pipeline with a given language model, on the real retrieval
/// stack, and scores the answers. Each question gets a chat of its own; a follow-up pair shares one.
public struct AnswerEvalRunner: Sendable {
    private let chats: any ChatRepository
    private let retriever: Retriever
    private let generator: any Generator
    private let maxAnswerTokens: Int
    private let temperature: Float

    /// `maxAnswerTokens` and `temperature` default to the app's own settings.
    public init(
        chats: any ChatRepository, retriever: Retriever, generator: any Generator,
        maxAnswerTokens: Int = 512, temperature: Float = 0.2
    ) {
        self.chats = chats
        self.retriever = retriever
        self.generator = generator
        self.maxAnswerTokens = maxAnswerTokens
        self.temperature = temperature
    }

    public func run(_ suite: EvalSuite, progress: (@Sendable (String) -> Void)? = nil) async throws -> AnswerEvalReport {
        let recorder = RecordingGenerator(base: generator)
        let service = ChatService(
            chats: chats, retriever: retriever, generator: recorder, maxAnswerTokens: maxAnswerTokens, temperature: temperature)
        var results: [AnswerEvalResult] = []
        for testCase in suite.cases {
            progress?(testCase.question)
            let chat = try await chats.createChat()
            results.append(try await ask(testCase, kind: .single, in: chat.id, with: service, recorder: recorder))
        }
        for pair in suite.followUps ?? [] {
            let chat = try await chats.createChat()
            progress?(pair.question)
            results.append(try await ask(pair.first, kind: .pairFirst, in: chat.id, with: service, recorder: recorder))
            progress?(pair.followUp.question)
            results.append(try await ask(pair.followUp, kind: .followUp, in: chat.id, with: service, recorder: recorder))
        }
        return AnswerEvalReport(results: results)
    }

    private func ask(
        _ testCase: EvalCase, kind: AnswerEvalResult.Kind, in chatId: String, with service: ChatService, recorder: RecordingGenerator
    ) async throws -> AnswerEvalResult {
        recorder.reset()
        let started = ContinuousClock.now
        var firstText: ContinuousClock.Instant?
        var reply: MessageRecord?
        for try await event in service.ask(testCase.question, in: chatId) {
            switch event {
            case .delta where firstText == nil: firstText = .now
            case .completed(let message): reply = message
            default: break
            }
        }
        guard let reply else { throw AnswerEvalError.noReply(testCase.question) }

        let needle = testCase.contains.map(Self.normalized)
        let states = !reply.notFound && needle.map { Self.normalized(reply.text).contains($0) } == true
        let cites = !reply.notFound && needle.map { needle in
            reply.citations.contains { Self.normalized($0.snippet).contains(needle) && (testCase.doc == nil || $0.docTitle == testCase.doc) }
        } == true
        let answer = recorder.lastAnswer
        let wrote = answer.map { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(PromptBuilder.notFoundMarker) } ?? false

        var hit: Bool?
        if kind == .followUp {
            let standalone = reply.standaloneQuery ?? testCase.question
            hit = try await retrievedExpectedChunk(for: testCase, query: standalone)
        }
        var speed: Double?
        if let answer, answer.fragments > 1, let first = answer.firstAt, let last = answer.lastAt, last > first {
            speed = Double(answer.fragments - 1) / first.duration(to: last).seconds
        }
        return AnswerEvalResult(
            testCase: testCase, kind: kind, answer: reply.notFound ? "" : reply.text, notFound: reply.notFound,
            searchedFor: reply.standaloneQuery, states: states, cites: cites,
            wronglyRefused: testCase.isAnswerable && reply.notFound,
            answeredWhenUnanswerable: !testCase.isAnswerable && !reply.notFound,
            groundingFailure: reply.notFound && wrote, followUpHit: hit,
            timeToFirstText: firstText.map { started.duration(to: $0).seconds }, fragmentsPerSecond: speed)
    }

    private func retrievedExpectedChunk(for testCase: EvalCase, query: String) async throws -> Bool {
        guard let doc = testCase.doc, let needle = testCase.contains.map(Self.normalized) else { return false }
        let retrieval = try await retriever.retrieve(query)
        return retrieval.chunks.contains { $0.documentTitle == doc && Self.normalized($0.chunk.text).contains(needle) }
    }

    /// Lowercase, with every run of whitespace as one space.
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum AnswerEvalError: Error, Equatable, LocalizedError {
    case noReply(String)

    public var errorDescription: String? {
        switch self {
        case .noReply(let question): "The chat produced no reply to “\(question)”."
        }
    }
}

/// Passes requests to the real generator and remembers what the answer step produced (not the query rewrite): its text,
/// how many fragments it had and when the first and last arrived.
private final class RecordingGenerator: Generator, @unchecked Sendable {
    struct Answer {
        var text = ""
        var fragments = 0
        var firstAt: ContinuousClock.Instant?
        var lastAt: ContinuousClock.Instant?
    }

    private let base: any Generator
    private let state = Mutex<Answer?>(nil)

    init(base: any Generator) { self.base = base }

    func reset() { state.withLock { $0 = nil } }
    var lastAnswer: Answer? { state.withLock { $0 } }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<String, Error> {
        // The query rewrite is a short request of its own (64 tokens); only the answer is recorded.
        guard request.maxTokens != 64 else { return base.generate(request) }
        state.withLock { $0 = Answer() }
        let upstream = base.generate(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in upstream {
                        let now = ContinuousClock.now
                        state.withLock { answer in
                            answer?.text += piece
                            answer?.fragments += 1
                            if answer?.firstAt == nil { answer?.firstAt = now }
                            answer?.lastAt = now
                        }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
