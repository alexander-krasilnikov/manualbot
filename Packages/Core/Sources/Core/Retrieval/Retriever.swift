import CoreGraphics
import Foundation
import Ports

public struct RetrievalConfiguration: Sendable, Equatable {
    /// Candidates taken from each search before fusion.
    public var candidatesPerSearch: Int
    /// Passages returned after fusion.
    public var resultLimit: Int
    /// A result is relevant when its best cosine distance is at most this. Tuned on the evaluation set (task 6.3) with real EmbeddingGemma output: answerable questions reach at most 0.66, off-topic ones start at 0.87, and every threshold from 0.68 to 0.86 separates them perfectly; 0.76 sits in the middle of that range.
    public var maxDistance: Double
    /// Passages offered as suggestions when nothing is relevant.
    public var suggestionCount: Int
    /// An image matches the question's photo when its cosine distance (Vision feature print) is at most this.
    /// Provisional: tuned with `ImageEvalTests` on a stand-in set, not on photos of real equipment. On 54 cropped,
    /// rotated, re-lit and noisy variants of 18 real landscape photographs plus 7 unrelated ones, the right photo
    /// was always in the top three; true matches were at most 0.30 away (90% within 0.20) and unrelated photos at
    /// least 0.23. At 0.25 this keeps 96% of the matches and rejects 6 of the 7 unrelated photos. It leans toward
    /// keeping matches, because field photos taken from another angle sit farther from their reference than these
    /// variants do. Re-tune on field photos before relying on it. (Generated abstract scenes cannot be told apart
    /// by distance at all: unrelated ones came as close as 0.075.)
    public var imageMaxDistance: Double
    /// Images taken from the image index before the distance threshold is applied.
    public var imageCandidates: Int
    /// Text passages taken from the page or section of each matching image, besides the image's own passage.
    public var passagesPerImage: Int

    public init(
        candidatesPerSearch: Int = 20, resultLimit: Int = 6, maxDistance: Double = 0.76, suggestionCount: Int = 3,
        imageMaxDistance: Double = 0.25, imageCandidates: Int = 10, passagesPerImage: Int = 4
    ) {
        self.candidatesPerSearch = candidatesPerSearch
        self.resultLimit = resultLimit
        self.maxDistance = maxDistance
        self.suggestionCount = suggestionCount
        self.imageMaxDistance = imageMaxDistance
        self.imageCandidates = imageCandidates
        self.passagesPerImage = passagesPerImage
    }
}

public struct RetrievedPassage: Sendable, Equatable, Identifiable {
    public var chunk: Chunk
    public var documentTitle: String
    /// Cosine distance from the query, when the vector search found this passage.
    public var distance: Double?
    /// Zero-based position in the keyword results, when the keyword search found it.
    public var keywordRank: Int?
    public var fusedScore: Double
    /// Zero-based position among the passages reached through the question's photo, when it reached this one.
    public var imageRank: Int? = nil

    public var id: String { chunk.id }
}

/// A library image that matched the question's photo.
public struct RetrievedImage: Sendable, Equatable, Identifiable {
    public var image: ImageRecord
    public var documentTitle: String
    /// Cosine distance from the photo (0 = identical).
    public var distance: Double

    public var id: String { image.id }
}

public struct RetrievalResult: Sendable, Equatable {
    /// Fused passages, best first. Only use them to answer when `relevant` is true.
    public var passages: [RetrievedPassage]
    public var relevant: Bool
    /// Best cosine distance seen, or `nil` if the library has nothing comparable.
    public var bestDistance: Double?
    /// Library images within the image distance threshold of the question's photo, best first.
    public var images: [RetrievedImage] = []
    /// What was read from the question's photo, when it had one.
    public var photo: PhotoQuery?

    /// The nearest passages, offered to the user when nothing was relevant enough to answer from.
    public func closest(_ count: Int = 3) -> [RetrievedPassage] { Array(passages.prefix(count)) }
}

/// What a photo question needs besides text search: reading the photo, comparing it with library images.
public struct PhotoSearch: Sendable {
    public var features: any ImageFeaturing
    public var search: any ImageSearching
    public var recognizer: any TextRecognizing

