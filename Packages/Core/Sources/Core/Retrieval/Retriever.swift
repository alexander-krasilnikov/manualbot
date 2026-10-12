import CoreGraphics
import Foundation
import Ports

public struct RetrievalConfiguration: Sendable, Equatable {
    /// Candidates taken from each search before fusion.
    public var candidatesPerSearch: Int
    /// Chunks returned after fusion.
    public var resultLimit: Int
    /// A result is relevant when its best cosine distance is at most this. Tuned with `RealEvalTests` on the evaluation set
    /// with real EmbeddingGemma 2 output (256 dimensions, chunks of 130 tokens): answerable questions reach at most 0.239,
    /// off-topic ones start at 0.323, and every threshold from 0.24 to 0.32 separates them perfectly; 0.28 sits in the
    /// middle of that range. Distances of this model are on a smaller scale than its predecessor's (0.66 and 0.87). The set
    /// has only six off-topic questions, so re-check this on a larger one before leaning on the margin.
    public var maxDistance: Double
    /// Chunks offered as suggestions when nothing is relevant.
    public var suggestionCount: Int
    /// An image matches the question's photo when its cosine distance (EmbeddingGemma 2, 256 dimensions) is at most this.
    /// Provisional: tuned with `ImageEvalTests` on a stand-in set, not on photos of real equipment. The set is 14
    /// Wikimedia Commons photos of equipment (pumps, valves, motors, breakers…) and, as queries, a *different* photo of the
    /// same kind of thing plus 6 photos of unrelated subjects. That is harder than photographing the same unit again:
    /// the right photo was in the top three for 12 of 14 (86%). Right matches were at most 0.31 away (median 0.17, 90% within
    /// 0.27) and the nearest library photo for unrelated photos at least 0.21 (median 0.28), so the two overlap. At 0.25 this
    /// keeps 71% of the matches and rejects 83% of the unrelated photos. Re-shots of the same object are far closer (the
    /// generated set: at most 0.054). Re-tune on field photos before relying on it.
    public var imageMaxDistance: Double
    /// Typed words match a photo by meaning when the cosine distance between the question's vector and the photo's is at
    /// most this. A separate scale from `imageMaxDistance`: words and pictures sit farther apart than two pictures do.
    /// Provisional, on the same stand-in set: for 28 descriptions of the 14 photos ("a ball valve", "photo of a ball
    /// valve") the right photo was always in the top three (26 times first), at distances of at most 0.276 (median 0.22);
    /// 4 descriptions of things no photo shows came no nearer than 0.327 (median 0.37). Every threshold from 0.28 to 0.32
    /// separates them; 0.30 is the middle. Never makes a question relevant on its own.
    public var textToImageMaxDistance: Double
    /// Images taken from the image index before the distance threshold is applied.
    public var imageCandidates: Int
    /// Text chunks taken from the page or section of each matching image, besides the image's own chunk.
    public var chunksPerImage: Int

    public init(
        candidatesPerSearch: Int = 20, resultLimit: Int = 6, maxDistance: Double = 0.28, suggestionCount: Int = 3,
        imageMaxDistance: Double = 0.25, textToImageMaxDistance: Double = 0.30, imageCandidates: Int = 10, chunksPerImage: Int = 4
    ) {
        self.candidatesPerSearch = candidatesPerSearch
        self.resultLimit = resultLimit
        self.maxDistance = maxDistance
        self.suggestionCount = suggestionCount
        self.imageMaxDistance = imageMaxDistance
        self.textToImageMaxDistance = textToImageMaxDistance
        self.imageCandidates = imageCandidates
        self.chunksPerImage = chunksPerImage
    }
}

public struct RetrievedChunk: Sendable, Equatable, Identifiable {
    public var chunk: Chunk
    public var documentTitle: String
    /// Cosine distance from the query, when the vector search found this chunk.
    public var distance: Double?
    /// Zero-based position in the keyword results, when the keyword search found it.
    public var keywordRank: Int?
    public var fusedScore: Double
    /// Zero-based position among the chunks reached through the question's photo, when it reached this one.
    public var imageRank: Int? = nil
    /// Zero-based position among the chunks reached through photos that matched the question's words, when one reached this.
    public var wordsRank: Int? = nil

