@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// Replication of the shared library, against an in-process server.
@Suite(.serialized) struct LibrarySyncTests {
    // MARK: Replication and status

    @Test func aDocumentWithItsChunksAndImagesReplicatesAndTheStatusReachesUpToDate() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        try await a.importDocument("d1", chunks: 5, images: 2)

        await a.sync.start(server.configuration)
        try await waitForFirstSync(a.sync)

        try await eventually("everything on the server") {
            try server.count("documents") == 1 && server.count("chunks") == 5 && server.count("images") == 2
        }
        let status = await a.sync.status
        #expect(status.lastSync != nil)
        #expect(status.sent == 1, "one document was sent, not its chunks and photos")
        #expect(status.records >= 8, "but every record that moved is counted as activity")
        #expect(try server.contains("chunks", id: "d1:1:0"))
    }

    @Test func theOriginalTravelsWithTheDocument() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        try await a.importDocument("d1", original: 4096)
        await a.sync.start(server.configuration)

        try await eventually("the record with its original") {
            try server.collection("documents").document(id: "d1")?.blob(forKey: "file")?.length == 4096
        }
    }

    @Test func aSecondDeviceReceivesTheLibraryAndFindsItWithoutIndexingIt() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        try await a.importDocument("d1", title: "Pump manual", chunks: 6, images: 1)
        await a.sync.start(server.configuration)
        await b.sync.start(server.configuration)

        try await eventually("the manual searchable on the second device") { try await b.keywordHits() == 6 }
        #expect(try await b.repo.document(id: "d1")?.title == "Pump manual")
        #expect(try await b.repo.arrivingDocumentIDs().isEmpty)
        try await eventually("one document received, with its chunks and photo counted as activity") {
            let status = await b.sync.status
            return status.received == 1 && status.records >= 8
        }
        #expect(try await b.repo.jobs().isEmpty, "nothing was indexed on the second device")
        #expect(try await b.repo.activeImages(docId: "d1").count == 1)
    }

    @Test func changesGoBothWays() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        await a.sync.start(server.configuration)
        await b.sync.start(server.configuration)
        try await a.importDocument("from-a", chunks: 3)
        try await b.importDocument("from-b", chunks: 2)

        try await eventually("each device has both manuals") {
            let onA = try await a.keywordHits("alpha")
            let onB = try await b.keywordHits("alpha")
            return onA == 5 && onB == 5
        }
    }

    @Test func aRenameReachesTheOtherDevice() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        try await a.importDocument("d1", title: "Old title")
        await a.sync.start(server.configuration)
        await b.sync.start(server.configuration)
        try await eventually("the manual on B") { try await b.repo.document(id: "d1") != nil }

        var record = try #require(try await a.repo.document(id: "d1"))
        record.title = "New title"
        try await a.repo.upsert(record)
        try await eventually("the new title on B") { try await b.repo.document(id: "d1")?.title == "New title" }
    }

    @Test func theStatusPassesThroughConnectingAndSyncing() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        try await a.importDocument("d1", chunks: 30, images: 3)

        var updates = await a.sync.statusUpdates().makeAsyncIterator()
        #expect(await updates.next()?.state == .off)
        await a.sync.start(server.configuration)
        var seen: [SyncState] = []
        while let status = await updates.next() {
            seen.append(status.state)
            if status.state == .upToDate { break }
        }
        #expect(seen.first == .connecting)
        #expect(seen.last == .upToDate)
    }

    @Test func wrongCredentialsAreReportedAsRefusedAndNotRetried() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        await a.sync.start(SyncConfiguration(endpoint: server.endpoint, username: "ipad1", password: "wrong"))

        try await waitForState(a.sync, .error(.credentialsRefused))
        try await Task.sleep(for: .seconds(2))
        #expect(await a.sync.status.state == .error(.credentialsRefused), "it stays refused, it does not keep retrying")
    }

    @Test func anUnreachableServerIsReportedAsUnreachable() async throws {
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        // Nothing listens here.
        await a.sync.start(SyncConfiguration(endpoint: URL(string: "ws://127.0.0.1:9/server")!, username: "ipad1", password: "x"))

        try await eventually("the unreachable state") {
            let state = await a.sync.status.state
            return state == .error(.unreachable) || { if case .error = state { true } else { false } }()
        }
        // Whatever the exact error, it is an error state and never "up to date".
        #expect(await a.sync.status.state != .upToDate)
    }

    @Test func stoppingStopsTheExchange() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        await a.sync.start(server.configuration)
        try await waitForFirstSync(a.sync)
        await a.sync.stop()
        #expect(await a.sync.status.state == .off)

        try await a.importDocument("late", chunks: 2)
        try await Task.sleep(for: .seconds(1.5))
        #expect(try server.count("documents") == 0, "nothing is sent while sync is off")
    }

    @Test func startingAgainReplacesTheRunningReplication() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        await a.sync.start(SyncConfiguration(endpoint: server.endpoint, username: "ipad1", password: "wrong"))
        try await waitForState(a.sync, .error(.credentialsRefused))

        try await a.importDocument("d1", chunks: 2)
        await a.sync.start(server.configuration)
        try await eventually("it syncs with the right credentials") { try server.count("documents") == 1 }
    }

    // MARK: What is held back

    @Test func aDocumentWithAnOriginalOverTheLimitStaysOnTheDevice() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(maxOriginalBytes: 1_000); defer { Task { await a.cleanUp() } }
        try await a.importDocument("big", title: "Big manual", chunks: 3, images: 1, original: 5_000)
        try await a.importDocument("small", title: "Small manual", chunks: 2, original: 500)
        await a.sync.start(server.configuration)

        try await eventually("the small manual on the server") { try server.contains("documents", id: "small") }
        try await eventually("the small manual's chunks") { try server.count("chunks") >= 2 }
        try await Task.sleep(for: .seconds(1))
        #expect(try !server.contains("documents", id: "big"))
        #expect(try server.count("chunks") == 2, "none of the big manual's chunks")
        #expect(try server.count("images") == 0, "nor its photo")
        // It is still searchable here.
        #expect(try await a.keywordHits() == 5)
    }

    @Test func theNotSharedListNamesTheLargeDocumentsWithTheirSize() async throws {
        let a = try SyncDevice(maxOriginalBytes: 1_000); defer { Task { await a.cleanUp() } }
        try await a.importDocument("big", title: "Big manual", original: 5_000)
        try await a.importDocument("small", title: "Small manual", original: 500)

        let unshared = await a.sync.unsharedDocuments()
        #expect(unshared == [UnsharedDocument(id: "big", title: "Big manual", bytes: 5_000)], "\(unshared)")
    }

    @Test func aDocumentAtTheLimitIsShared() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(maxOriginalBytes: 1_000); defer { Task { await a.cleanUp() } }
        try await a.importDocument("exact", chunks: 1, original: 1_000)
        #expect(await a.sync.unsharedDocuments().isEmpty)
        await a.sync.start(server.configuration)
        try await eventually("the document on the server") { try server.contains("documents", id: "exact") }
    }

    @Test func vectorsFromAnotherModelAreNeverSent() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        try await a.importDocument("fleet", chunks: 2)
        try await a.importDocument("other", chunks: 3, chunkModel: "some-other-model@1/768")
        await a.sync.start(server.configuration)

        try await eventually("the fleet chunks") { try server.count("chunks") >= 2 }
        try await Task.sleep(for: .seconds(1))
        #expect(try server.count("chunks") == 2)
        #expect(try server.contains("chunks", id: "fleet:1:0"))
        #expect(try !server.contains("chunks", id: "other:1:0"))
    }

    @Test func imagesFromAnotherModelAreNeverSent() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        try await a.repo.upsert(DocumentRecord(id: "d1", title: "Mixed", type: .pdf))
        try await a.repo.writeImages([
            CouchbaseImageTests.image("d1", 1, 0, model: RepoFixture.identity.tag),
            CouchbaseImageTests.image("d1", 1, 1, model: "some-other-model@1/768"),
        ])
        await a.sync.start(server.configuration)

        try await eventually("the fleet image") { try server.count("images") >= 1 }
        try await Task.sleep(for: .seconds(1))
        #expect(try server.count("images") == 1)
    }

    // MARK: Arrival

    /// Writes a document into the server as it is while another device is still sending it: the record, which names
    /// 3 chunks, and `chunks` of them.
    private func serverDocument(_ server: SyncTestServer, chunks: Range<Int>, of total: Int = 3) throws {
        let documents = try server.collection("documents")
        if try documents.document(id: "d1") == nil {
            let record = MutableDocument(id: "d1")
            record.setString("Partly sent", forKey: "title")
            record.setString("pdf", forKey: "type")
            record.setDouble(1_700_000_000, forKey: "importedAt")
            record.setInt(1, forKey: "activeGeneration")
            record.setInt(total, forKey: "chunkCount")
            record.setInt(0, forKey: "activeImageCount")
            try documents.save(document: record)
        }
        let target = try server.collection("chunks")
        for ordinal in chunks {
            let chunk = RepoFixture.chunk("d1", 1, ordinal, text: "alpha received \(ordinal)")
            let doc = MutableDocument(id: chunk.id)
            doc.setString(chunk.docId, forKey: "docId")
            doc.setInt(chunk.generation, forKey: "generation")
            doc.setInt(chunk.ordinal, forKey: "ordinal")
            doc.setString(chunk.text, forKey: "text")
            doc.setValue(chunk.embedding, forKey: "embedding")
            doc.setString(chunk.embeddingModel, forKey: "embeddingModel")
            try target.save(document: doc)
        }
    }

    @Test func aReceivedDocumentIsInvisibleUntilAllItsChunksArrive() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        try serverDocument(server, chunks: 0..<1)
        await b.sync.start(server.configuration)

        try await eventually("the record and its first chunk on the device") {
            let record = try await b.repo.document(id: "d1")
            let chunks = try await b.repo.chunks(docId: "d1", generation: 1)
            return record != nil && chunks.count == 1
        }
        #expect(try await b.repo.arrivingDocumentIDs() == ["d1"])
        #expect(try await b.keywordHits() == 0, "a partly received manual answers nothing")

        try serverDocument(server, chunks: 1..<3)
        try await eventually("the manual searchable once whole") { try await b.keywordHits() == 3 }
        #expect(try await b.repo.arrivingDocumentIDs().isEmpty)
    }

    // MARK: Deletes and re-index

    @Test func aDeleteOnOneDeviceRemovesTheDocumentChunksAndImagesOnTheOther() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        try await a.importDocument("d1", chunks: 4, images: 2)
        await a.sync.start(server.configuration)
        await b.sync.start(server.configuration)
        try await eventually("the manual on B") { try await b.keywordHits() == 4 }

        try await a.repo.deleteDocument(id: "d1")
        try await eventually("the manual gone from B") {
            let record = try await b.repo.document(id: "d1")
            let chunks = try await b.repo.chunks(docId: "d1", generation: 1)
            let images = try await b.repo.images(docId: "d1", generation: 1)
            return record == nil && chunks.isEmpty && images.isEmpty
        }
        #expect(try await b.keywordHits() == 0)
        #expect(try server.count("documents") == 0, "the server holds only the tombstone")
    }

    @Test func aReindexOnOneDeviceLeavesExactlyTheNewGenerationOnTheOther() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        try await a.importDocument("d1", chunks: 4, images: 1)
        await a.sync.start(server.configuration)
        await b.sync.start(server.configuration)
        try await eventually("the manual on B") { try await b.keywordHits() == 4 }

        try await a.importDocument("d1", chunks: 6, images: 2, generation: 2)
        try await eventually("generation 2 whole on B") {
            let record = try await b.repo.document(id: "d1")
            let hits = try await b.keywordHits()
            return record?.activeGeneration == 2 && record?.chunkCount == 6 && hits == 6
        }
        try await eventually("generation 1 gone from B") {
            let chunks = try await b.repo.chunks(docId: "d1", generation: 1)
            let images = try await b.repo.images(docId: "d1", generation: 1)
            return chunks.isEmpty && images.isEmpty
        }
        #expect(try await b.repo.images(docId: "d1", generation: 2).count == 2)
    }

    // MARK: Device-local data

    @Test func chatsMessagesJobsAndLocalMetaNeverReachTheServer() async throws {
        let server = try SyncTestServer(); defer { server.cleanUp() }
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        try await a.importDocument("d1", chunks: 2)
        let chat = try await a.repo.createChat(title: "Private question")
        try await a.repo.upsert(message: MessageRecord(id: "m1", chatId: chat.id, role: .user, text: "How do I reset it?"))
        try await a.repo.upsert(job: IngestJobRecord(docId: "d1", targetGeneration: 1))
        await a.sync.start(server.configuration)
        try await eventually("the library on the server") { try server.count("chunks") == 2 }
        try await Task.sleep(for: .seconds(1))

        let names = await a.sync.replicatedCollectionNames
        #expect(Set(names) == ["documents", "chunks", "images"] && names.count == 3, "\(names)")
        for name in ["chats", "messages", "ingestJobs", "localMeta"] {
            #expect(try server.count(name) == 0, "\(name) is device-local")
        }
        // And it is all still here.
        #expect(try await a.repo.chats().count == 1)
        #expect(try await a.repo.job(docId: "d1") != nil)
    }
}
