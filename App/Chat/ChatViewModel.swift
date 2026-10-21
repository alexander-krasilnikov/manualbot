import AVFoundation
import Core
import Foundation
import Observation
import Ports
import UIKit

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
    /// The photo waiting to be sent with the next question (picked or taken; JPEG or HEIC data).
    private(set) var attachedPhoto: Data?
    /// UI tests have no photo picker to drive: when set, the attach button attaches this instead of opening it.
    var stubPhoto: Data?
    /// Whether the embedding model in use can analyze photos; the photo controls give way to an explanation when it cannot.
    var photosAvailable = true
    /// Why photos cannot be analyzed, naming the embedding model in use. Shown in place of the photo controls.
    var photosExplanation: String?

    private let chatRepository: any ChatRepository
    private let documentRepository: any DocumentRepository
    private let ingestion: IngestionService
    private var service: ChatService?
    /// The answer style each question is asked with; Balanced when there is none.
    var answers: AnswerSettings?
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

    /// A question needs words or a photo.
    var canSend: Bool {
        availability == .ready && !isGenerating && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachedPhoto != nil)
    }

    var cameraAvailable: Bool { stubPhoto == nil && UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// Whether the app may use the camera, so the user can be told how to allow it instead of seeing a blank view.
    var cameraDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    func attach(photo data: Data) {
        guard PhotoData.image(from: data, maxPixelSize: 64) != nil else {
            errorMessage = "That file is not a photo the app can read."
            return
        }
        errorMessage = nil
        attachedPhoto = data
    }

    func removePhoto() { attachedPhoto = nil }

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
        let photo = attachedPhoto.flatMap { PhotoData.image(from: $0) }
        draft = ""
        attachedPhoto = nil
        errorMessage = nil
        isGenerating = true
        streaming = ""
        await ingestion.setPaused(true)  // the answer has priority over background indexing

        let task = Task {
            do {
                for try await event in service.ask(question, in: chatID, photo: photo, style: answers?.style ?? .balanced) {
                    switch event {
                    case .query: await self.reloadMessages()
                    case .delta(let piece): self.streaming = (self.streaming ?? "") + piece
                    case .restart: self.streaming = ""
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

    /// Stops the answer and waits until it has been saved, so nothing is written afterwards (a demo reset deletes the chat next).
    func stopAndWait() async {
        guard isGenerating else { return }
        stop()
        for _ in 0..<200 where isGenerating { try? await Task.sleep(for: .milliseconds(25)) }
    }

    /// The service saves the partial answer just after the stream ends; wait briefly for it.
    private func settleAfterStop() async {
        for _ in 0..<40 {
            await reloadMessages()
            if messages.last?.role == .assistant { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: Photos in the transcript

    @ObservationIgnored private var attachments: [String: Data] = [:]

    /// What the transcript needs to draw photos: the user's own, those on cited pages, and those a reply matched.
    var photos: PhotoLoader {
        PhotoLoader(
            attachment: { [weak self] message in await self?.attachment(of: message) },
            cited: { [weak self] citation in await self?.photos(for: citation) ?? [] },
            matched: { [weak self] match in await self?.thumbnail(for: match) ?? MatchThumbnail(data: nil, documentDeleted: false) })
    }

    private func attachment(of message: MessageRecord) async -> Data? {
        guard message.hasAttachment else { return nil }
        if let cached = attachments[message.id] { return cached }
        guard let data = try? await chatRepository.attachment(messageId: message.id) else { return nil }
        attachments[message.id] = data
        return data
    }

    /// The photo behind a cited image chunk, or every photo stored on the cited page or section.
    private func photos(for citation: Citation) async -> [PhotoRef] {
        var records: [ImageRecord] = []
        if let imageId = citation.imageId, let data = try? await documentRepository.imageData(id: imageId) {
            return [PhotoRef(id: imageId, data: data)]
        } else if let page = citation.page {
            records = (try? await documentRepository.activeImages(docId: citation.docId, page: page)) ?? []
        } else if let heading = citation.heading, !heading.isEmpty {
            records = (try? await documentRepository.activeImages(docId: citation.docId, heading: heading)) ?? []
        }
        var found: [PhotoRef] = []
        for record in records.prefix(4) {
            if let data = try? await documentRepository.imageData(id: record.id) { found.append(PhotoRef(id: record.id, data: data)) }
        }
        return found
    }

    private func thumbnail(for match: ImageMatch) async -> MatchThumbnail {
        let exists = (try? await documentRepository.document(id: match.docId)) != nil
        guard exists else { return MatchThumbnail(data: nil, documentDeleted: true) }
        return MatchThumbnail(data: try? await documentRepository.imageData(id: match.imageId), documentDeleted: false)
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

/// A photo stored in the library, as shown beside an answer.
struct PhotoRef: Identifiable, Equatable {
    let id: String
    let data: Data
}

struct MatchThumbnail: Equatable {
    var data: Data?
    /// The matched photo's document has been deleted since the reply was written.
    var documentDeleted: Bool
}

/// Loads the photos a message shows. Closures, so views stay free of repositories.
struct PhotoLoader {
    var attachment: (MessageRecord) async -> Data?
    var cited: (Citation) async -> [PhotoRef]
    var matched: (ImageMatch) async -> MatchThumbnail
}
