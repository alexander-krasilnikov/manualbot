import Foundation

public enum DocumentType: String, Sendable, Codable, CaseIterable {
    case text, markdown, pdf, docx, image
}

/// Identifies the embedding model that produced a vector. Stored on every chunk so that
/// vectors from a different model or dimension are never compared with each other.
public struct EmbeddingModelIdentity: Sendable, Codable, Hashable {
    public var id: String
    public var version: String
    public var dimensions: Int

    public init(id: String, version: String, dimensions: Int) {
        self.id = id
        self.version = version
        self.dimensions = dimensions
    }

    /// e.g. `embeddinggemma-300m@1/768`
    public var tag: String { "\(id)@\(version)/\(dimensions)" }
}

public struct DocumentRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var type: DocumentType
    public var pageCount: Int?
    /// The generation of chunks that retrieval may use. `nil` until the first generation is complete.
    public var activeGeneration: Int?
    public var importedAt: Date
    /// How many photos were found in the document (or 1 for an imported photo). `nil` when there are none.
    public var imageCount: Int?
    /// How many chunks and images the active generation holds, written in the same transaction that activates it.
    /// A device that received the record from sync searches the generation only once it holds that many of each.
    /// `nil` for a record written before these were recorded.
    public var chunkCount: Int?
    public var activeImageCount: Int?

    public init(
        id: String, title: String, type: DocumentType, pageCount: Int? = nil,
        activeGeneration: Int? = nil, importedAt: Date = Date(), imageCount: Int? = nil,
        chunkCount: Int? = nil, activeImageCount: Int? = nil
    ) {
        self.imageCount = imageCount
        self.chunkCount = chunkCount
        self.activeImageCount = activeImageCount
        self.id = id
        self.title = title
        self.type = type
        self.pageCount = pageCount
        self.activeGeneration = activeGeneration
        self.importedAt = importedAt
    }
}

public struct Chunk: Sendable, Codable, Hashable, Identifiable {
    public var docId: String
    public var generation: Int
    public var ordinal: Int
    public var page: Int?
    public var heading: String?
    public var text: String
    public var embedding: [Float]
    /// Tag of the `EmbeddingModelIdentity` that produced `embedding`.
    public var embeddingModel: String
    /// Set on the chunk that stands for an image (its caption, heading and recognized text).
    public var imageId: String?

    /// Deterministic, so re-writing a chunk overwrites it instead of duplicating it.
    public var id: String { Chunk.makeID(docId: docId, generation: generation, ordinal: ordinal) }

    public static func makeID(docId: String, generation: Int, ordinal: Int) -> String {
        "\(docId):\(generation):\(ordinal)"
    }

    /// Reads a chunk ID back into its parts without loading the chunk. `nil` if it is not a chunk ID.
    public static func parseID(_ id: String) -> (docId: String, generation: Int, ordinal: Int)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let generation = Int(parts[parts.count - 2]), let ordinal = Int(parts[parts.count - 1]) else { return nil }
        return (parts.dropLast(2).joined(separator: ":"), generation, ordinal)
    }

    public init(
        docId: String, generation: Int, ordinal: Int, page: Int? = nil, heading: String? = nil,
        text: String, embedding: [Float], embeddingModel: String, imageId: String? = nil
    ) {
        self.imageId = imageId
        self.docId = docId
        self.generation = generation
        self.ordinal = ordinal
        self.page = page
        self.heading = heading
        self.text = text
        self.embedding = embedding
        self.embeddingModel = embeddingModel
    }
}

// MARK: - Chats

public struct ChatRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var pinnedDocIds: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, title: String, pinnedDocIds: [String] = [], createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.pinnedDocIds = pinnedDocIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A reference from an answer to a retrieved chunk. It carries a snapshot of the chunk so it
/// keeps rendering after the document is deleted.
public struct Citation: Sendable, Codable, Hashable {
    public var n: Int
    public var chunkId: String
    public var docId: String
    public var docTitle: String
    public var page: Int?
    public var heading: String?
    public var snippet: String
    /// Set when the cited chunk stands for an image.
    public var imageId: String?

    public init(
        n: Int, chunkId: String, docId: String, docTitle: String, page: Int? = nil,
        heading: String? = nil, snippet: String, imageId: String? = nil
    ) {
        self.imageId = imageId
        self.n = n
        self.chunkId = chunkId
        self.docId = docId
        self.docTitle = docTitle
        self.page = page
        self.heading = heading
        self.snippet = snippet
    }
}

public enum MessageRole: String, Sendable, Codable {
    case user, assistant
}

