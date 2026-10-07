import CoreGraphics
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

/// One model for words and photos, as with EmbeddingGemma 2: the same identity, so a question's vector can search photos.
private struct JointModel: Embedder, ImageFeaturing {
    let identity = EmbeddingModelIdentity(id: "joint", version: "1", dimensions: 32)
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        try await FakeEmbedder(identity: identity).embed(texts, kind: kind)
    }
    func features(of image: CGImage) async throws -> [Float] { [Float](repeating: 0, count: identity.dimensions) }
}

@Suite struct WordsToPhotosTests {
    private let model = JointModel()

    private func chunk(_ doc: String, _ ordinal: Int, page: Int? = nil, _ text: String, imageId: String? = nil) -> Chunk {
        Chunk(docId: doc, generation: 1, ordinal: ordinal, page: page, text: text,
              embedding: [Float](repeating: 0, count: 32), embeddingModel: model.identity.tag, imageId: imageId)
    }

    /// A manual whose page 9 holds an uncaptioned photo of the drain plug, with the text beside it, and an unrelated page 3.
    private func library() async throws -> (repo: InMemoryDocumentRepository, plug: ImageRecord) {
        let repo = InMemoryDocumentRepository()
        let plug = ImageRecord(docId: "m", generation: 1, n: 0, page: 9, width: 200, height: 200,
                               features: [Float](repeating: 0, count: 32), featureModel: model.identity.tag)
        try await repo.upsert(DocumentRecord(id: "m", title: "Pump manual", type: .pdf))
        try await repo.writeChunks([
            chunk("m", 0, page: 3, "Switch the pump off before servicing."),
            chunk("m", 1, page: 9, "Unscrew the plug at the bottom of the housing and let the oil drain."),
            chunk("m", 2, page: 9, "", imageId: plug.id),
        ])
        try await repo.activate(generation: 1, for: "m")
        return (repo, plug)
    }

    private func retriever(
        _ repo: InMemoryDocumentRepository, text: FakeChunkSearch = FakeChunkSearch(), images: FakeImageSearch,
        tracer: any Tracer = NoTracer(), configuration: RetrievalConfiguration = .standIn
    ) -> Retriever {
        Retriever(
            embedder: model, search: text, repository: repo, configuration: configuration, tracer: tracer,
            photoSearch: PhotoSearch(features: model, search: images, recognizer: FakeTextRecognizer()))
    }

    private func scored(_ chunk: Chunk, _ distance: Double) -> ScoredChunk { ScoredChunk(chunk: chunk, score: distance) }

