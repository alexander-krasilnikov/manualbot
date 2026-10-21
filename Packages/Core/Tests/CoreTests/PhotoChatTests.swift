import CoreGraphics
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

private func samplePhoto() -> CGImage {
    let context = CGContext(
        data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    return context.makeImage()!
}

/// Manual A has a photo on page 14 with two text chunks beside it. Search results and image matches are scripted.
private struct PhotoHarness {
    let repo = InMemoryDocumentRepository()
    let text = FakeChunkSearch()
    let images: FakeImageSearch
    let generator: ScriptedGenerator
    let service: ChatService
    let chatID: String
    let features = FakeImageFeaturer()
    let page14: ImageRecord

    static let modelTag = FakeEmbedder().identity.tag

    static func chunk(_ ordinal: Int, page: Int, _ text: String, imageId: String? = nil) -> Chunk {
        Chunk(docId: "a", generation: 1, ordinal: ordinal, page: page, text: text, embedding: [Float](repeating: 0, count: 32),
              embeddingModel: modelTag, imageId: imageId)
    }

    init(
        answer: [String] = ["Descale it every six months [1]."], recognized: [String] = ["MODEL X200-B"], imageDistance: Double? = 0.2,
        textDistance: Double? = 0.3, tracer: any Tracer = NoTracer()
    ) async throws {
        let record = ImageRecord(
            docId: "a", generation: 1, n: 0, page: 14, caption: "Figure 3: Filter housing", captionSource: .nearby, width: 300, height: 200,
            features: [Float](repeating: 0, count: features.identity.dimensions), featureModel: features.identity.tag)
        page14 = record
        try await repo.upsert(DocumentRecord(id: "a", title: "Manual A", type: .pdf))
        try await repo.writeChunks([
            Self.chunk(0, page: 14, "Descale the X200 every six months."),
            Self.chunk(1, page: 14, "Use only the supplied descaler."),
            Self.chunk(2, page: 14, "Figure 3: Filter housing", imageId: record.id),
            Self.chunk(3, page: 20, "Replace the filter yearly."),
        ])
        try await repo.activate(generation: 1, for: "a")

        if let textDistance {
            text.vectorHits = [ScoredChunk(chunk: Self.chunk(0, page: 14, "Descale the X200 every six months."), score: textDistance)]
            text.keywordHits = [ScoredChunk(chunk: Self.chunk(0, page: 14, "Descale the X200 every six months."), score: 1)]
        } else {
            text.vectorHits = [ScoredChunk(chunk: Self.chunk(3, page: 20, "Replace the filter yearly."), score: 0.95)]
        }
        images = FakeImageSearch(hits: imageDistance.map { [ScoredImage(image: record, score: $0)] } ?? [])
        generator = ScriptedGenerator { request in request.maxTokens == 64 ? ["rewritten"] : answer }

        let retriever = Retriever(
            embedder: FakeEmbedder(), search: text, repository: repo, tracer: tracer,
            photoSearch: PhotoSearch(features: features, search: images, recognizer: FakeTextRecognizer(lines: recognized)))
        service = ChatService(chats: repo, retriever: retriever, generator: generator, tracer: tracer)
        chatID = try await repo.createChat().id
    }

    func ask(_ question: String, photo: CGImage? = samplePhoto(), style: AnswerStyle = .balanced) async throws -> [ChatEvent] {
        var events: [ChatEvent] = []
        for try await event in service.ask(question, in: chatID, photo: photo, style: style) { events.append(event) }
        return events
    }

    func reply(_ events: [ChatEvent]) -> MessageRecord? {
        events.compactMap { if case .completed(let m) = $0 { m } else { nil } }.last
    }
}

@Suite struct PhotoChatTests {
    @Test func aNameplateWithAQuestionIsAnsweredFromTheMatchingManual() async throws {
        let h = try await PhotoHarness()
        let events = try await h.ask("how do I descale it?")

        let reply = try #require(h.reply(events))
        #expect(!reply.notFound && !reply.matchesOnly)
        #expect(reply.text == "Descale it every six months [1].")
        #expect(reply.citations.first?.docTitle == "Manual A" && reply.citations.first?.page == 14)
        #expect(h.text.keywordTerms == [["descale", "X200-B"]], "the model number read off the nameplate joins the keywords")
        #expect(reply.imageMatches.map(\.imageId) == [h.page14.id])
        #expect(h.generator.callCount == 1)
        // The language model only ever sees chunks and the question, never the photo or its transcript.
        let prompt = try #require(h.generator.requests.last?.prompt)
        #expect(prompt.contains("Chunks:") && prompt.contains("Question: how do I descale it?") && !prompt.contains("X200-B"))
    }

    @Test func thePhotoIsStoredWithTheQuestionAndShownAgain() async throws {
        let h = try await PhotoHarness()
        _ = try await h.ask("how do I descale it?")

        let stored = try await h.repo.messages(chatId: h.chatID)
        let question = try #require(stored.first)
        #expect(question.role == .user && question.hasAttachment)
        let bytes = try #require(try await h.repo.attachment(messageId: question.id))
        #expect(bytes.starts(with: [0xFF, 0xD8]))
        #expect(stored.last?.hasAttachment == false)
    }

    @Test func aPhotoAloneAnswersWithMatchesAndNeverCallsTheModel() async throws {
        let h = try await PhotoHarness(recognized: [])
        let events = try await h.ask("")

        let reply = try #require(h.reply(events))
        #expect(reply.matchesOnly && !reply.notFound)
        #expect(reply.text == ChatService.photoMatchesText)
        let match = try #require(reply.imageMatches.first)
        #expect(reply.imageMatches.count == 1)
        #expect(match.docTitle == "Manual A" && match.page == 14 && match.imageId == h.page14.id && match.distance == 0.2)
        #expect(reply.citations.map(\.page) == [14, 14, 14], "the chunks from the matching page")
        #expect(reply.citations.contains { $0.imageId == h.page14.id }, "the image's own chunk says so")
        #expect(h.generator.callCount == 0)
        #expect(events.allSatisfy { if case .delta = $0 { false } else { true } })
        #expect(try await h.repo.chat(id: h.chatID)?.title == "Photo question")
    }

    @Test func aPhotoThatMatchesNothingGetsTheNotFoundReply() async throws {
        let h = try await PhotoHarness(recognized: [], imageDistance: nil, textDistance: nil)
        let events = try await h.ask("")
        let reply = try #require(h.reply(events))
        #expect(reply.notFound && !reply.matchesOnly && reply.imageMatches.isEmpty)
        #expect(h.generator.callCount == 0)
    }

    @Test func aPhotoAloneIsUnchangedUnderTheOpenStyle() async throws {
        let open = AnswerStyle(offset: 0.08)
        let nothing = try await PhotoHarness(recognized: [], imageDistance: nil, textDistance: nil)
        #expect(try #require(nothing.reply(try await nothing.ask("", style: open))).notFound)
        let matching = try await PhotoHarness(recognized: [])
        #expect(try #require(matching.reply(try await matching.ask("", style: open))).matchesOnly)
        #expect(nothing.generator.callCount == 0 && matching.generator.callCount == 0)
    }

    @Test func aQuestionWithAPhotoThatMatchesNothingIsAlsoNotFound() async throws {
        let h = try await PhotoHarness(recognized: ["MADE IN GERMANY"], imageDistance: nil, textDistance: nil)
        let reply = try #require(h.reply(try await h.ask("what is this part?")))
        #expect(reply.notFound)
        #expect(h.generator.callCount == 0, "nothing relevant, so the model is not called")
    }

    @Test func aQuestionOrAPhotoIsRequired() async throws {
        let h = try await PhotoHarness()
        await #expect(throws: ChatError.emptyQuestion) { _ = try await h.ask("  ", photo: nil) }
        #expect(try await h.repo.messages(chatId: h.chatID).isEmpty)
    }

    @Test func aQuestionWithoutAPhotoBehavesAsBefore() async throws {
        let h = try await PhotoHarness()
        let reply = try #require(h.reply(try await h.ask("how do I descale it?", photo: nil)))
        #expect(reply.imageMatches.isEmpty && !reply.matchesOnly)
        #expect(h.images.filters.isEmpty)
        #expect(try await h.repo.messages(chatId: h.chatID).first?.hasAttachment == false)
    }

    @Test func aFollowUpAfterAPhotoStillRewritesTheTextOnly() async throws {
        let h = try await PhotoHarness()
        _ = try await h.ask("how do I descale it?")
        let events = try await h.ask("and how often?", photo: nil)
        #expect(events.first == .query("rewritten"))
    }

    @Test func aPhotoQuestionIsOneTracedOperationWithTheModelSkipped() async throws {
        let tracer = RecordingTracer()
        let h = try await PhotoHarness(recognized: [], tracer: tracer)
        _ = try await h.ask("")
        let operations = Set(tracer.events.compactMap(\.operation))
        #expect(operations.count == 1 && operations.first?.kind == .ask && operations.first?.title == "Photo question")
        #expect(tracer.kinds.contains(.generation(firstToken: nil, skipped: true)))
        #expect(tracer.kinds.contains { if case .photoAnalyzed = $0 { true } else { false } })
    }

    @Test func aChatRecordFromBeforePhotosStillLoadsItsMessages() async throws {
        let h = try await PhotoHarness()
        _ = try await h.ask("how do I descale it?", photo: nil)
        let stored = try await h.repo.messages(chatId: h.chatID)
        #expect(stored.count == 2 && stored.allSatisfy { !$0.hasAttachment && !$0.matchesOnly })
    }
}