public struct MessageRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var chatId: String
    public var role: MessageRole
    public var text: String
    public var standaloneQuery: String?
    /// For an answer, the chunks it cites. For a not-found reply, the closest chunks offered as suggestions.
    public var citations: [Citation]
    public var stopped: Bool
    /// The documents did not contain an answer.
    public var notFound: Bool
    public var createdAt: Date
    /// The user attached a photo to this question. The photo itself is stored as a blob next to the message
    /// and read with `ChatRepository.attachment(messageId:)`, so listing messages never loads it.
    public var hasAttachment: Bool
    /// Library images that matched the attached photo, as snapshots that outlive their documents.
    public var imageMatches: [ImageMatch]
    /// The reply lists matches only: the photo had no typed question, so nothing was generated.
    public var matchesOnly: Bool

    public init(
        id: String, chatId: String, role: MessageRole, text: String, standaloneQuery: String? = nil,
        citations: [Citation] = [], stopped: Bool = false, notFound: Bool = false, createdAt: Date = Date(),
        hasAttachment: Bool = false, imageMatches: [ImageMatch] = [], matchesOnly: Bool = false
    ) {
        self.hasAttachment = hasAttachment
        self.imageMatches = imageMatches
        self.matchesOnly = matchesOnly
        self.id = id
        self.chatId = chatId
        self.role = role
        self.text = text
        self.standaloneQuery = standaloneQuery
        self.citations = citations
        self.stopped = stopped
        self.notFound = notFound
        self.createdAt = createdAt
    }

    // Fields added after the first version decode as their default when absent, so older or
    // synced records still load.
    enum CodingKeys: String, CodingKey {
        case id, chatId, role, text, standaloneQuery, citations, stopped, notFound, createdAt
        case hasAttachment, imageMatches, matchesOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        chatId = try c.decode(String.self, forKey: .chatId)
        role = try c.decode(MessageRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        standaloneQuery = try c.decodeIfPresent(String.self, forKey: .standaloneQuery)
        citations = try c.decodeIfPresent([Citation].self, forKey: .citations) ?? []
        stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
        notFound = try c.decodeIfPresent(Bool.self, forKey: .notFound) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        hasAttachment = try c.decodeIfPresent(Bool.self, forKey: .hasAttachment) ?? false
        imageMatches = try c.decodeIfPresent([ImageMatch].self, forKey: .imageMatches) ?? []
        matchesOnly = try c.decodeIfPresent(Bool.self, forKey: .matchesOnly) ?? false
    }
}

// MARK: - Ingestion jobs (device-local, never replicated)

public enum IngestState: String, Sendable, Codable {
    case queued, extracting, recognizingText, analyzingImages, embedding, ready, failed
}

public struct IngestJobRecord: Sendable, Codable, Hashable, Identifiable {
    public var docId: String
    public var targetGeneration: Int
    public var state: IngestState
    public var progress: Double
    /// The next chunk ordinal to embed; lets an interrupted job resume where it stopped.
    public var nextOrdinal: Int
    /// The next image to analyze; lets an interrupted job resume where it stopped.
    public var nextImage: Int
    public var error: String?
    /// Queue order: oldest first.
    public var enqueuedAt: Date
    /// Tag of the embedding model that made the vectors written so far, once there are any. A job that finds another
    /// model installed starts a new generation instead of mixing vectors of two models in one.
    public var embeddingModel: String?

    public var id: String { docId }

    public var isFinished: Bool { state == .ready || state == .failed }

    public init(
        docId: String, targetGeneration: Int, state: IngestState = .queued, progress: Double = 0,
        nextOrdinal: Int = 0, nextImage: Int = 0, error: String? = nil, enqueuedAt: Date = Date(), embeddingModel: String? = nil
    ) {
        self.embeddingModel = embeddingModel
        self.nextImage = nextImage
        self.enqueuedAt = enqueuedAt
        self.docId = docId
        self.targetGeneration = targetGeneration
        self.state = state
        self.progress = progress
        self.nextOrdinal = nextOrdinal
        self.error = error
    }

    // Jobs saved before images existed have no `nextImage`, and jobs saved before models could change have no
    // `embeddingModel`; they decode as 0 and nil.
    enum CodingKeys: String, CodingKey {
        case docId, targetGeneration, state, progress, nextOrdinal, nextImage, error, enqueuedAt, embeddingModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docId = try c.decode(String.self, forKey: .docId)
        targetGeneration = try c.decode(Int.self, forKey: .targetGeneration)
        state = try c.decode(IngestState.self, forKey: .state)
        progress = try c.decode(Double.self, forKey: .progress)
        nextOrdinal = try c.decode(Int.self, forKey: .nextOrdinal)
        nextImage = try c.decodeIfPresent(Int.self, forKey: .nextImage) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        enqueuedAt = try c.decode(Date.self, forKey: .enqueuedAt)
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
    }
}
