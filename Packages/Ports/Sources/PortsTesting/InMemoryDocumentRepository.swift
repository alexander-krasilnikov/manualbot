import Foundation
import Ports

public actor InMemoryDocumentRepository: DocumentRepository, IngestJobStore, ChatRepository {
    private var docs: [String: DocumentRecord] = [:]
    private var chunkStore: [String: Chunk] = [:]
    private var originals: [String: URL] = [:]
    private var jobStore: [String: IngestJobRecord] = [:]
    private var chatStore: [String: ChatRecord] = [:]
    private var messageStore: [String: MessageRecord] = [:]

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

    public func activate(generation: Int, for docId: String) throws {
        guard var doc = docs[docId] else { throw RepositoryError.documentNotFound(docId) }
        doc.activeGeneration = generation
        docs[docId] = doc
        chunkStore = chunkStore.filter { !($0.value.docId == docId && $0.value.generation != generation) }
    }

    public func attachOriginal(fileURL: URL, contentType: String, to docId: String) throws {
        guard docs[docId] != nil else { throw RepositoryError.documentNotFound(docId) }
        originals[docId] = fileURL
    }

    public func originalFileURL(docId: String) -> URL? { originals[docId] }

    public func deleteDocument(id: String) {
        docs[id] = nil
        originals[id] = nil
        chunkStore = chunkStore.filter { $0.value.docId != id }
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
        messageStore = messageStore.filter { $0.value.chatId != id }
    }
    public func upsert(message: MessageRecord) { messageStore[message.id] = message }
    public func message(id: String) -> MessageRecord? { messageStore[id] }
    public func messages(chatId: String) -> [MessageRecord] {
        messageStore.values.filter { $0.chatId == chatId }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
}

public enum RepositoryError: Error, Equatable {
    case documentNotFound(String)
}
