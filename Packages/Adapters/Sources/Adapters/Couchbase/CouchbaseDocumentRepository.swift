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
    let embedding: EmbeddingModelIdentity
    let imageFeatures: EmbeddingModelIdentity
    private let originalsCache: URL
    let tracer: any Tracer

    /// Opens (or creates) the database in `directory` and prepares the schema.
    /// `originalsCache` is where stored originals are materialized as plain files on demand.
    public init(
        directory: URL, originalsCache: URL, name: String = "manualbot", embedding: EmbeddingModelIdentity,
        imageFeatures: EmbeddingModelIdentity = CouchbaseSchema.defaultImageFeatures, tracer: any Tracer = NoTracer()
    ) throws {
        self.originalsCache = originalsCache
        self.tracer = tracer
        try CouchbaseBootstrap.enableVectorSearch()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = DatabaseConfiguration()
        config.directory = directory.path
        database = try Database(name: name, config: config)
        collections = try CouchbaseSchema.prepare(database, embedding: embedding, imageFeatures: imageFeatures)
        self.embedding = embedding
        self.imageFeatures = imageFeatures
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
        Self.set(document.imageCount, forKey: "imageCount", in: doc)
        doc.setDouble(document.importedAt.timeIntervalSince1970, forKey: "importedAt")
        try collections.documents.save(document: doc)
        tracer.emit(.documentSaved(collection: CouchbaseSchema.documents, id: document.id))
    }

    public func document(id: String) throws -> DocumentRecord? {
        try collections.documents.document(id: id).map(Self.record(from:))
    }

    public func documents() throws -> [DocumentRecord] {
        try run("SELECT meta().id AS id FROM \(CouchbaseSchema.scope).documents")
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try collections.documents.document(id: $0) }
            .map(Self.record(from:))
            .sorted { $0.importedAt < $1.importedAt }
    }

    // MARK: Chunks

    public func writeChunks(_ chunks: [Chunk]) throws {
        let (_, seconds) = try timed { try writeBatch(chunks) }
        if let first = chunks.first {
            tracer.emit(duration: seconds, .batchWritten(
                collection: CouchbaseSchema.chunks, count: chunks.count, dimensions: first.embedding.count))
        }
    }

    private func writeBatch(_ chunks: [Chunk]) throws {
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
                if let imageId = chunk.imageId { doc.setString(imageId, forKey: "imageId") }
                try collections.chunks.save(document: doc)
            }
        }
    }

    public func chunks(docId: String, generation: Int) throws -> [Chunk] {
        try run(
            "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).chunks WHERE docId = $docId AND generation = $generation",
            parameters: Parameters().setString(docId, forName: "docId").setInt(generation, forName: "generation"),
            shown: ["docId": docId, "generation": String(generation)])
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try collections.chunks.document(id: $0) }
            .map(Self.chunk(from:))
            .sorted { $0.ordinal < $1.ordinal }
    }

    public func activeChunks(docId: String) throws -> [Chunk] {
        guard let generation = try document(id: docId)?.activeGeneration else { return [] }
        return try chunks(docId: docId, generation: generation)
    }

    public func activeChunks(docId: String, page: Int) throws -> [Chunk] {
        try activeChunks(docId: docId, matching: "page = $page", Parameters().setInt(page, forName: "page"), shown: ["page": String(page)])
    }

    public func activeChunks(docId: String, heading: String) throws -> [Chunk] {
        try activeChunks(
            docId: docId, matching: "heading = $heading", Parameters().setString(heading, forName: "heading"),
            shown: ["heading": heading])
    }

    private func activeChunks(docId: String, matching predicate: String, _ extra: Parameters, shown: [String: String]) throws -> [Chunk] {
        guard let generation = try document(id: docId)?.activeGeneration else { return [] }
        let parameters = extra.setString(docId, forName: "docId").setInt(generation, forName: "generation")
        return try run(
            "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).chunks WHERE docId = $docId AND generation = $generation AND \(predicate)",
            parameters: parameters, shown: shown.merging(["docId": docId, "generation": String(generation)]) { a, _ in a })
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try collections.chunks.document(id: $0) }
            .map(Self.chunk(from:))
            .sorted { $0.ordinal < $1.ordinal }
    }

    public func activate(generation: Int, for docId: String) throws {
        guard let doc = try collections.documents.document(id: docId)?.toMutable() else {
            throw CouchbaseStoreError.documentNotFound(docId)
        }
        let stale = try chunkIDs(docId: docId, excludingGeneration: generation)
        let staleImages = try imageIDs(docId: docId, excludingGeneration: generation)
        // One transaction: readers see either the old generation or the new one, never a mix.
        let (_, seconds) = try timed {
            try database.inBatch {
                doc.setInt(generation, forKey: "activeGeneration")
                try collections.documents.save(document: doc)
                try deleteChunks(ids: stale)
                try deleteImages(ids: staleImages)
            }
        }
        tracer.emit(duration: seconds, .generationActivated(
            docId: docId, generation: generation, removed: stale.count, removedImages: staleImages.count))
    }

    // MARK: Images

    public func writeImages(_ writes: [ImageWrite]) throws {
        let (_, seconds) = try timed { try writeImageBatch(writes) }
        if let first = writes.first {
            tracer.emit(duration: seconds, .imagesWritten(
                collection: CouchbaseSchema.images, count: writes.count, blobBytes: writes.reduce(0) { $0 + $1.displayCopy.count },
                dimensions: first.record.features.count))
        }
    }

    private func writeImageBatch(_ writes: [ImageWrite]) throws {
        try database.inBatch {
            for write in writes {
                let image = write.record
                let doc = MutableDocument(id: image.id)
                doc.setString(image.docId, forKey: "docId")
                doc.setInt(image.generation, forKey: "generation")
                doc.setInt(image.n, forKey: "n")
                Self.set(image.page, forKey: "page", in: doc)
                if let heading = image.heading { doc.setString(heading, forKey: "heading") }
                if let caption = image.caption { doc.setString(caption, forKey: "caption") }
                doc.setString(image.captionSource.rawValue, forKey: "captionSource")
                doc.setString(image.ocrText, forKey: "ocrText")
                doc.setInt(image.width, forKey: "width")
                doc.setInt(image.height, forKey: "height")
                doc.setValue(image.features, forKey: "features")
                doc.setString(image.featureModel, forKey: "featureModel")
                doc.setInt(image.features.count, forKey: "dims")
                doc.setBlob(Blob(contentType: "image/jpeg", data: write.displayCopy), forKey: "image")
                try collections.images.save(document: doc)
            }
        }
    }

    public func images(docId: String, generation: Int) throws -> [ImageRecord] {
        try imageRecords(docId: docId, generation: generation, matching: nil, Parameters(), shown: [:])
    }

    public func activeImages(docId: String) throws -> [ImageRecord] {
        guard let generation = try document(id: docId)?.activeGeneration else { return [] }
        return try images(docId: docId, generation: generation)
    }

    public func activeImages(docId: String, page: Int) throws -> [ImageRecord] {
        guard let generation = try document(id: docId)?.activeGeneration else { return [] }
        return try imageRecords(
            docId: docId, generation: generation, matching: "page = $page", Parameters().setInt(page, forName: "page"),
            shown: ["page": String(page)])
    }

    public func activeImages(docId: String, heading: String) throws -> [ImageRecord] {
        guard let generation = try document(id: docId)?.activeGeneration else { return [] }
        return try imageRecords(
            docId: docId, generation: generation, matching: "heading = $heading",
            Parameters().setString(heading, forName: "heading"), shown: ["heading": heading])
    }

    public func imageData(id: String) throws -> Data? {
        try collections.images.document(id: id)?.blob(forKey: "image")?.content
    }

    private func imageRecords(
        docId: String, generation: Int, matching predicate: String?, _ extra: Parameters, shown: [String: String]
    ) throws -> [ImageRecord] {
        var sql = "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).images WHERE docId = $docId AND generation = $generation"
        if let predicate { sql += " AND \(predicate)" }
        let parameters = extra.setString(docId, forName: "docId").setInt(generation, forName: "generation")
        return try run(sql, parameters: parameters, shown: shown.merging(["docId": docId, "generation": String(generation)]) { a, _ in a })
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try collections.images.document(id: $0) }
            .map(Self.image(from:))
            .sorted { $0.n < $1.n }
    }

    func imageIDs(docId: String, excludingGeneration generation: Int?) throws -> [String] {
        var sql = "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).images WHERE docId = $docId"
        if generation != nil { sql += " AND generation != $generation" }
        let params = Parameters().setString(docId, forName: "docId")
        var shown = ["docId": docId]
        if let generation {
            params.setInt(generation, forName: "generation")
            shown["generation"] = String(generation)
        }
        return try run(sql, parameters: params, shown: shown).compactMap { $0.string(forKey: "id") }
    }

    private func deleteImages(ids: [String]) throws {
        for id in ids {
            if let doc = try collections.images.document(id: id) { try collections.images.delete(document: doc) }
        }
    }

    static func image(from doc: Document) throws -> ImageRecord {
        guard let docId = doc.string(forKey: "docId"), let model = doc.string(forKey: "featureModel"),
            let raw = doc.array(forKey: "features")?.toArray()
        else { throw CouchbaseStoreError.malformedDocument(doc.id) }
        return ImageRecord(
            docId: docId, generation: doc.int(forKey: "generation"), n: doc.int(forKey: "n"),
            page: doc.contains(key: "page") ? doc.int(forKey: "page") : nil,
            heading: doc.string(forKey: "heading"), caption: doc.string(forKey: "caption"),
            captionSource: doc.string(forKey: "captionSource").flatMap(CaptionSource.init(rawValue:)) ?? .none,
            ocrText: doc.string(forKey: "ocrText") ?? "", width: doc.int(forKey: "width"), height: doc.int(forKey: "height"),
            features: raw.compactMap { ($0 as? NSNumber)?.floatValue }, featureModel: model)
    }

    // MARK: Originals and deletion

    public func attachOriginal(fileURL: URL, contentType: String, to docId: String) throws {
        guard let doc = try collections.documents.document(id: docId)?.toMutable() else {
            throw CouchbaseStoreError.documentNotFound(docId)
        }
        let blob = try Blob(contentType: contentType, fileURL: fileURL)
        doc.setBlob(blob, forKey: "file")
        doc.setString(fileURL.lastPathComponent, forKey: "fileName")
        let (_, seconds) = try timed { try collections.documents.save(document: doc) }
        tracer.emit(duration: seconds, .blobStored(docId: docId, contentType: contentType, length: Int(blob.length)))
        try? FileManager.default.removeItem(at: cacheDirectory(for: docId))
    }

    public func originalFileURL(docId: String) throws -> URL? {
        guard let doc = try collections.documents.document(id: docId), let blob = doc.blob(forKey: "file"),
            let stream = blob.contentStream
        else { return nil }
        let target = cacheDirectory(for: docId).appendingPathComponent(doc.string(forKey: "fileName") ?? "original")
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: target.path)[.size]) as? UInt64, size == blob.length {
            tracer.emit(.blobRead(docId: docId, length: Int(blob.length), cacheHit: true))
            return target
        }
        let readStart = ContinuousClock.now
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
        if tracer.isEnabled {
            tracer.emit(duration: readStart.duration(to: .now).seconds,
                        .blobRead(docId: docId, length: Int(blob.length), cacheHit: false))
        }
        return target
    }

    private func cacheDirectory(for docId: String) -> URL {
        originalsCache.appendingPathComponent(docId, isDirectory: true)
    }

    public func deleteDocument(id: String) throws {
        let chunkIDs = try chunkIDs(docId: id, excludingGeneration: nil)
        let imageIDs = try imageIDs(docId: id, excludingGeneration: nil)
        // Deleting the document record also removes its blob; the chunks go with it.
        defer { try? FileManager.default.removeItem(at: cacheDirectory(for: id)) }
        let (_, seconds) = try timed {
            try database.inBatch {
                try deleteChunks(ids: chunkIDs)
                try deleteImages(ids: imageIDs)
                if let doc = try collections.documents.document(id: id) {
                    try collections.documents.delete(document: doc)
                }
            }
        }
        tracer.emit(duration: seconds, .documentDeleted(docId: id, passagesRemoved: chunkIDs.count, imagesRemoved: imageIDs.count))
    }

    // MARK: Chats, messages, jobs

    public func upsert(chat: ChatRecord) throws { try save(chat, id: chat.id, in: collections.chats) }
    public func chat(id: String) throws -> ChatRecord? { try load(ChatRecord.self, id: id, from: collections.chats) }

    public func chats() throws -> [ChatRecord] {
        try run("SELECT meta().id AS id FROM \(CouchbaseSchema.scope).chats")
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try load(ChatRecord.self, id: $0, from: collections.chats) }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    public func deleteChat(id: String) throws {
        let messageIDs = try run(
            "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).messages WHERE chatId = $chatId",
            parameters: Parameters().setString(id, forName: "chatId"), shown: ["chatId": id]
        ).compactMap { $0.string(forKey: "id") }
        try database.inBatch {
            for messageID in messageIDs {
                if let doc = try collections.messages.document(id: messageID) { try collections.messages.delete(document: doc) }
            }
            if let doc = try collections.chats.document(id: id) { try collections.chats.delete(document: doc) }
        }
    }

    public func messages(chatId: String) throws -> [MessageRecord] {
        try run(
            "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).messages WHERE chatId = $chatId",
            parameters: Parameters().setString(chatId, forName: "chatId"), shown: ["chatId": chatId]
        )
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try load(MessageRecord.self, id: $0, from: collections.messages) }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func upsert(message: MessageRecord) throws {
        let doc = try document(for: message, id: message.id)
        // Saving the record again must not drop the photo that was stored with it.
        if let photo = try collections.messages.document(id: message.id)?.blob(forKey: "attachment") {
            doc.setBlob(photo, forKey: "attachment")
        }
        try collections.messages.save(document: doc)
        tracer.emit(.messageSaved(id: message.id))
    }

    public func upsert(message: MessageRecord, attachment: Data) throws {
        let doc = try document(for: message, id: message.id)
        doc.setBlob(Blob(contentType: "image/jpeg", data: attachment), forKey: "attachment")
        try collections.messages.save(document: doc)
        tracer.emit(.messageSaved(id: message.id))
    }

    public func attachment(messageId: String) throws -> Data? {
        try collections.messages.document(id: messageId)?.blob(forKey: "attachment")?.content
    }
    public func message(id: String) throws -> MessageRecord? {
        try load(MessageRecord.self, id: id, from: collections.messages)
    }

    public func upsert(job: IngestJobRecord) throws { try save(job, id: job.docId, in: collections.ingestJobs) }
    public func job(docId: String) throws -> IngestJobRecord? {
        try load(IngestJobRecord.self, id: docId, from: collections.ingestJobs)
    }

    public func jobs() throws -> [IngestJobRecord] {
        try run("SELECT meta().id AS id FROM \(CouchbaseSchema.scope).ingestJobs")
            .compactMap { $0.string(forKey: "id") }
            .compactMap { try load(IngestJobRecord.self, id: $0, from: collections.ingestJobs) }
            .sorted { ($0.enqueuedAt, $0.docId) < ($1.enqueuedAt, $1.docId) }
    }

    public func deleteJob(docId: String) throws {
        if let doc = try collections.ingestJobs.document(id: docId) { try collections.ingestJobs.delete(document: doc) }
    }

    /// `docId → active generation` for every document that has completed ingestion.
    func activeGenerations() throws -> [String: Int] {
        var result: [String: Int] = [:]
        let rows = try run(
            "SELECT meta().id AS id, activeGeneration AS generation FROM \(CouchbaseSchema.scope).documents WHERE activeGeneration IS NOT MISSING")
        for row in rows {
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

    /// Runs `sql`, and reports it (text, parameters as shown, rows, execution time) when tracing is on.
    /// Only the execution is timed, not the work done with the rows afterwards.
    func run(_ sql: String, parameters: Parameters? = nil, shown: @autoclosure () -> [String: String] = [:]) throws -> [Result] {
        let query = try database.createQuery(sql)
        if let parameters { query.parameters = parameters }
        let (rows, seconds) = try timed { try query.execute().allResults() }
        tracer.emit(duration: seconds, .query(QueryTrace(sql: sql, parameters: shown(), returnedRows: rows.count)))
        return rows
    }

    /// Runs `body`; measures it only while tracing is on.
    func timed<T>(_ body: () throws -> T) rethrows -> (value: T, seconds: TimeInterval?) {
        guard tracer.isEnabled else { return (try body(), nil) }
        let start = ContinuousClock.now
        let value = try body()
        return (value, start.duration(to: .now).seconds)
    }

    private func chunkIDs(docId: String, excludingGeneration generation: Int?) throws -> [String] {
        var sql = "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).chunks WHERE docId = $docId"
        if generation != nil { sql += " AND generation != $generation" }
        let params = Parameters().setString(docId, forName: "docId")
        var shown = ["docId": docId]
        if let generation {
            params.setInt(generation, forName: "generation")
            shown["generation"] = String(generation)
        }
        return try run(sql, parameters: params, shown: shown).compactMap { $0.string(forKey: "id") }
    }

    private func deleteChunks(ids: [String]) throws {
        for id in ids {
            if let doc = try collections.chunks.document(id: id) { try collections.chunks.delete(document: doc) }
        }
    }

    private func document<T: Encodable>(for value: T, id: String) throws -> MutableDocument {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
        guard let dictionary = object as? [String: Any] else { throw CouchbaseStoreError.malformedDocument(id) }
        return MutableDocument(id: id, data: dictionary)
    }

    private func save<T: Encodable>(_ value: T, id: String, in collection: Collection) throws {
        try collection.save(document: document(for: value, id: id))
    }

    private func load<T: Decodable>(_ type: T.Type, id: String, from collection: Collection) throws -> T? {
        guard let doc = try collection.document(id: id) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Blobs (a message's photo) are read on demand, never decoded with the record.
        let fields = doc.toDictionary().filter { !($0.value is Blob) }
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: fields))
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
            importedAt: Date(timeIntervalSince1970: doc.double(forKey: "importedAt")),
            imageCount: doc.contains(key: "imageCount") ? doc.int(forKey: "imageCount") : nil)
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
            embedding: raw.compactMap { ($0 as? NSNumber)?.floatValue }, embeddingModel: model,
            imageId: doc.string(forKey: "imageId"))
    }
}
