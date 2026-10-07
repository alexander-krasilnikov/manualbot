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
    /// Facts about this device's database, such as the dimension each vector index was created with.
    public static let localMeta = "localMeta"
    static let vectorDimensionsDocument = "vectorIndexDimensions"

    public static let vectorIndex = "chunks_vec"
    public static let ftsIndex = "chunks_fts"
    public static let imageVectorIndex = "images_vec"
    public static let imageDocGenIndex = "images_doc_gen"

    /// Vector dimension and index parameters (design D5).
    public static let centroids: UInt32 = 64
    /// Photo libraries are far smaller than passage sets. A spike (since removed with the Vision feature print) found 8 and 16
    /// centroids equally accurate from 10 to 1,000 images.
    public static let imageCentroids: UInt32 = 8

    /// The feature model assumed when none is given: photos share the embedding model of the passages.
    public static let defaultImageFeatures = LiteRTEmbedder.modelIdentity

    struct Collections {
        let documents: Collection
        let chunks: Collection
        let chats: Collection
        let messages: Collection
        let ingestJobs: Collection
        let images: Collection
        let localMeta: Collection
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
            ingestJobs: try collection(ingestJobs), images: try collection(images), localMeta: try collection(localMeta))

        var vector = VectorIndexConfiguration(
            expression: "embedding", dimensions: UInt32(embedding.dimensions), centroids: centroids)
        vector.metric = .cosine
        vector.encoding = .scalarQuantizer(type: .SQ8)
        try ensureVectorIndex(vectorIndex, on: collections.chunks, config: vector, dimensions: embedding.dimensions, meta: collections.localMeta)

        try collections.chunks.createIndex(
            withName: ftsIndex, config: FullTextIndexConfiguration(["text"], ignoreAccents: true, language: "en"))
        try collections.chunks.createIndex(
            withName: "chunks_doc_gen", config: ValueIndexConfiguration(["docId", "generation"]))
        var imageVector = VectorIndexConfiguration(
            expression: "features", dimensions: UInt32(imageFeatures.dimensions), centroids: imageCentroids)
        imageVector.metric = .cosine
        imageVector.encoding = .scalarQuantizer(type: .SQ8)
        try ensureVectorIndex(
            imageVectorIndex, on: collections.images, config: imageVector, dimensions: imageFeatures.dimensions, meta: collections.localMeta)
        try collections.images.createIndex(
            withName: imageDocGenIndex, config: ValueIndexConfiguration(["docId", "generation"]))
        try collections.messages.createIndex(
            withName: "messages_chat", config: ValueIndexConfiguration(["chatId", "createdAt"]))
        return collections
    }

    /// A vector index keeps the dimension it was created with, and silently ignores vectors of another length, so a new
    /// embedding model with a different dimension needs a new index. The dimension each index was created with is
    /// recorded on this device; an index that exists with a different dimension, or with none recorded (made by a
    /// version that did not record it), is deleted and created again. The stored documents are not touched.
    private static func ensureVectorIndex(
        _ name: String, on collection: Collection, config: VectorIndexConfiguration, dimensions: Int, meta: Collection
    ) throws {
        let record = try meta.document(id: vectorDimensionsDocument)
        let recorded = record?.contains(key: name) == true ? record?.int(forKey: name) : nil
        if try collection.indexes().contains(name), recorded != dimensions {
            try collection.deleteIndex(forName: name)
        }
        try collection.createIndex(withName: name, config: config)
        if recorded != dimensions {
            let updated = record?.toMutable() ?? MutableDocument(id: vectorDimensionsDocument)
            updated.setInt(dimensions, forKey: name)
            try meta.save(document: updated)
        }
    }
}
