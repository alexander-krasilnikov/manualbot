@preconcurrency import CouchbaseLiteSwift
import Ports

/// Names of the scope, collections, and indexes. Synced collections are separate from local-only ones.
public enum CouchbaseSchema {
    public static let scope = "manualbot"

    // Sync-ready: these are the collections a future replicator will carry.
    public static let documents = "documents"
    public static let chunks = "chunks"
    public static let chats = "chats"
    public static let messages = "messages"
    public static let images = "images"
    // Device-local: never replicated.
    public static let ingestJobs = "ingestJobs"

    public static let vectorIndex = "chunks_vec"
    public static let ftsIndex = "chunks_fts"
    public static let imageVectorIndex = "images_vec"
    public static let imageDocGenIndex = "images_doc_gen"

    /// Vector dimension and index parameters (design D5).
    public static let centroids: UInt32 = 64
    /// Photo libraries are far smaller than passage sets. A spike (ImageFeaturePrintSpikeTests) found 8 and 16
    /// centroids equally accurate from 10 to 1,000 images.
    public static let imageCentroids: UInt32 = 8

    /// The feature model assumed when none is given: Vision's feature print, revision 2, 768 floats.
    public static let defaultImageFeatures = EmbeddingModelIdentity(id: "vision-featureprint", version: "2", dimensions: 768)

    struct Collections {
        let documents: Collection
        let chunks: Collection
        let chats: Collection
        let messages: Collection
        let ingestJobs: Collection
        let images: Collection
    }

    /// Creates the collections and indexes if they do not exist yet. Safe to call on every launch.
    static func prepare(
        _ database: Database, embedding: EmbeddingModelIdentity, imageFeatures: EmbeddingModelIdentity = defaultImageFeatures
    ) throws -> Collections {
        func collection(_ name: String) throws -> Collection {
            try database.createCollection(name: name, scope: scope)
        }
        let collections = Collections(
            documents: try collection(documents),
            chunks: try collection(chunks),
            chats: try collection(chats),
            messages: try collection(messages),
            ingestJobs: try collection(ingestJobs), images: try collection(images))

        var vector = VectorIndexConfiguration(
            expression: "embedding", dimensions: UInt32(embedding.dimensions), centroids: centroids)
        vector.metric = .cosine
        vector.encoding = .scalarQuantizer(type: .SQ8)
        try collections.chunks.createIndex(withName: vectorIndex, config: vector)

        try collections.chunks.createIndex(
            withName: ftsIndex, config: FullTextIndexConfiguration(["text"], ignoreAccents: true, language: "en"))
        try collections.chunks.createIndex(
            withName: "chunks_doc_gen", config: ValueIndexConfiguration(["docId", "generation"]))
        var imageVector = VectorIndexConfiguration(
            expression: "features", dimensions: UInt32(imageFeatures.dimensions), centroids: imageCentroids)
        imageVector.metric = .cosine
        imageVector.encoding = .scalarQuantizer(type: .SQ8)
        try collections.images.createIndex(withName: imageVectorIndex, config: imageVector)
        try collections.images.createIndex(
            withName: imageDocGenIndex, config: ValueIndexConfiguration(["docId", "generation"]))
        try collections.messages.createIndex(
            withName: "messages_chat", config: ValueIndexConfiguration(["chatId", "createdAt"]))
        return collections
    }
}