    public var id: String { chunk.id }
}

/// A library image that matched the question's photo.
public struct RetrievedImage: Sendable, Equatable, Identifiable {
    public var image: ImageRecord
    public var documentTitle: String
    /// Cosine distance from the photo (0 = identical), or from the question's words when `viaWords`.
    public var distance: Double
    /// Matched the typed words by meaning, not the question's photo.
    public var viaWords = false

    public var id: String { image.id }
}

public struct RetrievalResult: Sendable, Equatable {
    /// Fused chunks, best first. Only use them to answer when `relevant` is true.
    public var chunks: [RetrievedChunk]
    public var relevant: Bool
    /// Best cosine distance seen, or `nil` if the library has nothing comparable.
    public var bestDistance: Double?
    /// Library images within the image distance threshold of the question's photo, best first.
    public var images: [RetrievedImage] = []
    /// What was read from the question's photo, when it had one.
    public var photo: PhotoQuery?

    /// The nearest chunks, offered to the user when nothing was relevant enough to answer from.
    public func closest(_ count: Int = 3) -> [RetrievedChunk] { Array(chunks.prefix(count)) }
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

/// Finds the chunks that best answer a question: semantic (vector) and exact (keyword) search,
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
        var wordMatches: [ScoredImage] = []
        var terms: [String] = []
        if photoQuery == nil || !query.isEmpty {
            let vector = try await tracer.measure(
                { try await embedder.embed([query], kind: .query)[0] }, event: { .queryEmbedded(dimensions: $0.count) })
            terms = QueryTerms.keywords(from: query)
            if terms.isEmpty { tracer.emit(.keywordSearchSkipped) }

            async let semantic = search.vectorSearch(vector, limit: configuration.candidatesPerSearch, filter: filter)
            async let keyword = terms.isEmpty ? [] : search.keywordSearch(terms: terms, limit: configuration.candidatesPerSearch, filter: filter)
            async let byWords = photosMatching(words: vector, scope: scope)
            (vectorHits, keywordHits, wordMatches) = try await (semantic, keyword, byWords)
        }

        let reached = try await chunks(reachedBy: imageMatches)
        let reachedByWords = try await chunks(reachedBy: wordMatches)
        let titles = try await titles(for: Set(
            (vectorHits + keywordHits).map(\.chunk.docId) + reached.map(\.docId) + reachedByWords.map(\.docId)
                + (imageMatches + wordMatches).map(\.image.docId)))

        var byID = Dictionary((vectorHits + keywordHits).map { ($0.chunk.id, $0.chunk) }, uniquingKeysWith: { a, _ in a })
        for chunk in reached + reachedByWords where byID[chunk.id] == nil { byID[chunk.id] = chunk }
        // List positions: 0 vector, 1 keyword, then the photo's list when the question had a photo, then the words' list.
        var lists = [vectorHits.map(\.chunk.id), keywordHits.map(\.chunk.id)]
        var photoList: Int?, wordsList: Int?
        if photoQuery != nil { photoList = lists.count; lists.append(reached.map(\.id)) }
        if !wordMatches.isEmpty { wordsList = lists.count; lists.append(reachedByWords.map(\.id)) }
        let fused = RankFusion.fuse(lists, limit: configuration.resultLimit)

        let distances = Dictionary(vectorHits.map { ($0.chunk.id, $0.score) }, uniquingKeysWith: { a, _ in a })
        let chunks = fused.compactMap { item -> RetrievedChunk? in
            guard let chunk = byID[item.id] else { return nil }
            return RetrievedChunk(
                chunk: chunk, documentTitle: titles[chunk.docId] ?? "Untitled", distance: distances[item.id],
                keywordRank: item.ranks[1], fusedScore: item.score,
                imageRank: photoList.flatMap { item.ranks[$0] }, wordsRank: wordsList.flatMap { item.ranks[$0] })
        }

