import Foundation
import Ports

/// Builds the strict, chunk-only prompt and the follow-up rewrite prompt.
public enum PromptBuilder {
    /// The model replies with exactly this when the chunks do not contain the answer.
    public static let notFoundMarker = "NOT_FOUND"

    public static let answerSystemPrompt = """
        You answer questions using ONLY the numbered chunks provided in the user message.
        Rules:
        1. Use only facts stated in the chunks. Never use outside knowledge.
        2. After every sentence that states a fact, cite the chunk or chunks it came from, like [1] or [1][3].
        3. If the chunks do not contain the answer, reply with exactly: \(notFoundMarker)
        4. Be concise. Quote exact values, part numbers and steps as written.
        """

    public static let rewriteSystemPrompt = """
        Rewrite the user's last question as one standalone search query that makes sense without the conversation. \
        Resolve pronouns and references using the conversation. Output only the query, nothing else.
        """

    /// The chunks, numbered from 1 in the given order, followed by the question.
    public static func answerPrompt(question: String, chunks: [RetrievedChunk]) -> String {
        var lines = ["Chunks:"]
        for (index, retrieved) in chunks.enumerated() {
            lines.append("[\(index + 1)] (\(label(for: retrieved))) \(retrieved.chunk.text)")
        }
        lines.append("")
        lines.append("Question: \(question)")
        return lines.joined(separator: "\n")
    }

    /// `Manual A, page 42, section “Reset”`
    static func label(for retrieved: RetrievedChunk) -> String {
        var parts = [retrieved.documentTitle]
        if let page = retrieved.chunk.page { parts.append("page \(page)") }
        if let heading = retrieved.chunk.heading, !heading.isEmpty { parts.append("section “\(heading)”") }
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
