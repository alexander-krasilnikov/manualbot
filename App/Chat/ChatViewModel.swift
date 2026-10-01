import Core
import Foundation
import Observation
import Ports

@MainActor @Observable
final class ChatViewModel {
    enum Availability: Equatable {
        case ready
        /// The language model is not installed or loaded yet.
        case modelNotReady
        /// There is nothing to ask about yet.
        case noDocuments
    }

    private(set) var chats: [ChatRecord] = []
    private(set) var currentID: String?
    private(set) var messages: [MessageRecord] = []
    /// The answer so far while one is being written; `nil` otherwise.
    private(set) var streaming: String?
    private(set) var isGenerating = false
    private(set) var errorMessage: String?
    private(set) var documents: [LibraryViewModel.Item] = []
    var draft = ""

    private let chatRepository: any ChatRepository
    private let documentRepository: any DocumentRepository
    private let ingestion: IngestionService
    private var service: ChatService?
    private var generation: Task<Void, Never>?

    init(chats: any ChatRepository, documents: any DocumentRepository, ingestion: IngestionService) {
        self.chatRepository = chats
        self.documentRepository = documents
        self.ingestion = ingestion
    }

    func attach(_ service: ChatService) { self.service = service }

    // MARK: State

    var current: ChatRecord? { chats.first { $0.id == currentID } }
    var pinnedIDs: [String] { current?.pinnedDocIds ?? [] }
    var pinnedDocuments: [LibraryViewModel.Item] { pinnedIDs.compactMap { id in documents.first { $0.id == id } } }

    var availability: Availability {
        if service == nil { return .modelNotReady }
        return documents.isEmpty ? .noDocuments : .ready
    }

    var canSend: Bool { availability == .ready && !isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Called when the library changes; only documents that are ready can be searched or pinned.
    func updateDocuments(_ items: [LibraryViewModel.Item]) {
        documents = items.filter { $0.status.isReady }
    }

    // MARK: Chats

    func load() async {
        await reloadChats()
        if currentID == nil || current == nil { currentID = chats.first?.id }
        await reloadMessages()
    }

    func newChat() async {
        guard let chat = try? await chatRepository.createChat(title: ChatService.untitled) else { return }
        await reloadChats()
        currentID = chat.id
        await reloadMessages()
    }

    func select(_ id: String) async {
        guard !isGenerating else { return }
        currentID = id
        await reloadMessages()
    }

    func rename(_ id: String, to title: String) async {
        try? await chatRepository.rename(chatId: id, to: title)
        await reloadChats()
    }

    func delete(_ id: String) async {
        guard !isGenerating || id != currentID else { return }
        try? await chatRepository.deleteChat(id: id)
        await reloadChats()
        if currentID == id { currentID = chats.first?.id }
        await reloadMessages()
    }

    func togglePin(_ docID: String) async {
        guard let id = await ensureChat() else { return }
        var pinned = pinnedIDs
        if let index = pinned.firstIndex(of: docID) { pinned.remove(at: index) } else { pinned.append(docID) }
        try? await chatRepository.setPinnedDocuments(chatId: id, pinned)
        await reloadChats()
    }

    func clearPins() async {
        guard let id = currentID else { return }
        try? await chatRepository.setPinnedDocuments(chatId: id, [])
        await reloadChats()
    }

    // MARK: Asking

    func send() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let service, let chatID = await ensureChat() else { return }
        draft = ""
        errorMessage = nil
        isGenerating = true
        streaming = ""
        await ingestion.setPaused(true)  // the answer has priority over background indexing

        let task = Task {
            do {
                for try await event in service.ask(question, in: chatID) {
                    switch event {
                    case .query: await self.reloadMessages()
                    case .delta(let piece): self.streaming = (self.streaming ?? "") + piece
                    case .completed: await self.reloadMessages()
                    }
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
        generation = task
        await task.value
        generation = nil

        if task.isCancelled { await settleAfterStop() }
        streaming = nil
        isGenerating = false
        await ingestion.setPaused(false)
        await reloadChats()
        await reloadMessages()
    }

    /// Stops the answer being written. What was written so far is kept and marked as stopped.
    func stop() { generation?.cancel() }

    /// The service saves the partial answer just after the stream ends; wait briefly for it.
    private func settleAfterStop() async {
        for _ in 0..<40 {
            await reloadMessages()
            if messages.last?.role == .assistant { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Helpers

    private func ensureChat() async -> String? {
        if let currentID, current != nil { return currentID }
        await newChat()
        return currentID
    }

    private func reloadChats() async { chats = (try? await chatRepository.chats()) ?? chats }

    private func reloadMessages() async {
        guard let currentID else { messages = []; return }
        messages = (try? await chatRepository.messages(chatId: currentID)) ?? messages
    }
}
