import Foundation

public protocol ChatRepository: Sendable {
    func upsert(chat: ChatRecord) async throws
    func chat(id: String) async throws -> ChatRecord?
    /// Most recently updated first.
    func chats() async throws -> [ChatRecord]
    /// Removes the chat and all of its messages.
    func deleteChat(id: String) async throws

    /// Saves the message. Any photo already stored with it is kept.
    func upsert(message: MessageRecord) async throws
    /// Saves the message together with the photo the user attached (a display copy, JPEG).
    func upsert(message: MessageRecord, attachment: Data) async throws
    /// The photo stored with a message, or `nil` if it has none.
    func attachment(messageId: String) async throws -> Data?
    func message(id: String) async throws -> MessageRecord?
    /// Oldest first.
    func messages(chatId: String) async throws -> [MessageRecord]
}

extension ChatRepository {
    @discardableResult
    public func createChat(title: String = "New chat", pinnedDocIds: [String] = [], now: Date = Date()) async throws -> ChatRecord {
        let chat = ChatRecord(id: UUID().uuidString, title: title, pinnedDocIds: pinnedDocIds, createdAt: now, updatedAt: now)
        try await upsert(chat: chat)
        return chat
    }

    public func rename(chatId: String, to title: String, now: Date = Date()) async throws {
        guard var chat = try await chat(id: chatId) else { return }
        chat.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? chat.title : title
        chat.updatedAt = now
        try await upsert(chat: chat)
    }

    /// Replaces the chat's document scope. An empty list means the whole library.
    public func setPinnedDocuments(chatId: String, _ docIds: [String], now: Date = Date()) async throws {
        guard var chat = try await chat(id: chatId) else { return }
        chat.pinnedDocIds = docIds
        chat.updatedAt = now
        try await upsert(chat: chat)
    }
}
