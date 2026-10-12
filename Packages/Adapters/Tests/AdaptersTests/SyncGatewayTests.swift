@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports
import PortsTesting
import Core
import Testing
@testable import Adapters

/// Replication through a real Sync Gateway and Couchbase Server: the Docker Compose stack in `sync/`. Runs only when
/// `SYNC_GATEWAY_URL` is set, for example:
///
///     cd sync && docker compose up -d --wait
///     SYNC_GATEWAY_URL=ws://localhost:4984/manualbot swift test --filter SyncGatewayTests
///
/// `SYNC_GATEWAY_PASSWORD` is the password of the accounts `ipad1` and `ipad2` (`manualbot-ipad` unless the stack's `.env` says
/// otherwise). Each test uses documents with new IDs and deletes them at the end, so the stack can be reused.
private let gatewayURL = ProcessInfo.processInfo.environment["SYNC_GATEWAY_URL"].flatMap(URL.init(string:))

@Suite(.serialized, .enabled(if: gatewayURL != nil)) struct SyncGatewayTests {
    private func configuration(_ user: String, password: String? = nil) -> SyncConfiguration {
        SyncConfiguration(
            endpoint: gatewayURL!, username: user,
            password: password ?? ProcessInfo.processInfo.environment["SYNC_GATEWAY_PASSWORD"] ?? "manualbot-ipad")
    }

    @Test func aLibraryWithAnOriginalAtTheLimitReachesAnotherDeviceThroughTheStack() async throws {
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        let id = "gateway-\(UUID().uuidString)"
        let limit = Int(IngestionService.maxOriginalBytes)
        try await a.importDocument(id, title: "At the limit", chunks: 5, images: 2, original: limit)

        await a.sync.start(configuration("ipad1"))
        await b.sync.start(configuration("ipad2"))
        try await eventually("the document searchable on the second device", timeout: 90) {
            let record = try await b.repo.document(id: id)
            let hits = try await b.repo.keywordSearch(
                terms: [id], limit: 20, filter: SearchFilter(documentIDs: [id], embeddingModel: RepoFixture.identity.tag)).count
            return record?.activeGeneration == 1 && hits == 5
        }
        #expect(try await b.repo.images(docId: id, generation: 1).count == 2)
        let original = try #require(try await b.repo.originalFileURL(docId: id))
        let size = (try FileManager.default.attributesOfItem(atPath: original.path)[.size] as? Int) ?? 0
        #expect(size == limit, "the 20 MB original arrived whole")
        #expect(try await b.repo.arrivingDocumentIDs().isEmpty)

        // Delete it on A: it goes from B too, and from the server.
        try await a.repo.deleteDocument(id: id)
        try await eventually("the document gone from the second device", timeout: 60) { try await b.repo.document(id: id) == nil }
    }

    @Test func aRenameOnOneDeviceReachesTheOtherThroughTheStack() async throws {
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        let id = "gateway-rename-\(UUID().uuidString)"
        try await a.importDocument(id, title: "Old title", chunks: 2)
        await a.sync.start(configuration("ipad1"))
        await b.sync.start(configuration("ipad2"))
        try await eventually("the document on the second device", timeout: 60) { try await b.repo.document(id: id) != nil }

        var record = try #require(try await a.repo.document(id: id))
        record.title = "New title"
        try await a.repo.upsert(record)
        try await eventually("the new title on the second device", timeout: 60) { try await b.repo.document(id: id)?.title == "New title" }
        #expect(try await b.repo.document(id: id)?.activeGeneration == 1, "a rename does not disturb the index")
        try await a.repo.deleteDocument(id: id)
    }

    @Test func aMoreThanLimitOriginalStaysOnTheDeviceAndTheStackNeverSeesIt() async throws {
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        let b = try SyncDevice(); defer { Task { await b.cleanUp() } }
        let big = "gateway-big-\(UUID().uuidString)"
        let small = "gateway-small-\(UUID().uuidString)"
        try await a.importDocument(big, title: "Too big", chunks: 2, original: Int(IngestionService.maxOriginalBytes) + 1)
        try await a.importDocument(small, title: "Fits", chunks: 2, original: 1024)
        #expect(await a.sync.unsharedDocuments().map(\.id) == [big])

        await a.sync.start(configuration("ipad1"))
        await b.sync.start(configuration("ipad2"))
        try await eventually("the small document on the second device", timeout: 60) { try await b.repo.document(id: small) != nil }
        try await Task.sleep(for: .seconds(2))
        #expect(try await b.repo.document(id: big) == nil, "the large one was never sent")
        #expect(try await a.keywordHitsFor(big) == 2, "and it still works where it is")

        try await a.repo.deleteDocument(id: small)
        try await a.repo.deleteDocument(id: big)
    }

    @Test func aWrongPasswordIsRefusedByTheRealGateway() async throws {
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        await a.sync.start(configuration("ipad1", password: "not-the-password"))
        try await waitForState(a.sync, .error(.credentialsRefused), timeout: 30)
    }

    @Test func anUnknownAccountIsRefused() async throws {
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        await a.sync.start(configuration("nobody"))
        try await waitForState(a.sync, .error(.credentialsRefused), timeout: 30)
    }

    @Test func theRightPasswordReachesUpToDate() async throws {
        let a = try SyncDevice(); defer { Task { await a.cleanUp() } }
        await a.sync.start(configuration("ipad3"))
        try await waitForFirstSync(a.sync, timeout: 30)
    }
}

private extension SyncDevice {
    /// Keyword hits of one document, found by the ID its chunks carry in their text.
    func keywordHitsFor(_ id: String) async throws -> Int {
        try await repo.keywordSearch(
            terms: [id], limit: 20, filter: SearchFilter(documentIDs: [id], embeddingModel: RepoFixture.identity.tag)).count
    }
}
