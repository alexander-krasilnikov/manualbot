@preconcurrency import CouchbaseLiteSwift
import Core
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
    /// Photo libraries are far smaller than chunk sets. A spike (since removed with the Vision feature print) found 8 and 16
    /// centroids equally accurate from 10 to 1,000 images.
    public static let imageCentroids: UInt32 = 8

    /// The feature model assumed when none is given: photos share the embedding model of the chunks.
    public static let defaultImageFeatures = EmbedderProfile.embeddingGemma2.identity

    struct Collections {
        let documents: Collection
        let chunks: Collection
        let chats: Collection
        let messages: Collection
        let ingestJobs: Collection
        let images: Collection
        let localMeta: Collection
    }

    /// One index: where it lives, which fields or expression it covers, and the settings the explorer shows.
    struct IndexDefinition {
        let name: String
        let collection: String
        let fields: [String]
        let settings: IndexSummary.Settings
    }

    /// Every index the app creates. `prepare` creates them from this table and the database explorer describes them
    /// from it, so what is shown is what was built.
    static func indexDefinitions(embeddingDimensions: Int, imageDimensions: Int) -> [IndexDefinition] {
        func vector(_ name: String, _ collection: String, field: String, dimensions: Int, centroids: UInt32) -> IndexDefinition {
            IndexDefinition(
                name: name, collection: collection, fields: [field],
                settings: .init(
                    kind: .vector, expression: field, dimensions: dimensions, metric: "cosine", centroids: Int(centroids),
                    encoding: "SQ8"))
        }
        func values(_ name: String, _ collection: String, _ fields: [String]) -> IndexDefinition {
            IndexDefinition(
                name: name, collection: collection, fields: fields,
                settings: .init(kind: .value, expression: fields.joined(separator: ", ")))
        }
        return [
            vector(vectorIndex, chunks, field: "embedding", dimensions: embeddingDimensions, centroids: centroids),
            IndexDefinition(
                name: ftsIndex, collection: chunks, fields: ["text"], settings: .init(kind: .fullText, expression: "text")),
            values("chunks_doc_gen", chunks, ["docId", "generation"]),
            vector(imageVectorIndex, images, field: "features", dimensions: imageDimensions, centroids: imageCentroids),
            values(imageDocGenIndex, images, ["docId", "generation"]),
            values("messages_chat", messages, ["chatId", "createdAt"]),
        ]
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

        let byName: [String: Collection] = [
            documents: collections.documents, chunks: collections.chunks, chats: collections.chats,
            messages: collections.messages, images: collections.images, ingestJobs: collections.ingestJobs,
            localMeta: collections.localMeta,
        ]
        for index in indexDefinitions(embeddingDimensions: embedding.dimensions, imageDimensions: imageFeatures.dimensions) {
            guard let target = byName[index.collection] else { continue }
            switch index.settings.kind {
            case .vector:
                let dimensions = index.settings.dimensions ?? 0
                var config = VectorIndexConfiguration(
                    expression: index.fields[0], dimensions: UInt32(dimensions), centroids: UInt32(index.settings.centroids ?? 0))
                config.metric = .cosine
                config.encoding = .scalarQuantizer(type: .SQ8)
                try ensureVectorIndex(index.name, on: target, config: config, dimensions: dimensions, meta: collections.localMeta)
            case .fullText:
                try target.createIndex(
                    withName: index.name, config: FullTextIndexConfiguration(index.fields, ignoreAccents: true, language: "en"))
            case .value:
                try target.createIndex(withName: index.name, config: ValueIndexConfiguration(index.fields))
            }
        }
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
