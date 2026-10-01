@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports

public enum CouchbaseStoreError: Error, Equatable {
    case documentNotFound(String)
    case malformedDocument(String)
}

/// Couchbase Lite implementation of `DocumentRepository`, plus the chat and job records.
public actor CouchbaseDocumentRepository: DocumentRepository, IngestJobStore, ChatRepository {
    let database: Database
    let collections: CouchbaseSchema.Collections
    private let embedding: EmbeddingModelIdentity
    private let originalsCache: URL

    /// Opens (or creates) the database in `directory` and prepares the schema.
    /// `originalsCache` is where stored originals are materialized as plain files on demand.
    public init(
        directory: URL, originalsCache: URL, name: String = "manualbot", embedding: EmbeddingModelIdentity
    ) throws {
        self.originalsCache = originalsCache
        try CouchbaseBootstrap.enableVectorSearch()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = DatabaseConfiguration()
        config.directory = directory.path
        database = try Database(name: name, config: config)
        collections = try CouchbaseSchema.prepare(database, embedding: embedding)
        self.embedding = embedding
    }

    public func close() throws { try database.close() }

    // MARK: Documents

    public func upsert(_ document: DocumentRecord) throws {
        let doc = try collections.documents.document(id: document.id)?.toMutable()
            ?? MutableDocument(id: document.id)
        doc.setString(document.title, forKey: "title")
        doc.setString(document.type.rawValue, forKey: "type")
        Self.set(document.pageCount, forKey: "pageCount", in: doc)
        Self.set(document.activeGeneration, forKey: "activeGeneration", in: doc)
        doc.setDouble(document.importedAt.timeIntervalSince1970, forKey: "importedAt")
        try collections.documents.save(document: doc)
    }

    public func document(id: String) throws -> DocumentRecord? {
        try collections.documents.document(id: id).map(Self.record(from:))
    }

    public func documents() throws -> [DocumentRecord] {
        let query = try database.createQuery("SELECT meta().id AS id FROM \(CouchbaseSchema.scope).documents")
        return try query.execute().allResults()
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try collections.documents.document(id: $0) }
            .map(Self.record(from:))
            .sorted { $0.importedAt < $1.importedAt }
    }

    // MARK: Chunks

    public func writeChunks(_ chunks: [Chunk]) throws {
        try database.inBatch {
            for chunk in chunks {
                let doc = MutableDocument(id: chunk.id)
                doc.setString(chunk.docId, forKey: "docId")
                doc.setInt(chunk.generation, forKey: "generation")
                doc.setInt(chunk.ordinal, forKey: "ordinal")
                Self.set(chunk.page, forKey: "page", in: doc)
                if let heading = chunk.heading { doc.setString(heading, forKey: "heading") }
                doc.setString(chunk.text, forKey: "text")
                doc.setValue(chunk.embedding, forKey: "embedding")
                doc.setString(chunk.embeddingModel, forKey: "embeddingModel")
                doc.setInt(chunk.embedding.count, forKey: "dims")
                try collections.chunks.save(document: doc)
            }
        }
    }

    public func chunks(docId: String, generation: Int) throws -> [Chunk] {
        let query = try database.createQuery(
            "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).chunks WHERE docId = $docId AND generation = $generation")
        query.parameters = Parameters().setString(docId, forName: "docId").setInt(generation, forName: "generation")
        return try query.execute().allResults()
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try collections.chunks.document(id: $0) }
            .map(Self.chunk(from:))
            .sorted { $0.ordinal < $1.ordinal }
    }

    public func activeChunks(docId: String) throws -> [Chunk] {
        guard let generation = try document(id: docId)?.activeGeneration else { return [] }
        return try chunks(docId: docId, generation: generation)
    }

    public func activate(generation: Int, for docId: String) throws {
        guard let doc = try collections.documents.document(id: docId)?.toMutable() else {
            throw CouchbaseStoreError.documentNotFound(docId)
        }
        let stale = try chunkIDs(docId: docId, excludingGeneration: generation)
        // One transaction: readers see either the old generation or the new one, never a mix.
        try database.inBatch {
            doc.setInt(generation, forKey: "activeGeneration")
            try collections.documents.save(document: doc)
            try deleteChunks(ids: stale)
        }
    }

    // MARK: Originals and deletion

    public func attachOriginal(fileURL: URL, contentType: String, to docId: String) throws {
        guard let doc = try collections.documents.document(id: docId)?.toMutable() else {
            throw CouchbaseStoreError.documentNotFound(docId)
        }
        doc.setBlob(try Blob(contentType: contentType, fileURL: fileURL), forKey: "file")
        doc.setString(fileURL.lastPathComponent, forKey: "fileName")
        try collections.documents.save(document: doc)
        try? FileManager.default.removeItem(at: cacheDirectory(for: docId))
    }

    public func originalFileURL(docId: String) throws -> URL? {
        guard let doc = try collections.documents.document(id: docId), let blob = doc.blob(forKey: "file"),
            let stream = blob.contentStream
        else { return nil }
        let target = cacheDirectory(for: docId).appendingPathComponent(doc.string(forKey: "fileName") ?? "original")
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: target.path)[.size]) as? UInt64, size == blob.length {
            return target
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: target.path, contents: nil), let out = OutputStream(url: target, append: false)
        else { throw CouchbaseStoreError.malformedDocument(docId) }
        stream.open()
        out.open()
        defer { stream.close(); out.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw stream.streamError ?? CouchbaseStoreError.malformedDocument(docId) }
            if read == 0 { break }
            var written = 0
            while written < read {
                let n = buffer.withUnsafeBufferPointer { out.write($0.baseAddress! + written, maxLength: read - written) }
                if n <= 0 { throw out.streamError ?? CouchbaseStoreError.malformedDocument(docId) }
                written += n
            }
        }
        return target
    }

    private func cacheDirectory(for docId: String) -> URL {
        originalsCache.appendingPathComponent(docId, isDirectory: true)
    }

    public func deleteDocument(id: String) throws {
        let chunkIDs = try chunkIDs(docId: id, excludingGeneration: nil)
        // Deleting the document record also removes its blob; the chunks go with it.
        defer { try? FileManager.default.removeItem(at: cacheDirectory(for: id)) }
        try database.inBatch {
            try deleteChunks(ids: chunkIDs)
            if let doc = try collections.documents.document(id: id) {
                try collections.documents.delete(document: doc)
            }
        }
    }

    // MARK: Chats, messages, jobs

    public func upsert(chat: ChatRecord) throws { try save(chat, id: chat.id, in: collections.chats) }
    public func chat(id: String) throws -> ChatRecord? { try load(ChatRecord.self, id: id, from: collections.chats) }

    public func chats() throws -> [ChatRecord] {
        let query = try database.createQuery("SELECT meta().id AS id FROM \(CouchbaseSchema.scope).chats")
        return try query.execute().allResults()
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try load(ChatRecord.self, id: $0, from: collections.chats) }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    public func deleteChat(id: String) throws {
        let query = try database.createQuery(
            "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).messages WHERE chatId = $chatId")
        query.parameters = Parameters().setString(id, forName: "chatId")
        let messageIDs = try query.execute().allResults().compactMap { $0.string(forKey: "id") }
        try database.inBatch {
            for messageID in messageIDs {
                if let doc = try collections.messages.document(id: messageID) { try collections.messages.delete(document: doc) }
            }
            if let doc = try collections.chats.document(id: id) { try collections.chats.delete(document: doc) }
        }
    }

    public func messages(chatId: String) throws -> [MessageRecord] {
        let query = try database.createQuery(
            "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).messages WHERE chatId = $chatId")
        query.parameters = Parameters().setString(chatId, forName: "chatId")
        return try query.execute().allResults()
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try load(MessageRecord.self, id: $0, from: collections.messages) }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func upsert(message: MessageRecord) throws { try save(message, id: message.id, in: collections.messages) }
    public func message(id: String) throws -> MessageRecord? {
        try load(MessageRecord.self, id: id, from: collections.messages)
    }

    public func upsert(job: IngestJobRecord) throws { try save(job, id: job.docId, in: collections.ingestJobs) }
    public func job(docId: String) throws -> IngestJobRecord? {
        try load(IngestJobRecord.self, id: docId, from: collections.ingestJobs)
    }

    public func jobs() throws -> [IngestJobRecord] {
        let query = try database.createQuery("SELECT meta().id AS id FROM \(CouchbaseSchema.scope).ingestJobs")
        return try query.execute().allResults()
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try load(IngestJobRecord.self, id: $0, from: collections.ingestJobs) }
            .sorted { ($0.enqueuedAt, $0.docId) < ($1.enqueuedAt, $1.docId) }
    }

    public func deleteJob(docId: String) throws {
        if let doc = try collections.ingestJobs.document(id: docId) { try collections.ingestJobs.delete(document: doc) }
    }

    /// `docId → active generation` for every document that has completed ingestion.
    func activeGenerations() throws -> [String: Int] {
        let query = try database.createQuery(
            "SELECT meta().id AS id, activeGeneration AS generation FROM \(CouchbaseSchema.scope).documents WHERE activeGeneration IS NOT MISSING")
        var result: [String: Int] = [:]
        for row in try query.execute().allResults() {
            if let id = row.string(forKey: "id") { result[id] = row.int(forKey: "generation") }
        }
        return result
    }

    // MARK: Diagnostics

    /// Query plan for `sql`; `vector` is bound to `$vector`, `text` to `$text`. Used to check index usage.
    func explain(_ sql: String, vector: [Float]? = nil, text: String? = nil) throws -> String {
        let query = try database.createQuery(sql)
        let params = Parameters()
        if let vector { params.setValue(vector, forName: "vector") }
        if let text { params.setString(text, forName: "text") }
        query.parameters = params
        return try query.explain()
    }

    func count(_ sql: String, docId: String) throws -> Int {
        let query = try database.createQuery(sql)
        query.parameters = Parameters().setString(docId, forName: "docId")
        return try query.execute().allResults().count
    }

    // MARK: Helpers

    private func chunkIDs(docId: String, excludingGeneration generation: Int?) throws -> [String] {
        var sql = "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).chunks WHERE docId = $docId"
        if generation != nil { sql += " AND generation != $generation" }
        let query = try database.createQuery(sql)
        let params = Parameters().setString(docId, forName: "docId")
        if let generation { params.setInt(generation, forName: "generation") }
        query.parameters = params
        return try query.execute().allResults().compactMap { $0.string(forKey: "id") }
    }

    private func deleteChunks(ids: [String]) throws {
        for id in ids {
            if let doc = try collections.chunks.document(id: id) { try collections.chunks.delete(document: doc) }
        }
    }

    private func save<T: Encodable>(_ value: T, id: String, in collection: Collection) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
        guard let dictionary = object as? [String: Any] else { throw CouchbaseStoreError.malformedDocument(id) }
        try collection.save(document: MutableDocument(id: id, data: dictionary))
    }

    private func load<T: Decodable>(_ type: T.Type, id: String, from collection: Collection) throws -> T? {
        guard let doc = try collection.document(id: id) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: doc.toDictionary()))
    }

    private static func set(_ value: Int?, forKey key: String, in doc: MutableDocument) {
        if let value { doc.setInt(value, forKey: key) } else { doc.removeValue(forKey: key) }
    }

    private static func record(from doc: Document) throws -> DocumentRecord {
        guard let title = doc.string(forKey: "title"),
            let type = doc.string(forKey: "type").flatMap(DocumentType.init(rawValue:))
        else { throw CouchbaseStoreError.malformedDocument(doc.id) }
        return DocumentRecord(
            id: doc.id, title: title, type: type,
            pageCount: doc.contains(key: "pageCount") ? doc.int(forKey: "pageCount") : nil,
            activeGeneration: doc.contains(key: "activeGeneration") ? doc.int(forKey: "activeGeneration") : nil,
            importedAt: Date(timeIntervalSince1970: doc.double(forKey: "importedAt")))
    }

    static func chunk(from doc: Document) throws -> Chunk {
        guard let docId = doc.string(forKey: "docId"), let text = doc.string(forKey: "text"),
            let model = doc.string(forKey: "embeddingModel"),
            let raw = doc.array(forKey: "embedding")?.toArray()
        else { throw CouchbaseStoreError.malformedDocument(doc.id) }
        return Chunk(
            docId: docId, generation: doc.int(forKey: "generation"), ordinal: doc.int(forKey: "ordinal"),
            page: doc.contains(key: "page") ? doc.int(forKey: "page") : nil,
            heading: doc.string(forKey: "heading"), text: text,
            embedding: raw.compactMap { ($0 as? NSNumber)?.floatValue }, embeddingModel: model)
    }
}
