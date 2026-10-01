import Foundation
import Ports

public enum ChatError: Error, Equatable, LocalizedError {
    case chatNotFound(String)
    case emptyQuestion

    public var errorDescription: String? {
        switch self {
        case .chatNotFound: "This chat no longer exists."
        case .emptyQuestion: "Type a question first."
        }
    }
}

public enum ChatEvent: Sendable, Equatable {
    /// The standalone query used for retrieval (equal to the question when there was nothing to resolve).
    case query(String)
    /// More of the answer as it streams. Citation markers are not validated yet.
    case delta(String)
    /// The saved reply. Its text and citations replace whatever was streamed.
    case completed(MessageRecord)
}

/// Answers a question strictly from the user's documents: rewrite, retrieve, refuse when nothing is
/// relevant, otherwise generate from the retrieved passages and keep only citations that are real.
public actor ChatService {
    public static let notFoundText = "I couldn't find an answer to that in your documents."
    public static let notFoundWithSuggestionsText = notFoundText + " The closest passages are listed below."
    public static let untitled = "New chat"
    static let defaultTitle = untitled

    private let chats: any ChatRepository
    private let retriever: Retriever
    private let generator: any Generator
    private let rewriter: QueryRewriter
    private let maxAnswerTokens: Int
    private let temperature: Float

    public init(
        chats: any ChatRepository, retriever: Retriever, generator: any Generator,
        maxAnswerTokens: Int = 512, temperature: Float = 0.2
    ) {
        self.chats = chats
        self.retriever = retriever
        self.generator = generator
        self.rewriter = QueryRewriter(generator: generator)
        self.maxAnswerTokens = maxAnswerTokens
        self.temperature = temperature
    }

    /// Streams events for one question. Ending iteration early (the user pressing stop) stops
    /// generation; the partial answer is kept and marked as stopped.
    public nonisolated func ask(_ question: String, in chatId: String) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.answer(question, in: chatId) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Pipeline

    private func answer(_ raw: String, in chatId: String, emit: @Sendable (ChatEvent) -> Void) async throws {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw ChatError.emptyQuestion }
        guard let chat = try await chats.chat(id: chatId) else { throw ChatError.chatNotFound(chatId) }

        let history = try await chats.messages(chatId: chatId)
        let asked = MessageRecord(
            id: UUID().uuidString, chatId: chatId, role: .user, text: question,
            createdAt: Self.timestamp(after: history.last?.createdAt))
        try await chats.upsert(message: asked)
        if history.isEmpty, chat.title == Self.defaultTitle {
            try await chats.rename(chatId: chatId, to: Self.title(from: question))
        }

        let standalone = await rewriter.standaloneQuery(for: question, history: history)
        emit(.query(standalone))

        let scope = chat.pinnedDocIds.isEmpty ? nil : Set(chat.pinnedDocIds)
        let retrieval = try await retriever.retrieve(standalone, scope: scope)

        // Nothing relevant: answer instantly, without the language model.
        guard retrieval.relevant, !retrieval.passages.isEmpty else {
            try await finish(notFound: retrieval.closest(), chatId: chatId, standalone: standalone, after: asked, emit: emit)
            return
        }

        let passages = retrieval.passages
        let request = GenerationRequest(
            system: PromptBuilder.answerSystemPrompt,
            prompt: PromptBuilder.answerPrompt(question: standalone, passages: passages),
            maxTokens: maxAnswerTokens, temperature: temperature)

        var text = ""
        var gate = NotFoundGate()
        var failure: Error?
        do {
            for try await piece in generator.generate(request) {
                text += piece
                if let visible = gate.feed(piece) { emit(.delta(visible)) }
                if Task.isCancelled { break }
            }
            if let rest = gate.flush() { emit(.delta(rest)) }
        } catch {
            failure = error
        }
        let stopped = Task.isCancelled || failure != nil

        if gate.isNotFound(text) && !stopped {
            try await finish(notFound: retrieval.closest(), chatId: chatId, standalone: standalone, after: asked, emit: emit)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let failure { throw failure }
            return  // stopped before any text: nothing to keep
        }

        let validated = CitationValidator.validate(text, passageCount: passages.count)
        if !validated.isGrounded && !stopped {
            // An answer that cites nothing real is not grounded in the documents.
            try await finish(notFound: retrieval.closest(), chatId: chatId, standalone: standalone, after: asked, emit: emit)
            return
        }
        let reply = MessageRecord(
            id: UUID().uuidString, chatId: chatId, role: .assistant, text: validated.text, standaloneQuery: standalone,
            citations: validated.cited.map { Self.citation($0, passages[$0 - 1]) }, stopped: stopped,
            createdAt: Self.after(asked))
        try await chats.upsert(message: reply)
        emit(.completed(reply))
        if let failure { throw failure }
    }

    private func finish(
        notFound suggestions: [RetrievedPassage], chatId: String, standalone: String, after asked: MessageRecord,
        emit: @Sendable (ChatEvent) -> Void
    ) async throws {
        let reply = MessageRecord(
            id: UUID().uuidString, chatId: chatId, role: .assistant,
            text: suggestions.isEmpty ? Self.notFoundText : Self.notFoundWithSuggestionsText,
            standaloneQuery: standalone,
            citations: suggestions.enumerated().map { Self.citation($0.offset + 1, $0.element) },
            notFound: true, createdAt: Self.after(asked))
        try await chats.upsert(message: reply)
        emit(.completed(reply))
    }

    // MARK: Helpers

    private static func citation(_ n: Int, _ passage: RetrievedPassage) -> Citation {
        Citation(
            n: n, chunkId: passage.chunk.id, docId: passage.chunk.docId, docTitle: passage.documentTitle,
            page: passage.chunk.page, heading: passage.chunk.heading, snippet: passage.chunk.text)
    }

    /// Now, but never earlier than 1 ms after `previous`, so messages always sort in the order they were written.
    private static func timestamp(after previous: Date?) -> Date {
        guard let previous else { return Date() }
        return max(Date(), previous.addingTimeInterval(0.001))
    }

    private static func after(_ message: MessageRecord) -> Date { timestamp(after: message.createdAt) }

    static func title(from question: String) -> String {
        let oneLine = question.split(whereSeparator: \.isNewline).joined(separator: " ")
        return oneLine.count <= 40 ? oneLine : String(oneLine.prefix(40)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Holds back the start of a reply just long enough to tell whether the model is answering
/// `NOT_FOUND`, so that marker is never shown as streamed text.
struct NotFoundGate {
    private enum State { case undecided, notFound, passThrough }
    private var state = State.undecided
    private var held = ""
    private let marker = PromptBuilder.notFoundMarker

    /// Text to show now, if any.
    mutating func feed(_ piece: String) -> String? {
        switch state {
        case .notFound: return nil
        case .passThrough: return piece
        case .undecided:
            held += piece
            let probe = held.drop(while: \.isWhitespace)
            if probe.hasPrefix(marker) { state = .notFound; held = ""; return nil }
            if marker.hasPrefix(probe) { return nil }  // could still become the marker
            state = .passThrough
            defer { held = "" }
            return held
        }
    }

    /// At the end of the stream: text that was held back but turned out not to be the marker.
    mutating func flush() -> String? {
        defer { held = "" }
        return state == .undecided && !held.isEmpty ? held : nil
    }

    func isNotFound(_ full: String) -> Bool {
        full.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(marker)
    }
}
