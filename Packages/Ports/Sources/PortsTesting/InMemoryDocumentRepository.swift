import Foundation
import Ports

public actor InMemoryDocumentRepository: DocumentRepository, IngestJobStore, ChatRepository {
    private var docs: [String: DocumentRecord] = [:]
    private var chunkStore: [String: Chunk] = [:]
    private var originals: [String: URL] = [:]
    private var jobStore: [String: IngestJobRecord] = [:]
    private var chatStore: [String: ChatRecord] = [:]
    private var messageStore: [String: MessageRecord] = [:]
    private var imageStore: [String: ImageWrite] = [:]
    private var attachments: [String: Data] = [:]

    public init() {}

    public func upsert(_ document: DocumentRecord) { docs[document.id] = document }
    public func document(id: String) -> DocumentRecord? { docs[id] }
    public func documents() -> [DocumentRecord] { docs.values.sorted { $0.importedAt < $1.importedAt } }

    public func writeChunks(_ chunks: [Chunk]) {
        for chunk in chunks { chunkStore[chunk.id] = chunk }
    }

    public func chunks(docId: String, generation: Int) -> [Chunk] {
        chunkStore.values
            .filter { $0.docId == docId && $0.generation == generation }
            .sorted { $0.ordinal < $1.ordinal }
    }

    public func activeChunks(docId: String) -> [Chunk] {
        guard let active = docs[docId]?.activeGeneration else { return [] }
        return chunks(docId: docId, generation: active)
    }

    public func activeChunks(docId: String, page: Int) -> [Chunk] { activeChunks(docId: docId).filter { $0.page == page } }
    public func activeChunks(docId: String, heading: String) -> [Chunk] { activeChunks(docId: docId).filter { $0.heading == heading } }

    public func writeImages(_ writes: [ImageWrite]) {
        for write in writes { imageStore[write.record.id] = write }
    }

    public func images(docId: String, generation: Int) -> [ImageRecord] {
        imageStore.values.map(\.record)
            .filter { $0.docId == docId && $0.generation == generation }
            .sorted { $0.n < $1.n }
    }

    public func activeImages(docId: String) -> [ImageRecord] {
        guard let active = docs[docId]?.activeGeneration else { return [] }
        return images(docId: docId, generation: active)
    }

    public func activeImages(docId: String, page: Int) -> [ImageRecord] { activeImages(docId: docId).filter { $0.page == page } }
    public func activeImages(docId: String, heading: String) -> [ImageRecord] { activeImages(docId: docId).filter { $0.heading == heading } }
    public func imageData(id: String) -> Data? { imageStore[id]?.displayCopy }

    public func activate(generation: Int, for docId: String) throws {
        guard var doc = docs[docId] else { throw RepositoryError.documentNotFound(docId) }
        doc.activeGeneration = generation
        docs[docId] = doc
        chunkStore = chunkStore.filter { !($0.value.docId == docId && $0.value.generation != generation) }
        imageStore = imageStore.filter { !($0.value.record.docId == docId && $0.value.record.generation != generation) }
    }

    public func attachOriginal(fileURL: URL, contentType: String, to docId: String) throws {
        guard docs[docId] != nil else { throw RepositoryError.documentNotFound(docId) }
        originals[docId] = fileURL
    }

    public func originalFileURL(docId: String) -> URL? { originals[docId] }

    public func documentIDs(notEmbeddedBy textModel: String, imageModel: String) -> [String] {
        documents().filter { document in
            guard document.activeGeneration != nil else { return false }
            return activeChunks(docId: document.id).contains { $0.embeddingModel != textModel }
                || activeImages(docId: document.id).contains { $0.featureModel != imageModel }
        }.map(\.id)
    }

    public func deleteDocument(id: String) {
        docs[id] = nil
        originals[id] = nil
        chunkStore = chunkStore.filter { $0.value.docId != id }
        imageStore = imageStore.filter { $0.value.record.docId != id }
    }
}

extension InMemoryDocumentRepository {
    public func upsert(job: IngestJobRecord) { jobStore[job.docId] = job }
    public func job(docId: String) -> IngestJobRecord? { jobStore[docId] }
    public func jobs() -> [IngestJobRecord] { jobStore.values.sorted { ($0.enqueuedAt, $0.docId) < ($1.enqueuedAt, $1.docId) } }
    public func deleteJob(docId: String) { jobStore[docId] = nil }
}

extension InMemoryDocumentRepository {
    public func upsert(chat: ChatRecord) { chatStore[chat.id] = chat }
    public func chat(id: String) -> ChatRecord? { chatStore[id] }
    public func chats() -> [ChatRecord] { chatStore.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) } }
    public func deleteChat(id: String) {
        chatStore[id] = nil
        let removed = messageStore.filter { $0.value.chatId == id }.keys
        messageStore = messageStore.filter { $0.value.chatId != id }
        for key in removed { attachments[key] = nil }
    }
    public func upsert(message: MessageRecord) { messageStore[message.id] = message }
    public func upsert(message: MessageRecord, attachment: Data) {
        messageStore[message.id] = message
        attachments[message.id] = attachment
    }
    public func attachment(messageId: String) -> Data? { attachments[messageId] }
    public func message(id: String) -> MessageRecord? { messageStore[id] }
    public func messages(chatId: String) -> [MessageRecord] {
        messageStore.values.filter { $0.chatId == chatId }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}

public enum RepositoryError: Error, Equatable {
    case documentNotFound(String)
}