        if tracer.isEnabled {
            let ranks = Dictionary(uniqueKeysWithValues: fused.map { ($0.id, $0.ranks) })
            tracer.emit(.fusion(method: "Reciprocal Rank Fusion", k: RankFusion.defaultK, entries: chunks.map { retrieved in
                FusionEntry(
                    chunkID: retrieved.chunk.id, documentTitle: retrieved.documentTitle,
                    vectorPosition: ranks[retrieved.chunk.id]?[0], keywordPosition: retrieved.keywordRank,
                    imagePosition: retrieved.imageRank, wordsPosition: retrieved.wordsRank, distance: retrieved.distance,
                    score: retrieved.fusedScore)
            }))
        }

        let best = vectorHits.map(\.score).min()
        let bestImage = imageMatches.map(\.score).min()
        let outcome = relevance(best: best, chunks: chunks, terms: terms, bestImage: bestImage)
        tracer.emit(.relevance(
            bestDistance: best, threshold: configuration.maxDistance, outcome: outcome,
            bestImageDistance: photoQuery == nil ? nil : bestImage,
            imageThreshold: photoQuery == nil ? nil : configuration.imageMaxDistance))

        // Photos that matched the question's photo come first; photos that only matched its words follow.
        var images = imageMatches.map { RetrievedImage(image: $0.image, documentTitle: titles[$0.image.docId] ?? "Untitled", distance: $0.score) }
        let alreadyShown = Set(images.map(\.id))
        images += wordMatches.filter { !alreadyShown.contains($0.image.id) }.map {
            RetrievedImage(image: $0.image, documentTitle: titles[$0.image.docId] ?? "Untitled", distance: $0.score, viaWords: true)
        }
        return RetrievalResult(chunks: chunks, relevant: outcome != .failed, bestDistance: best, images: images, photo: photoQuery)
    }

    // MARK: Photo

    /// The library's photos that the question's words describe, by meaning. Only possible when the same model made
    /// the question's vector and the photos' (otherwise the two are not comparable and nothing is searched).
    private func photosMatching(words vector: [Float], scope: Set<String>?) async throws -> [ScoredImage] {
        guard let services = photoSearch, services.features.identity == embedder.identity else { return [] }
        let filter = SearchFilter(documentIDs: scope, embeddingModel: services.features.identity.tag)
        let hits = try await TraceContext.$imageQueryIsWords.withValue(true) {
            try await services.search.imageSearch(vector, limit: configuration.imageCandidates, filter: filter)
        }
        let matches = hits.filter { $0.score <= configuration.textToImageMaxDistance }
        tracer.emit(.wordsMatchedPhotos(matches: matches.count, bestDistance: hits.map(\.score).min(), threshold: configuration.textToImageMaxDistance))
        return matches
    }

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

    /// For each matching image, best first: the chunk that stands for the image, then the text on its page
    /// (PDF) or under its heading (Word). The result is one ranked list for fusion.
    private func chunks(reachedBy matches: [ScoredImage]) async throws -> [Chunk] {
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
            // A photo document has nothing but its own chunk; for a document, text beside the image comes next.
            let beside = candidates.filter { $0.imageId == nil }.prefix(configuration.chunksPerImage)
            for chunk in own + beside where seen.insert(chunk.id).inserted { reached.append(chunk) }
        }
        return reached
    }

    private func titles(for docIds: Set<String>) async throws -> [String: String] {
        var titles: [String: String] = [:]
        for docId in docIds { titles[docId] = try await repository.document(id: docId)?.title }
        return titles
    }

    /// Relevant when the closest chunk is near enough in meaning, or when an identifier from the
    /// question (an error code, a part number) appears verbatim in one of the top chunks.
    func relevance(best: Double?, chunks: [RetrievedChunk], terms: [String], bestImage: Double? = nil) -> RelevanceOutcome {
        if let best, best <= configuration.maxDistance { return .passedOnDistance }
        let codes = QueryTerms.codes(in: terms)
        for retrieved in chunks.prefix(configuration.suggestionCount) {
            if let code = codes.first(where: { QueryTerms.contains(retrieved.chunk.text, code: $0) }) {
                return .passedOnIdentifier(code)
            }
        }
        if let bestImage, bestImage <= configuration.imageMaxDistance { return .passedOnImage(bestImage) }
        return .failed
    }
}
