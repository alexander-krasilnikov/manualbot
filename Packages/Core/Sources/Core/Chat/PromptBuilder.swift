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

    /// The Conversational answer style, when the documents do not answer: talk about the app, never about facts.
    public static let conversationalSystemPrompt = """
        You are ManualBot, an offline assistant that answers questions from the user's own manuals and documents.
        Nothing in the user's documents matched this message.
        Rules:
        1. Reply in at most two short sentences, in the same language as the user's message.
        2. You may say what you are, what you can do, and suggest asking about something in their documents.
        3. Never state facts about the world, products, or the documents. Never answer the question itself.
        """

    /// The Open answer style, when the documents do not answer: general knowledge, clearly not from the documents.
    public static let openSystemPrompt = """
        You are ManualBot, an offline assistant. Nothing in the user's documents answers this question, so answer it from \
        general knowledge.
        Rules:
        1. Reply in the same language as the user's question.
        2. Be concise. If you are not sure, say so plainly instead of guessing.
        3. Do not claim that the answer comes from the user's documents, and do not add citation markers.
        """

    /// The prompt of a reply without documents: the question alone, so no document text can be passed off as cited.
    public static func fallbackPrompt(question: String) -> String { question }

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