    @Test("Passage reached through words that describe a photo")
    func aPassageIsReachedThroughWordsThatDescribeAPhoto() async throws {
        let (repo, plug) = try await library()
        let images = FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.18)])
        let result = try await retriever(repo, images: images).retrieve("where is the drain plug")

        #expect(Set(result.passages.map(\.id)) == ["m:1:1", "m:1:2"], "the passages of page 9: \(result.passages.map(\.id))")
        #expect(result.passages.allSatisfy { $0.wordsRank != nil && $0.imageRank == nil && $0.distance == nil })
        #expect(result.images.map(\.id) == [plug.id])
        #expect(result.images.first?.viaWords == true && result.images.first?.distance == 0.18)
        #expect(result.images.first?.documentTitle == "Pump manual")
    }

    @Test func theQuestionsOwnVectorSearchesThePhotosOfTheSameModel() async throws {
        let (repo, plug) = try await library()
        let images = FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.18)])
        _ = try await retriever(repo, images: images).retrieve("where is the drain plug", scope: ["m"])
        let expected = try await model.embed(["where is the drain plug"], kind: .query)[0]
        #expect(images.vectors == [expected])
        #expect(images.filters == [SearchFilter(documentIDs: ["m"], embeddingModel: model.identity.tag)])
    }

    @Test("Words that only resemble a photo")
    func wordsThatOnlyResembleAPhotoDoNotMakeTheQuestionRelevant() async throws {
        let (repo, plug) = try await library()
        // The text is far beyond the threshold, but a photo matches the words closely.
        let text = FakeChunkSearch(vectorHits: [scored(chunk("m", 0, page: 3, "Switch the pump off before servicing."), 0.9)])
        let images = FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.05)])
        let tracer = RecordingTracer()
        let result = try await retriever(repo, text: text, images: images, tracer: tracer).retrieve("what colour is the sky")

        #expect(!result.relevant, "a match between words and a photo must not pass the gate")
        #expect(tracer.kinds.contains(.relevance(bestDistance: 0.9, threshold: 0.76, outcome: .failed)))
        #expect(!result.closest().isEmpty, "the closest passages are still offered")
    }

    @Test func aPhotoBeyondTheThresholdIsNotAMatch() async throws {
        let (repo, plug) = try await library()
        let images = FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.4)])
        let result = try await retriever(repo, images: images).retrieve("where is the drain plug")
        #expect(result.images.isEmpty && result.passages.isEmpty)
    }

    @Test func theThresholdIsConfigurable() async throws {
        let (repo, plug) = try await library()
        let images = FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.3)])
        let strict = try await retriever(repo, images: images, configuration: .init(textToImageMaxDistance: 0.2)).retrieve("drain plug")
        let loose = try await retriever(repo, images: images, configuration: .init(textToImageMaxDistance: 0.35)).retrieve("drain plug")
        #expect(strict.images.isEmpty && loose.images.count == 1)
    }

    @Test func aPassageFoundByTextAndThroughAPhotoRanksAboveOneFoundByText() async throws {
        let (repo, plug) = try await library()
        let text = FakeChunkSearch(vectorHits: [
            scored(chunk("m", 0, page: 3, "Switch the pump off before servicing."), 0.5),
            scored(chunk("m", 1, page: 9, "Unscrew the plug at the bottom of the housing and let the oil drain."), 0.55),
        ])
        let images = FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.18)])
        let result = try await retriever(repo, text: text, images: images).retrieve("where is the drain plug")
        #expect(result.passages.first?.id == "m:1:1", "\(result.passages.map(\.id))")
        let first = try #require(result.passages.first)
        #expect(first.distance == 0.55 && first.wordsRank != nil)
        #expect(Set(result.passages.map(\.id)).count == result.passages.count)
    }

    @Test func aPhotoInTheQuestionKeepsItsOwnListAndTheWordsListIsAddedAfterIt() async throws {
        let (repo, plug) = try await library()
        let images = FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.18)])
        let tracer = RecordingTracer()
        let photo = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let result = try await retriever(repo, images: images, tracer: tracer).retrieve("drain plug", photo: photo)

        #expect(images.vectors.count == 2, "one search by the photo and one by the words")
        #expect(result.passages.allSatisfy { $0.imageRank != nil && $0.wordsRank != nil })
        #expect(result.images.map(\.id) == [plug.id], "the same photo is listed once")
        #expect(result.images.first?.viaWords == false, "listed as the photo's match, which comes first")
        let fusion = try #require(tracer.kinds.compactMap { kind -> [FusionEntry]? in
            if case .fusion(_, _, let entries) = kind { return entries } else { return nil }
        }.first)
        #expect(fusion.allSatisfy { $0.imagePosition != nil && $0.wordsPosition != nil })
    }

    @Test func wordsAreNotComparedWithPhotosOfAnotherModel() async throws {
        let (repo, plug) = try await library()
        let images = FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.1)])
        // The embedder and the photo model are different models here, so their vectors are not comparable.
        let other = Retriever(
            embedder: FakeEmbedder(), search: FakeChunkSearch(), repository: repo,
            photoSearch: PhotoSearch(features: FakeImageFeaturer(), search: images, recognizer: FakeTextRecognizer()))
        let result = try await other.retrieve("where is the drain plug")
        #expect(images.vectors.isEmpty && result.images.isEmpty)
    }

    @Test func theWordsSearchIsTracedWithItsOutcome() async throws {
        let (repo, plug) = try await library()
        let tracer = RecordingTracer()
        _ = try await retriever(repo, images: FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.18)]), tracer: tracer).retrieve("drain plug")
        #expect(tracer.kinds.contains(.wordsMatchedPhotos(matches: 1, bestDistance: 0.18, threshold: 0.25)))
        let none = RecordingTracer()
        _ = try await retriever(repo, images: FakeImageSearch(hits: [ScoredImage(image: plug, score: 0.6)]), tracer: none).retrieve("drain plug")
        #expect(none.kinds.contains(.wordsMatchedPhotos(matches: 0, bestDistance: 0.6, threshold: 0.25)))
    }

    @Test func aLibraryWithoutPhotosQueriesNothingToShow() async throws {
        let (repo, _) = try await library()
        let result = try await retriever(repo, images: FakeImageSearch(hits: [])).retrieve("drain plug")
        #expect(result.images.isEmpty)
    }
}
