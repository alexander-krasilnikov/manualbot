import CoreGraphics
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

@Suite struct PhotoRetrievalTests {
    private let features = FakeImageFeaturer()
    private let embedderTag = FakeEmbedder().identity.tag

    private func photo(_ seed: Int = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: CGFloat(seed) / 10, green: 0.5, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    private func chunk(_ doc: String, _ ordinal: Int, page: Int? = nil, heading: String? = nil, _ text: String, imageId: String? = nil) -> Chunk {
        Chunk(docId: doc, generation: 1, ordinal: ordinal, page: page, heading: heading, text: text,
              embedding: [Float](repeating: 0, count: 32), embeddingModel: embedderTag, imageId: imageId)
    }

    private func image(_ doc: String, n: Int, page: Int? = nil, heading: String? = nil) -> ImageRecord {
        ImageRecord(docId: doc, generation: 1, n: n, page: page, heading: heading, width: 200, height: 200,
                    features: [Float](repeating: 0, count: features.identity.dimensions), featureModel: features.identity.tag)
    }

    /// Manual A (PDF): page 14 has a photo, its own passage and two text passages; page 15 has text only.
    /// Manual B (Word): one photo under the heading "Installation". Poster C: an imported photo with no page.
    private struct World {
        var repo = InMemoryDocumentRepository()
        var photoOnPage14: ImageRecord
        var photoInWord: ImageRecord
        var importedPhoto: ImageRecord
    }

    private func world() async throws -> World {
        let repo = InMemoryDocumentRepository()
        let page14 = image("a", n: 0, page: 14), word = image("b", n: 0, heading: "Installation"), poster = image("c", n: 0)
        try await repo.upsert(DocumentRecord(id: "a", title: "Manual A", type: .pdf))
        try await repo.upsert(DocumentRecord(id: "b", title: "Manual B", type: .docx))
        try await repo.upsert(DocumentRecord(id: "c", title: "Nameplate photo", type: .image))
        try await repo.writeChunks([
            chunk("a", 0, page: 14, "Descale the X200 every six months."),
            chunk("a", 1, page: 14, "Use only the supplied descaler."),
            chunk("a", 2, page: 14, "Figure 3: Filter housing", imageId: page14.id),
            chunk("a", 3, page: 15, "Replace the filter yearly."),
            chunk("b", 0, heading: "Installation", "Mount the pump on a flat base."),
            chunk("b", 1, heading: "Installation", "Installation · Pump front view", imageId: word.id),
            chunk("b", 2, heading: "Service", "Service text."),
            chunk("c", 0, "MODEL X200-B S/N 4471-22", imageId: poster.id),
        ])
        for id in ["a", "b", "c"] { try await repo.activate(generation: 1, for: id) }
        return World(repo: repo, photoOnPage14: page14, photoInWord: word, importedPhoto: poster)
    }

    private func retriever(
        _ world: World, text: FakeChunkSearch = FakeChunkSearch(), images: FakeImageSearch = FakeImageSearch(),
        recognizer: FakeTextRecognizer = FakeTextRecognizer(), tracer: any Tracer = NoTracer()
    ) -> Retriever {
        Retriever(
            embedder: FakeEmbedder(), search: text, repository: world.repo, tracer: tracer,
            photoSearch: PhotoSearch(features: features, search: images, recognizer: recognizer))
    }

    private func scored(_ chunk: Chunk, _ distance: Double) -> ScoredChunk { ScoredChunk(chunk: chunk, score: distance) }

    // MARK: Fusion

    @Test func aPassageReachedThroughThePhotoAndFoundByTextAppearsOnceAndRanksFirst() async throws {
        let w = try await world()
        let text = FakeChunkSearch(vectorHits: [
            scored(chunk("a", 3, page: 15, "Replace the filter yearly."), 0.5),
            scored(chunk("a", 0, page: 14, "Descale the X200 every six months."), 0.55),
        ])
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoOnPage14, score: 0.2)])
        let result = try await retriever(w, text: text, images: images).retrieve("how do I descale it", photo: photo())

        let ids = result.passages.map(\.id)
        #expect(Set(ids).count == ids.count, "no passage twice")
        #expect(ids.first == "a:1:0", "found by the text search and through the photo, so it leads: \(ids)")
        let first = try #require(result.passages.first)
        #expect(first.distance == 0.55 && first.imageRank != nil && first.keywordRank == nil)
        // The rest of page 14 is reached too, in the order: the image's own passage, then the text beside it.
        #expect(ids.contains("a:1:2") && ids.contains("a:1:1"))
        #expect(!ids.contains("b:1:0"))
        #expect(result.images.map(\.id) == [w.photoOnPage14.id])
        #expect(result.images.first?.documentTitle == "Manual A" && result.images.first?.distance == 0.2)
    }

    @Test func aWordImageReachesThePassagesUnderItsHeading() async throws {
        let w = try await world()
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoInWord, score: 0.2)])
        let result = try await retriever(w, images: images).retrieve("", photo: photo())
        let ids = Set(result.passages.map(\.id))
        #expect(ids == ["b:1:0", "b:1:1"], "the passages under 'Installation' and not those under 'Service': \(ids)")
    }

    @Test func anImportedPhotoReachesItsOwnPassage() async throws {
        let w = try await world()
        let images = FakeImageSearch(hits: [ScoredImage(image: w.importedPhoto, score: 0.1)])
        let result = try await retriever(w, images: images).retrieve("", photo: photo())
        #expect(result.passages.map(\.id) == ["c:1:0"] && result.relevant)
    }

    // MARK: Relevance

    @Test func aCloseImageMatchPassesTheGateWhenTheTextAloneWouldNot() async throws {
        let w = try await world()
        let text = FakeChunkSearch(vectorHits: [scored(chunk("a", 3, page: 15, "Replace the filter yearly."), 0.9)])
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoOnPage14, score: 0.2)])
        let tracer = RecordingTracer()
        let result = try await retriever(w, text: text, images: images, tracer: tracer).retrieve("what is this", photo: photo())
        #expect(result.relevant)
        #expect(tracer.kinds.contains(.relevance(
            bestDistance: 0.9, threshold: 0.76, outcome: .passedOnImage(0.2), bestImageDistance: 0.2, imageThreshold: 0.25)))
    }

    @Test func aDistantImageIsNotAMatchAndTheQuestionStaysNotRelevant() async throws {
        let w = try await world()
        let text = FakeChunkSearch(vectorHits: [scored(chunk("a", 3, page: 15, "Replace the filter yearly."), 0.9)])
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoOnPage14, score: 0.4)])
        let result = try await retriever(w, text: text, images: images).retrieve("what is this", photo: photo())
        #expect(!result.relevant && result.images.isEmpty)
        #expect(result.passages.map(\.id) == ["a:1:3"], "nothing reached through the photo")
    }

    @Test func distanceStillWinsOverTheImageMatch() async throws {
        let w = try await world()
        let text = FakeChunkSearch(vectorHits: [scored(chunk("a", 0, page: 14, "Descale the X200 every six months."), 0.3)])
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoOnPage14, score: 0.1)])
        let tracer = RecordingTracer()
        _ = try await retriever(w, text: text, images: images, tracer: tracer).retrieve("how do I descale it", photo: photo())
        let outcomes = tracer.kinds.compactMap { kind -> RelevanceOutcome? in
            if case .relevance(_, _, let outcome, _, _) = kind { return outcome } else { return nil }
        }
        #expect(outcomes == [.passedOnDistance])
    }

    // MARK: Reading the photo

    @Test func identifiersReadFromTheNameplateJoinTheTypedQuestion() async throws {
        let w = try await world()
        let text = FakeChunkSearch(keywordHits: [scored(chunk("c", 0, "MODEL X200-B S/N 4471-22"), 1)])
        let recognizer = FakeTextRecognizer(lines: ["ACME", "MODEL X200-B", "230V~ 50Hz", "IP54"])
        let result = try await retriever(w, text: text, recognizer: recognizer).retrieve("descale", photo: photo())

        #expect(text.keywordTerms == [["descale", "X200-B"]])
        #expect(result.photo?.identifiers == ["X200-B"])
        #expect(result.relevant, "the model number appears verbatim in a top passage")
        #expect(recognizer.calls == [false])
    }

    @Test func aNameplateAloneIsEnoughToSearchWith() async throws {
        let w = try await world()
        let text = FakeChunkSearch(keywordHits: [scored(chunk("c", 0, "MODEL X200-B S/N 4471-22"), 1)])
        let result = try await retriever(w, text: text, recognizer: FakeTextRecognizer(lines: ["MODEL X200-B"])).retrieve("", photo: photo())
        #expect(text.keywordTerms == [["X200-B"]] && result.relevant)
    }

    @Test func aPhotoWithNoTextAndNoQuestionSearchesOnlyByLook() async throws {
        let w = try await world()
        let text = FakeChunkSearch(vectorHits: [scored(chunk("a", 3, page: 15, "Replace the filter yearly."), 0.1)])
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoOnPage14, score: 0.2)])
        let tracer = RecordingTracer()
        let result = try await retriever(w, text: text, images: images, tracer: tracer).retrieve("  ", photo: photo())

        #expect(text.filters.isEmpty && text.keywordTerms.isEmpty, "no text to search with")
        #expect(!tracer.kinds.contains { if case .queryEmbedded = $0 { true } else { false } })
        #expect(result.images.count == 1 && result.relevant && result.passages.allSatisfy { $0.chunk.docId == "a" })
        #expect(result.bestDistance == nil)
    }

    @Test func aRecognizerThatFailsLeavesTheLookAndTheTypedQuestion() async throws {
        struct Failing: TextRecognizing {
            func recognize(_ image: CGImage, correctLanguage: Bool) async throws -> [RecognizedLine] { throw ExtractionError.unreadable("x") }
        }
        let w = try await world()
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoOnPage14, score: 0.2)])
        let retriever = Retriever(
            embedder: FakeEmbedder(), search: FakeChunkSearch(), repository: w.repo,
            photoSearch: PhotoSearch(features: features, search: images, recognizer: Failing()))
        let result = try await retriever.retrieve("descale", photo: photo())
        #expect(result.photo?.text == "descale" && result.images.count == 1)
    }

    // MARK: Scope and compatibility

    @Test func theImageSearchHonorsThePinnedScopeAndTheFeatureModel() async throws {
        let w = try await world()
        let images = FakeImageSearch()
        _ = try await retriever(w, images: images).retrieve("x", scope: ["a", "b"], photo: photo())
        #expect(images.filters == [SearchFilter(documentIDs: ["a", "b"], embeddingModel: features.identity.tag)])
        #expect(images.vectors.first?.count == features.identity.dimensions)
    }

    @Test func aQuestionWithoutAPhotoIsUnchanged() async throws {
        let w = try await world()
        let text = FakeChunkSearch(vectorHits: [scored(chunk("a", 0, page: 14, "Descale the X200 every six months."), 0.3)])
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoOnPage14, score: 0.1)])
        let recognizer = FakeTextRecognizer(lines: ["MODEL X200-B"])
        let withServices = try await retriever(w, text: text, images: images, recognizer: recognizer).retrieve("how do I descale it")
        let plain = try await Retriever(embedder: FakeEmbedder(), search: text, repository: w.repo).retrieve("how do I descale it")

        #expect(withServices == plain)
        #expect(images.filters.isEmpty && recognizer.calls.isEmpty)
        #expect(withServices.images.isEmpty && withServices.photo == nil)
    }

    @Test func aPhotoIsIgnoredWhenTheRetrieverHasNoPhotoServices() async throws {
        let w = try await world()
        let text = FakeChunkSearch(vectorHits: [scored(chunk("a", 0, page: 14, "Descale the X200 every six months."), 0.3)])
        let result = try await Retriever(embedder: FakeEmbedder(), search: text, repository: w.repo).retrieve("descale", photo: photo())
        #expect(result.photo == nil && result.images.isEmpty && result.relevant)
    }

    // MARK: Tracing

    @Test func thePhotoAndItsImagePositionsAreTraced() async throws {
        let w = try await world()
        let images = FakeImageSearch(hits: [ScoredImage(image: w.photoOnPage14, score: 0.2)])
        let tracer = RecordingTracer()
        _ = try await retriever(
            w, text: FakeChunkSearch(), images: images, recognizer: FakeTextRecognizer(lines: ["MODEL X200-B", "IP54"]), tracer: tracer
        ).retrieve("descale", photo: photo())

        let analyzed = try #require(tracer.events.first { if case .photoAnalyzed = $0.kind { true } else { false } })
        #expect(analyzed.kind == .photoAnalyzed(recognizedLength: "MODEL X200-B\nIP54".count, identifiers: ["X200-B"], dimensions: features.identity.dimensions))
        #expect(analyzed.duration != nil)

        let fusion = try #require(tracer.kinds.compactMap { kind -> [FusionEntry]? in
            if case .fusion(_, _, let entries) = kind { return entries } else { return nil }
        }.first)
        #expect(fusion.allSatisfy { $0.imagePosition != nil && $0.vectorPosition == nil })
        #expect(fusion.map(\.imagePosition) == [0, 1, 2].map { Optional($0) })
    }

    @Test func aTextQuestionHasNoImageFieldsInItsRelevanceEvent() async throws {
        let w = try await world()
        let tracer = RecordingTracer()
        _ = try await retriever(w, tracer: tracer).retrieve("how do I descale it")
        #expect(tracer.kinds.contains(.relevance(bestDistance: nil, threshold: 0.76, outcome: .failed)))
    }
}
