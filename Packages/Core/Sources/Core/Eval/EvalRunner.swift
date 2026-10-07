import Foundation
import Ports

public struct EvalCase: Codable, Sendable, Equatable {
    public var question: String
    /// Title of the document that answers the question; `nil` for questions the documents cannot answer.
    public var doc: String?
    /// Text that a retrieved passage from `doc` must contain (compared ignoring case).
    public var contains: String?

    public var isAnswerable: Bool { doc != nil }

    public init(question: String, doc: String?, contains: String?) {
        self.question = question
        self.doc = doc
        self.contains = contains
    }
}

/// A question followed by one that cannot be understood without it ("And how long do I hold it?"). Both have expected
/// passages. Only the answer evaluation uses these: retrieval alone has no conversation.
public struct EvalFollowUp: Codable, Sendable, Equatable {
    public var question: String
    public var doc: String?
    public var contains: String?
    public var followUp: EvalCase

    public init(first: EvalCase, followUp: EvalCase) {
        question = first.question
        doc = first.doc
        contains = first.contains
        self.followUp = followUp
    }

    public var first: EvalCase { EvalCase(question: question, doc: doc, contains: contains) }
}

public struct EvalSuite: Codable, Sendable, Equatable {
    public var documents: [String]
    public var cases: [EvalCase]
    public var followUps: [EvalFollowUp]?

    public init(documents: [String], cases: [EvalCase], followUps: [EvalFollowUp]? = nil) {
        self.documents = documents
        self.cases = cases
        self.followUps = followUps
    }

    public static func decode(from data: Data) throws -> EvalSuite { try JSONDecoder().decode(EvalSuite.self, from: data) }
}

public struct EvalCaseResult: Sendable, Equatable {
    public var testCase: EvalCase
    public var bestDistance: Double?
    /// Whether the relevance gate passed at the retriever's configured threshold.
    public var relevant: Bool
    /// An identifier in the question appears verbatim in a top passage, which passes the gate at any threshold.
    public var codeMatch: Bool
    /// Position (from 1) of the first passage from the expected document containing the expected text.
    public var hitRank: Int?
    public var topDocuments: [String]

    public var hit: Bool { hitRank != nil }

    public func relevant(atThreshold threshold: Double) -> Bool {
        codeMatch || (bestDistance.map { $0 <= threshold } ?? false)
    }
}

public struct EvalReport: Sendable {
    public var results: [EvalCaseResult]
    public var resultLimit: Int
    public var threshold: Double

    var answerable: [EvalCaseResult] { results.filter { $0.testCase.isAnswerable } }
    var unanswerable: [EvalCaseResult] { results.filter { !$0.testCase.isAnswerable } }

    /// Share of answerable questions whose answer passage is among the returned passages.
    public var recall: Double { Self.ratio(answerable.filter(\.hit).count, answerable.count) }
    /// Share of answerable questions the relevance gate lets through (the rest would be wrongly refused).
    public var answerRate: Double { Self.ratio(answerable.filter(\.relevant).count, answerable.count) }
    /// Share of unanswerable questions the relevance gate refuses.
    public var refusalRate: Double { Self.ratio(unanswerable.filter { !$0.relevant }.count, unanswerable.count) }

    public func answerRate(atThreshold t: Double) -> Double { Self.ratio(answerable.filter { $0.relevant(atThreshold: t) }.count, answerable.count) }
    public func refusalRate(atThreshold t: Double) -> Double { Self.ratio(unanswerable.filter { !$0.relevant(atThreshold: t) }.count, unanswerable.count) }

    /// Thresholds that both let every answerable question through and refuse every unanswerable one, if any.
    public func perfectThresholds(in range: [Double]) -> [Double] {
        range.filter { answerRate(atThreshold: $0) == 1 && refusalRate(atThreshold: $0) == 1 }
    }

    static func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 1 : Double(a) / Double(b) }

    public var description: String {
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
        var lines = [
            "EVAL recall@\(resultLimit): \(pct(recall)) (\(answerable.filter(\.hit).count)/\(answerable.count))",
            "EVAL answered (gate passes answerable): \(pct(answerRate)) at threshold \(threshold)",
            "EVAL refused (gate blocks unanswerable): \(pct(refusalRate)) (\(unanswerable.filter { !$0.relevant }.count)/\(unanswerable.count))",
        ]
        for r in results where (r.testCase.isAnswerable && (!r.hit || !r.relevant)) || (!r.testCase.isAnswerable && r.relevant) {
            let d = r.bestDistance.map { String(format: "%.3f", $0) } ?? "-"
            lines.append("EVAL miss [\(r.testCase.isAnswerable ? (r.hit ? "refused" : "not retrieved") : "answered off-topic")] d=\(d) top=\(r.topDocuments.prefix(3)) — \(r.testCase.question)")
        }
        let a = answerable.compactMap(\.bestDistance), u = unanswerable.compactMap(\.bestDistance)
        if let amax = a.max(), let umin = u.min() {
            lines.append(String(format: "EVAL distances: answerable max %.3f, unanswerable min %.3f (gap %.3f)", amax, umin, umin - amax))
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs a question set through retrieval and scores it.
public struct EvalRunner: Sendable {
    private let retriever: Retriever

    public init(retriever: Retriever) { self.retriever = retriever }

    public func run(_ suite: EvalSuite) async throws -> EvalReport {
        var results: [EvalCaseResult] = []
        for testCase in suite.cases {
            let retrieval = try await retriever.retrieve(testCase.question)
            let terms = QueryTerms.keywords(from: testCase.question)
            let codes = QueryTerms.codes(in: terms)
            let top = retrieval.passages.prefix(retriever.configuration.suggestionCount)
            let codeMatch = !codes.isEmpty && top.contains { p in codes.contains { QueryTerms.contains(p.chunk.text, code: $0) } }

            var hitRank: Int?
            if let doc = testCase.doc, let needle = testCase.contains?.lowercased() {
                hitRank = retrieval.passages.firstIndex { $0.documentTitle == doc && $0.chunk.text.lowercased().contains(needle) }.map { $0 + 1 }
            }
            results.append(EvalCaseResult(
                testCase: testCase, bestDistance: retrieval.bestDistance, relevant: retrieval.relevant, codeMatch: codeMatch,
                hitRank: hitRank, topDocuments: retrieval.passages.map(\.documentTitle)))
        }
        return EvalReport(results: results, resultLimit: retriever.configuration.resultLimit, threshold: retriever.configuration.maxDistance)
    }
}
