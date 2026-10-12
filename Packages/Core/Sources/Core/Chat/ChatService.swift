import CoreGraphics
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
/// relevant, otherwise generate from the retrieved chunks and keep only citations that are real.
public actor ChatService {
    public static let notFoundText = "I couldn't find an answer to that in your documents."
    public static let notFoundWithSuggestionsText = notFoundText + " The closest chunks are listed below."
    /// The reply to a photo sent without a question: what in the library matches it, with nothing generated.
    public static let photoMatchesText = "Here is what matches your photo in your documents."
    static let photoTitle = "Photo question"
    public static let untitled = "New chat"
    static let defaultTitle = untitled

    private let chats: any ChatRepository
    private let retriever: Retriever
    private let generator: any Generator
    private let rewriter: QueryRewriter
    private let maxAnswerTokens: Int
    private let temperature: Float
    private let tracer: any Tracer

    public init(
        chats: any ChatRepository, retriever: Retriever, generator: any Generator,
        maxAnswerTokens: Int = 512, temperature: Float = 0.2, tracer: any Tracer = NoTracer()
    ) {
        self.tracer = tracer
        self.chats = chats
        self.retriever = retriever
        self.generator = generator
        self.rewriter = QueryRewriter(generator: generator)
        self.maxAnswerTokens = maxAnswerTokens
        self.temperature = temperature
    }

    /// Streams events for one question. Ending iteration early (the user pressing stop) stops
    /// generation; the partial answer is kept and marked as stopped.
    /// A photo may come with the question or alone. It is read on the device and never given to the language model.
    public nonisolated func ask(_ question: String, in chatId: String, photo: CGImage? = nil) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.answer(question, in: chatId, photo: photo) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Pipeline

    /// Runs one question as its own traced operation, so everything it causes is grouped under it.
    private func answer(_ raw: String, in chatId: String, photo: CGImage?, emit: @Sendable (ChatEvent) -> Void) async throws {
        guard tracer.isEnabled else { return try await respond(raw, in: chatId, photo: photo, emit: emit) }
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = TraceOperation(id: "ask-\(UUID().uuidString)", kind: .ask, title: typed.isEmpty ? Self.photoTitle : typed)
        try await TraceContext.$operation.withValue(operation) { try await respond(raw, in: chatId, photo: photo, emit: emit) }
    }

    private func respond(_ raw: String, in chatId: String, photo: CGImage?, emit: @Sendable (ChatEvent) -> Void) async throws {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || photo != nil else { throw ChatError.emptyQuestion }
        guard let chat = try await chats.chat(id: chatId) else { throw ChatError.chatNotFound(chatId) }

        let history = try await chats.messages(chatId: chatId)
        // The photo is kept with the question so the chat can show it again; a photo that cannot be encoded is still searched with.
        let attachment = photo.flatMap { try? DisplayCopy.jpeg(from: $0) }
        let asked = MessageRecord(
            id: UUID().uuidString, chatId: chatId, role: .user, text: question,
            createdAt: Self.timestamp(after: history.last?.createdAt), hasAttachment: attachment != nil)
        if let attachment {
            try await chats.upsert(message: asked, attachment: attachment)
        } else {
            try await chats.upsert(message: asked)
        }
        if history.isEmpty, chat.title == Self.defaultTitle {
            try await chats.rename(chatId: chatId, to: question.isEmpty ? Self.photoTitle : Self.title(from: question))
        }

        let standalone = question.isEmpty ? "" : await rewriter.standaloneQuery(for: question, history: history)
        if standalone != question { tracer.emit(.queryRewritten(original: question, standalone: standalone)) }
        if !standalone.isEmpty { emit(.query(standalone)) }

        let scope = chat.pinnedDocIds.isEmpty ? nil : Set(chat.pinnedDocIds)
        let retrieval = try await retriever.retrieve(standalone, scope: scope, photo: photo)
        let matches = retrieval.images.map(Self.match)

        // Nothing relevant: answer instantly, without the language model.
        guard retrieval.relevant, !retrieval.chunks.isEmpty else {
            tracer.emit(.generation(firstToken: nil, skipped: true))
            try await finish(notFound: retrieval.closest(), chatId: chatId, standalone: standalone, after: asked, emit: emit)
            return
        }

        // A photo with no question: show what matches, and write nothing.
        if question.isEmpty {
            tracer.emit(.generation(firstToken: nil, skipped: true))
            let reply = MessageRecord(
                id: UUID().uuidString, chatId: chatId, role: .assistant, text: Self.photoMatchesText,
                citations: retrieval.chunks.enumerated().map { Self.citation($0.offset + 1, $0.element) },
                createdAt: Self.after(asked), imageMatches: matches, matchesOnly: true)
            try await chats.upsert(message: reply)
            emit(.completed(reply))
            return
        }

        let chunks = retrieval.chunks
        let request = GenerationRequest(
            system: PromptBuilder.answerSystemPrompt,
            prompt: PromptBuilder.answerPrompt(question: standalone, chunks: chunks),
            maxTokens: maxAnswerTokens, temperature: temperature)

        var text = ""
        var gate = NotFoundGate()
        var failure: Error?
        let started = tracer.isEnabled ? ContinuousClock.now : nil
        var firstToken: TimeInterval?
        do {
            for try await piece in generator.generate(request) {
                if firstToken == nil, let started { firstToken = started.duration(to: .now).seconds }
                text += piece
                if let visible = gate.feed(piece) { emit(.delta(visible)) }
                if Task.isCancelled { break }
            }
            if let rest = gate.flush() { emit(.delta(rest)) }
        } catch {
            failure = error
        }
        let stopped = Task.isCancelled || failure != nil
        if let started {
            tracer.emit(duration: started.duration(to: .now).seconds, .generation(firstToken: firstToken, skipped: false))
        }

        if gate.isNotFound(text) && !stopped {
            try await finish(notFound: retrieval.closest(), chatId: chatId, standalone: standalone, after: asked, emit: emit)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let failure { throw failure }
            return  // stopped before any text: nothing to keep
        }

        let validated = CitationValidator.validate(text, chunkCount: chunks.count)
        if !validated.isGrounded && !stopped {
            // An answer that cites nothing real is not grounded in the documents.
            try await finish(notFound: retrieval.closest(), chatId: chatId, standalone: standalone, after: asked, emit: emit)
            return
        }
        let reply = MessageRecord(
            id: UUID().uuidString, chatId: chatId, role: .assistant, text: validated.text, standaloneQuery: standalone,
            citations: validated.cited.map { Self.citation($0, chunks[$0 - 1]) }, stopped: stopped,
            createdAt: Self.after(asked), imageMatches: matches)
        try await chats.upsert(message: reply)
        emit(.completed(reply))
        if let failure { throw failure }
    }

    private func finish(
        notFound suggestions: [RetrievedChunk], chatId: String, standalone: String, after asked: MessageRecord,
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

    private static func citation(_ n: Int, _ retrieved: RetrievedChunk) -> Citation {
        Citation(
            n: n, chunkId: retrieved.chunk.id, docId: retrieved.chunk.docId, docTitle: retrieved.documentTitle,
            page: retrieved.chunk.page, heading: retrieved.chunk.heading, snippet: retrieved.chunk.text,
            imageId: retrieved.chunk.imageId)
    }

    private static func match(_ image: RetrievedImage) -> ImageMatch {
        ImageMatch(
            imageId: image.image.id, docId: image.image.docId, docTitle: image.documentTitle, page: image.image.page,
            heading: image.image.heading, distance: image.distance)
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
