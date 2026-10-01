import Foundation
import Ports

/// Builds the strict, passage-only prompt and the follow-up rewrite prompt.
public enum PromptBuilder {
    /// The model replies with exactly this when the passages do not contain the answer.
    public static let notFoundMarker = "NOT_FOUND"

    public static let answerSystemPrompt = """
        You answer questions using ONLY the numbered passages provided in the user message.
        Rules:
        1. Use only facts stated in the passages. Never use outside knowledge.
        2. After every sentence that states a fact, cite the passage or passages it came from, like [1] or [1][3].
        3. If the passages do not contain the answer, reply with exactly: \(notFoundMarker)
        4. Be concise. Quote exact values, part numbers and steps as written.
        """

    public static let rewriteSystemPrompt = """
        Rewrite the user's last question as one standalone search query that makes sense without the conversation. \
        Resolve pronouns and references using the conversation. Output only the query, nothing else.
        """

    /// The passages, numbered from 1 in the given order, followed by the question.
    public static func answerPrompt(question: String, passages: [RetrievedPassage]) -> String {
        var lines = ["Passages:"]
        for (index, passage) in passages.enumerated() {
            lines.append("[\(index + 1)] (\(label(for: passage))) \(passage.chunk.text)")
        }
        lines.append("")
        lines.append("Question: \(question)")
        return lines.joined(separator: "\n")
    }

    /// `Manual A, page 42, section “Reset”`
    static func label(for passage: RetrievedPassage) -> String {
        var parts = [passage.documentTitle]
        if let page = passage.chunk.page { parts.append("page \(page)") }
        if let heading = passage.chunk.heading, !heading.isEmpty { parts.append("section “\(heading)”") }
        return parts.joined(separator: ", ")
    }

    /// `history` is oldest first. Long assistant answers are shortened; the rewrite only needs the topic.
    public static func rewritePrompt(question: String, history: [(role: MessageRole, text: String)]) -> String {
        var lines = ["Conversation:"]
        for turn in history {
            let text = turn.text.count > 300 ? String(turn.text.prefix(300)) + "…" : turn.text
            lines.append("\(turn.role == .user ? "User" : "Assistant"): \(text)")
        }
        lines.append("")
        lines.append("Last question: \(question)")
        lines.append("")
        lines.append("Standalone query:")
        return lines.joined(separator: "\n")
    }
}
