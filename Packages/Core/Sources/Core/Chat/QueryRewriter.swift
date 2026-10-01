import Foundation
import Ports

/// Turns a follow-up such as "and on the older model?" into a standalone search query.
public struct QueryRewriter: Sendable {
    private let generator: any Generator
    /// Exchanges (a question and its answer) of history given to the model.
    public let historyExchanges: Int

    public init(generator: any Generator, historyExchanges: Int = 3) {
        self.generator = generator
        self.historyExchanges = historyExchanges
    }

    /// Returns `question` unchanged when there is no history, or when the model's rewrite is unusable.
    public func standaloneQuery(for question: String, history: [MessageRecord]) async -> String {
        let turns = history.suffix(historyExchanges * 2).map { (role: $0.role, text: $0.text) }
        guard !turns.isEmpty else { return question }

        let request = GenerationRequest(
            system: PromptBuilder.rewriteSystemPrompt,
            prompt: PromptBuilder.rewritePrompt(question: question, history: turns),
            maxTokens: 64, temperature: 0)
        var output = ""
        do {
            for try await piece in generator.generate(request) { output += piece }
        } catch {
            return question
        }
        return Self.clean(output) ?? question
    }

    /// First line, without wrapping quotes or a leading label; `nil` if nothing usable is left.
    static func clean(_ raw: String) -> String? {
        guard var line = raw.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        for label in ["Standalone query:", "Query:"] where line.lowercased().hasPrefix(label.lowercased()) {
            line = String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ "))
        guard !line.isEmpty, line.count <= 300 else { return nil }
        return line
    }
}
