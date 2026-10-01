import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// The same behavior is required of every `ChatRepository`, so both implementations run these.
private func exerciseChatRepository(_ repo: any ChatRepository) async throws {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // Create with pinned documents
    let a = try await repo.createChat(title: "Reset help", pinnedDocIds: ["d1", "d2"], now: t0)
    let b = try await repo.createChat(title: "Filters", now: t0.addingTimeInterval(60))
    #expect(try await repo.chat(id: a.id)?.pinnedDocIds == ["d1", "d2"])
    #expect(try await repo.chats().map(\.id) == [b.id, a.id], "most recently updated first")

    // Rename, and blank names are ignored
    try await repo.rename(chatId: a.id, to: "Reset the X200", now: t0.addingTimeInterval(120))
    #expect(try await repo.chat(id: a.id)?.title == "Reset the X200")
    try await repo.rename(chatId: a.id, to: "   ", now: t0.addingTimeInterval(130))
    #expect(try await repo.chat(id: a.id)?.title == "Reset the X200")
    #expect(try await repo.chats().map(\.id) == [a.id, b.id], "renaming bumps updatedAt")

    // Pinning and clearing the scope
    try await repo.setPinnedDocuments(chatId: a.id, ["d3"])
    #expect(try await repo.chat(id: a.id)?.pinnedDocIds == ["d3"])
    try await repo.setPinnedDocuments(chatId: a.id, [])
    #expect(try await repo.chat(id: a.id)?.pinnedDocIds == [])

    // Messages come back oldest first, with citations intact
    let citation = Citation(n: 1, chunkId: "d1:1:4", docId: "d1", docTitle: "Manual A", page: 42, heading: "Reset", snippet: "Hold the button")
    let user = MessageRecord(id: "m1", chatId: a.id, role: .user, text: "How do I reset it?", createdAt: t0.addingTimeInterval(200))
    let answer = MessageRecord(id: "m2", chatId: a.id, role: .assistant, text: "Hold the button [1]", standaloneQuery: "reset X200",
                               citations: [citation], stopped: true, createdAt: t0.addingTimeInterval(201))
    try await repo.upsert(message: answer)
    try await repo.upsert(message: user)
    try await repo.upsert(message: MessageRecord(id: "other", chatId: b.id, role: .user, text: "elsewhere", createdAt: t0))
    #expect(try await repo.messages(chatId: a.id) == [user, answer])
    #expect(try await repo.message(id: "m2") == answer)

    // Deleting a chat removes its messages and only its messages
    try await repo.deleteChat(id: a.id)
    #expect(try await repo.chat(id: a.id) == nil)
    #expect(try await repo.messages(chatId: a.id).isEmpty)
    #expect(try await repo.message(id: "m1") == nil)
    #expect(try await repo.messages(chatId: b.id).map(\.id) == ["other"])
    #expect(try await repo.chats().map(\.id) == [b.id])

    // Missing chats are ignored, not errors
    try await repo.rename(chatId: "nope", to: "x")
    try await repo.setPinnedDocuments(chatId: "nope", ["d1"])
    try await repo.deleteChat(id: "nope")
}

@Suite struct ChatRepositoryTests {
    @Test func inMemoryImplementationMeetsTheContract() async throws {
        try await exerciseChatRepository(InMemoryDocumentRepository())
    }

    @Test func couchbaseImplementationMeetsTheContract() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await exerciseChatRepository(f.repo)
    }

    @Test func chatsAndMessagesSurviveReopeningTheDatabase() async throws {
        let f = try RepoFixture()
        let chat = try await f.repo.createChat(title: "Persisted", pinnedDocIds: ["d1"])
        let citation = Citation(n: 1, chunkId: "d1:1:0", docId: "d1", docTitle: "Manual", page: 3, snippet: "kept")
        let message = MessageRecord(id: "m1", chatId: chat.id, role: .assistant, text: "Answer [1]", citations: [citation],
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_500))
        try await f.repo.upsert(message: message)
        try await f.repo.close()

        let reopened = try RepoFixture(root: f.root)
        defer { Task { await reopened.cleanUp() } }
        #expect(try await reopened.repo.chats().map(\.title) == ["Persisted"])
        #expect(try await reopened.repo.chat(id: chat.id)?.pinnedDocIds == ["d1"])
        #expect(try await reopened.repo.messages(chatId: chat.id) == [message])
    }
}
