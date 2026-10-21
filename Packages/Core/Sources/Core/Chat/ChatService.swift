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
    /// The text streamed so far is discarded: a reply not from the documents follows in its place.
    case restart
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
    /// A conversational reply is a sentence or two about the app.
    static let conversationalTokens = 96
    static let conversationalTemperature: Float = 0.3

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
    /// `style` sets the relevance cutoff, and what is said when the documents do not answer.
    public nonisolated func ask(
        _ question: String, in chatId: String, photo: CGImage? = nil, style: AnswerStyle = .balanced
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let ask = String(UUID().uuidString.prefix(8))
            let task = Task {
                do {
                    try await AskID.$current.withValue(ask) {
                        try await self.answer(question, in: chatId, photo: photo, style: style) { continuation.yield($0) }
                    }
                    log.notice("ask \(ask, privacy: .public): finished")
                    continuation.finish()
                } catch {
                    log.error("ask \(ask, privacy: .public): failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { log.notice("ask \(ask, privacy: .public): stopped by the user") }
                task.cancel()
            }
        }
    }

    // MARK: Pipeline

    /// Runs one question as its own traced operation, so everything it causes is grouped under it.
    private func answer(
        _ raw: String, in chatId: String, photo: CGImage?, style: AnswerStyle, emit: @Sendable (ChatEvent) -> Void
    ) async throws {
        guard tracer.isEnabled else { return try await respond(raw, in: chatId, photo: photo, style: style, emit: emit) }
        let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = TraceOperation(id: "ask-\(UUID().uuidString)", kind: .ask, title: typed.isEmpty ? Self.photoTitle : typed)
        try await TraceContext.$operation.withValue(operation) {
            try await respond(raw, in: chatId, photo: photo, style: style, emit: emit)
        }
    }

    private func respond(
        _ raw: String, in chatId: String, photo: CGImage?, style: AnswerStyle, emit: @Sendable (ChatEvent) -> Void
    ) async throws {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || photo != nil else { throw ChatError.emptyQuestion }
        guard let chat = try await chats.chat(id: chatId) else { throw ChatError.chatNotFound(chatId) }

        let history = try await chats.messages(chatId: chatId)
        let ask = AskID.current
        log.notice("""
            ask \(ask, privacy: .public): started, question \(question.count) chars, photo \(photo != nil), \
            history \(history.count) messages, pinned \(chat.pinnedDocIds.count)
            """)
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

        let rewriteStart = ContinuousClock.now
        let standalone = question.isEmpty ? "" : await rewriter.standaloneQuery(for: question, history: history)
        if standalone != question {
            tracer.emit(.queryRewritten(original: question, standalone: standalone))
            log.notice("ask \(ask, privacy: .public): rewritten to \(standalone.count) chars in \(Self.since(rewriteStart), privacy: .public)")
        }
        if !standalone.isEmpty { emit(.query(standalone)) }

        let scope = chat.pinnedDocIds.isEmpty ? nil : Set(chat.pinnedDocIds)
        let retrievalStart = ContinuousClock.now
        log.notice("ask \(ask, privacy: .public): retrieving")
        let retrieval = try await retriever.retrieve(
            standalone, scope: scope, photo: photo, maxDistance: style.maxDistance(tuned: retriever.configuration.maxDistance))
        let matches = retrieval.images.map(Self.match)
        log.notice("""
            ask \(ask, privacy: .public): retrieved \(retrieval.chunks.count) chunks, \(retrieval.images.count) images in \
            \(Self.since(retrievalStart), privacy: .public), relevant \(retrieval.relevant), \
            best distance \(retrieval.bestDistance.map { String(format: "%.3f", $0) } ?? "none", privacy: .public)
            """)

        // Nothing relevant: answer instantly, without the language model.
        guard retrieval.relevant, !retrieval.chunks.isEmpty else {
            log.notice("ask \(ask, privacy: .public): not found, retrieval found nothing relevant (model not run)")
            tracer.emit(.generation(firstToken: nil, skipped: true))
            try await finishWithoutAnswer(retrieval, style: style, chatId: chatId, standalone: standalone, after: asked, emit: emit)
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
        var pieces = 0
        var gate = NotFoundGate()
        var failure: Error?
        let started = ContinuousClock.now
        var firstToken: TimeInterval?
        log.notice("""
            ask \(ask, privacy: .public): generating from \(chunks.count) chunks, prompt \(request.prompt.count) chars, \
            max \(request.maxTokens) tokens
            """)
        let interval = Diagnostics.signposter.beginInterval("Generate", id: Diagnostics.signposter.makeSignpostID())
        do {
            for try await piece in generator.generate(request) {
                if firstToken == nil {
                    firstToken = started.duration(to: .now).seconds
                    log.notice("ask \(ask, privacy: .public): first text after \(Self.since(started), privacy: .public)")
                }
                text += piece
                pieces += 1
                if let visible = gate.feed(piece) { emit(.delta(visible)) }
                if Task.isCancelled { break }
            }
            if let rest = gate.flush() { emit(.delta(rest)) }
        } catch {
            failure = error
        }
        Diagnostics.signposter.endInterval("Generate", interval)
        let stopped = Task.isCancelled || failure != nil
        log.notice("""
            ask \(ask, privacy: .public): generation ended after \(Self.since(started), privacy: .public), \(pieces) pieces, \
            \(text.count) chars, cancelled \(Task.isCancelled), \
            error \(failure.map { String(describing: $0) } ?? "none", privacy: .public)
            """)
        tracer.emit(duration: started.duration(to: .now).seconds, .generation(firstToken: firstToken, skipped: false))

        if gate.isNotFound(text) && !stopped {
            log.notice("ask \(ask, privacy: .public): not found, the model replied NOT_FOUND")
            try await finishWithoutAnswer(retrieval, style: style, chatId: chatId, standalone: standalone, after: asked, emit: emit)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let failure { throw failure }
            return  // stopped before any text: nothing to keep
        }

        let validated = CitationValidator.validate(text, chunkCount: chunks.count)
        if !validated.isGrounded && !stopped {
            // An answer that cites nothing real is not grounded in the documents.
            log.notice("ask \(ask, privacy: .public): not found, the \(text.count)-char answer cited no supplied chunk")
            try await finishWithoutAnswer(retrieval, style: style, chatId: chatId, standalone: standalone, after: asked, emit: emit)
            return
        }
        log.notice("ask \(ask, privacy: .public): answered with \(validated.cited.count) cited chunks, stopped \(stopped)")
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

    /// The documents do not answer. Under the Strict and Balanced styles, and for a photo sent without a question, that is
    /// the not-found reply. Under Conversational and Open, the model writes a reply from the question alone, never from the
    /// chunks, saved as not from the documents; Open also lists the closest chunks. A reply that fails or comes back empty
    /// gives the not-found reply instead.
    private func finishWithoutAnswer(
        _ retrieval: RetrievalResult, style: AnswerStyle, chatId: String, standalone: String, after asked: MessageRecord,
        emit: @Sendable (ChatEvent) -> Void
    ) async throws {
        let suggestions = retrieval.closest()
        let stop = style.stop
        guard stop.repliesWithoutDocuments, !standalone.isEmpty else {
            return try await finish(notFound: suggestions, chatId: chatId, standalone: standalone, after: asked, emit: emit)
        }
        let ask = AskID.current
        let conversational = stop == .conversational
        let request = GenerationRequest(
            system: conversational ? PromptBuilder.conversationalSystemPrompt : PromptBuilder.openSystemPrompt,
            prompt: PromptBuilder.fallbackPrompt(question: standalone),
            maxTokens: conversational ? Self.conversationalTokens : maxAnswerTokens,
            temperature: conversational ? Self.conversationalTemperature : temperature)
        log.notice("ask \(ask, privacy: .public): replying without documents, \(stop.name, privacy: .public) style")
        emit(.restart)

        var text = ""
        let started = ContinuousClock.now
        do {
            for try await piece in generator.generate(request) {
                text += piece
                emit(.delta(piece))
                if Task.isCancelled { break }
            }
        } catch {
            log.error("ask \(ask, privacy: .public): the reply without documents failed: \(String(describing: error), privacy: .public)")
            return try await finish(notFound: suggestions, chatId: chatId, standalone: standalone, after: asked, emit: emit)
        }
        // Markers the model added anyway point at nothing: no chunk was supplied.
        let cleaned = CitationValidator.validate(text, chunkCount: 0).text
        log.notice("""
            ask \(ask, privacy: .public): reply without documents ended after \(Self.since(started), privacy: .public), \
            \(cleaned.count) chars, cancelled \(Task.isCancelled)
            """)
        guard !cleaned.isEmpty else {
            if Task.isCancelled { return }  // stopped before any text: nothing to keep
            return try await finish(notFound: suggestions, chatId: chatId, standalone: standalone, after: asked, emit: emit)
        }
        let reply = MessageRecord(
            id: UUID().uuidString, chatId: chatId, role: .assistant, text: cleaned, standaloneQuery: standalone,
            citations: stop == .open ? suggestions.enumerated().map { Self.citation($0.offset + 1, $0.element) } : [],
            stopped: Task.isCancelled, createdAt: Self.after(asked), fromDocuments: false)
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

    /// `1.234s`, for the log.
    private static func since(_ start: ContinuousClock.Instant) -> String {
        String(format: "%.3fs", start.duration(to: .now).seconds)
    }

    static func title(from question: String) -> String {
        let oneLine = question.split(whereSeparator: \.isNewline).joined(separator: " ")
        return oneLine.count <= 40 ? oneLine : String(oneLine.prefix(40)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

private let log = Diagnostics.chat

/// Ties the log lines of one question together.
enum AskID {
    @TaskLocal static var current = "-"
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