    public init(features: any ImageFeaturing, search: any ImageSearching, recognizer: any TextRecognizing) {
        self.features = features
        self.search = search
        self.recognizer = recognizer
    }
}

/// Finds the passages that best answer a question: semantic (vector) and exact (keyword) search,
/// merged, then a relevance check. A question can come with a photo, which adds text read from it and
/// the pages of similar-looking library images.
public struct Retriever: Sendable {
    private let embedder: any Embedder
    private let search: any ChunkSearching
    private let repository: any DocumentRepository
    private let tracer: any Tracer
    private let photoSearch: PhotoSearch?
    public let configuration: RetrievalConfiguration

    public init(
        embedder: any Embedder, search: any ChunkSearching, repository: any DocumentRepository,
        configuration: RetrievalConfiguration = .init(), tracer: any Tracer = NoTracer(), photoSearch: PhotoSearch? = nil
    ) {
        self.photoSearch = photoSearch
        self.embedder = embedder
        self.search = search
        self.repository = repository
        self.configuration = configuration
        self.tracer = tracer
    }

    /// `photo` is analyzed only when this retriever was given photo services; otherwise the question is searched as text.
    public func retrieve(_ question: String, scope: Set<String>? = nil, photo: CGImage? = nil) async throws -> RetrievalResult {
        let filter = SearchFilter(documentIDs: scope, embeddingModel: embedder.identity.tag)

        var query = question
        var photoQuery: PhotoQuery?
        var imageMatches: [ScoredImage] = []
        if let photo, let photoSearch {
            let analysis = try await analyze(photo, typed: question, with: photoSearch, scope: scope)
            query = analysis.query.text
            photoQuery = analysis.query
            imageMatches = analysis.matches
        }

        // A photo with nothing readable and nothing typed has no text to search with.
        var vectorHits: [ScoredChunk] = []
        var keywordHits: [ScoredChunk] = []
        var terms: [String] = []
        if photoQuery == nil || !query.isEmpty {
            let vector = try await tracer.measure(
                { try await embedder.embed([query], kind: .query)[0] }, event: { .queryEmbedded(dimensions: $0.count) })
            terms = QueryTerms.keywords(from: query)
            if terms.isEmpty { tracer.emit(.keywordSearchSkipped) }

            async let semantic = search.vectorSearch(vector, limit: configuration.candidatesPerSearch, filter: filter)
            async let keyword = terms.isEmpty ? [] : search.keywordSearch(terms: terms, limit: configuration.candidatesPerSearch, filter: filter)
            (vectorHits, keywordHits) = try await (semantic, keyword)
        }

        let reached = try await passages(reachedBy: imageMatches)
        let titles = try await titles(for: Set((vectorHits + keywordHits).map(\.chunk.docId) + reached.map(\.docId) + imageMatches.map(\.image.docId)))

        var byID = Dictionary((vectorHits + keywordHits).map { ($0.chunk.id, $0.chunk) }, uniquingKeysWith: { a, _ in a })
        for chunk in reached where byID[chunk.id] == nil { byID[chunk.id] = chunk }
        var lists = [vectorHits.map(\.chunk.id), keywordHits.map(\.chunk.id)]
        if photoQuery != nil { lists.append(reached.map(\.id)) }
        let fused = RankFusion.fuse(lists, limit: configuration.resultLimit)

        let distances = Dictionary(vectorHits.map { ($0.chunk.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let passages = fused.compactMap { item -> RetrievedPassage? in
            guard let chunk = byID[item.id] else { return nil }
            return RetrievedPassage(
                chunk: chunk, documentTitle: titles[chunk.docId] ?? "Untitled", distance: distances[item.id],
                keywordRank: item.ranks[1], fusedScore: item.score, imageRank: item.ranks.count > 2 ? item.ranks[2] : nil)
        }

        if tracer.isEnabled {
            let ranks = Dictionary(uniqueKeysWithValues: fused.map { ($0.id, $0.ranks) })
            tracer.emit(.fusion(method: "Reciprocal Rank Fusion", k: RankFusion.defaultK, entries: passages.map { passage in
                FusionEntry(
                    chunkID: passage.chunk.id, documentTitle: passage.documentTitle,
                    vectorPosition: ranks[passage.chunk.id]?[0], keywordPosition: passage.keywordRank,
                    imagePosition: passage.imageRank, distance: passage.distance, score: passage.fusedScore)
            }))
        }

        let best = vectorHits.map(\.score).min()
        let bestImage = imageMatches.map(\.score).min()
        let outcome = relevance(best: best, passages: passages, terms: terms, bestImage: bestImage)
        tracer.emit(.relevance(
            bestDistance: best, threshold: configuration.maxDistance, outcome: outcome,
            bestImageDistance: photoQuery == nil ? nil : bestImage,
            imageThreshold: photoQuery == nil ? nil : configuration.imageMaxDistance))

        let images = imageMatches.map { RetrievedImage(image: $0.image, documentTitle: titles[$0.image.docId] ?? "Untitled", distance: $0.score) }
        return RetrievalResult(passages: passages, relevant: outcome != .failed, bestDistance: best, images: images, photo: photoQuery)
    }

    // MARK: Photo

    /// Reads the photo (text and look at the same time) and finds the library images that resemble it.
    private func analyze(
        _ photo: CGImage, typed: String, with services: PhotoSearch, scope: Set<String>?
    ) async throws -> (query: PhotoQuery, matches: [ScoredImage]) {
        let started = tracer.isEnabled ? ContinuousClock.now : nil
        async let lines = services.recognizer.recognize(photo, correctLanguage: false)
        async let vector = services.features.features(of: photo)
        // Text that cannot be read still leaves the photo's look to search with.
        let recognized = (try? await lines)?.map(\.text) ?? []
        let features = try await vector
        let query = PhotoQuery(typed: typed, recognizedLines: recognized)
        if let started {
            tracer.emit(
                duration: started.duration(to: .now).seconds,
                .photoAnalyzed(recognizedLength: query.recognizedText.count, identifiers: query.identifiers, dimensions: features.count))
        }
        let filter = SearchFilter(documentIDs: scope, embeddingModel: services.features.identity.tag)
        let hits = try await services.search.imageSearch(features, limit: configuration.imageCandidates, filter: filter)
        return (query, hits.filter { $0.score <= configuration.imageMaxDistance })
    }

    /// For each matching image, best first: the passage that stands for the image, then the text on its page
    /// (PDF) or under its heading (Word). The result is one ranked list for fusion.
    private func passages(reachedBy matches: [ScoredImage]) async throws -> [Chunk] {
        var reached: [Chunk] = []
        var seen = Set<String>()
        for match in matches {
            let image = match.image
            let candidates: [Chunk]
            if let page = image.page {
                candidates = try await repository.activeChunks(docId: image.docId, page: page)
            } else if let heading = image.heading {
                candidates = try await repository.activeChunks(docId: image.docId, heading: heading)
            } else {
                candidates = try await repository.activeChunks(docId: image.docId)
            }
            let own = candidates.filter { $0.imageId == image.id }
            // A photo document has nothing but its own passage; for a document, text beside the image comes next.
            let beside = candidates.filter { $0.imageId == nil }.prefix(configuration.passagesPerImage)
            for chunk in own + beside where seen.insert(chunk.id).inserted { reached.append(chunk) }
        }
        return reached
    }

    private func titles(for docIds: Set<String>) async throws -> [String: String] {
        var titles: [String: String] = [:]
        for docId in docIds { titles[docId] = try await repository.document(id: docId)?.title }
        return titles
    }

    /// Relevant when the closest passage is near enough in meaning, or when an identifier from the
    /// question (an error code, a part number) appears verbatim in one of the top passages.
    func relevance(best: Double?, passages: [RetrievedPassage], terms: [String], bestImage: Double? = nil) -> RelevanceOutcome {
        if let best, best <= configuration.maxDistance { return .passedOnDistance }
        let codes = QueryTerms.codes(in: terms)
        for passage in passages.prefix(configuration.suggestionCount) {
            if let code = codes.first(where: { QueryTerms.contains(passage.chunk.text, code: $0) }) {
                return .passedOnIdentifier(code)
            }
        }
        if let bestImage, bestImage <= configuration.imageMaxDistance { return .passedOnImage(bestImage) }
        return .failed
    }
}
