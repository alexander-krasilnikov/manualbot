@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// Stands in for Sync Gateway: a database behind a `URLEndpointListener`, with the replicated collections and basic
/// authentication. Real replication runs against it, in-process.
final class SyncTestServer: @unchecked Sendable {
    static let username = "ipad1"
    static let password = "secret"

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("server-\(UUID().uuidString)")
    let database: Database
    private let listener: URLEndpointListener

    init() throws {
        try CouchbaseBootstrap.enableVectorSearch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var config = DatabaseConfiguration()
        config.directory = root.path
        database = try Database(name: "server", config: config)
        var exposed: [Collection] = []
        for name in CouchbaseSchema.replicated {
            exposed.append(try database.createCollection(name: name, scope: CouchbaseSchema.scope))
        }
        // Device-local collections exist here too, only to show that nothing arrives in them.
        for name in CouchbaseSchema.deviceLocal { _ = try database.createCollection(name: name, scope: CouchbaseSchema.scope) }
        var listenerConfig = URLEndpointListenerConfiguration(collections: exposed)
        listenerConfig.disableTLS = true
        listenerConfig.authenticator = ListenerPasswordAuthenticator { user, password in
            user == Self.username && password == Self.password
        }
        listener = URLEndpointListener(config: listenerConfig)
        try listener.start()
    }

    var endpoint: URL { URL(string: "ws://127.0.0.1:\(listener.port ?? 0)/\(database.name)")! }

    var configuration: SyncConfiguration {
        SyncConfiguration(endpoint: endpoint, username: Self.username, password: Self.password)
    }

    func collection(_ name: String) throws -> Collection {
        try #require(try database.collection(name: name, scope: CouchbaseSchema.scope))
    }

    func count(_ name: String) throws -> Int { Int(try collection(name).count) }

    func contains(_ name: String, id: String) throws -> Bool { try collection(name).document(id: id) != nil }

    func cleanUp() {
        listener.stop()
        try? database.close()
        try? FileManager.default.removeItem(at: root)
    }
}

/// One iPad: a library on its own database, and the replicator that syncs it.
struct SyncDevice {
    let fixture: RepoFixture
    let sync: CouchbaseLibrarySync

    var repo: CouchbaseDocumentRepository { fixture.repo }

    init(embedding: EmbeddingModelIdentity = RepoFixture.identity, imageFeatures: EmbeddingModelIdentity = RepoFixture.imageIdentity,
         maxOriginalBytes: Int64 = 20 * 1024 * 1024, tracer: any Tracer = NoTracer()) throws {
        fixture = try RepoFixture(embedding: embedding, imageFeatures: imageFeatures)
        sync = CouchbaseLibrarySync(
            repository: fixture.repo, fleetModelTag: embedding.tag, fleetImageModelTag: imageFeatures.tag,
            maxOriginalBytes: maxOriginalBytes, tracer: tracer)
    }

    func cleanUp() async {
        await sync.stop()
        await fixture.cleanUp()
    }

    /// Imports a document as ingestion would: record, original, chunks, images, then the switch to the new set.
    func importDocument(
        _ id: String, title: String = "Manual", chunks: Int = 4, images: Int = 0, original: Int = 100, generation: Int = 1,
        chunkModel: String? = nil
    ) async throws {
        if generation == 1 {
            try await repo.upsert(DocumentRecord(id: id, title: title, type: .pdf))
            let file = fixture.root.appendingPathComponent("\(id).pdf")
            try Data(repeating: 7, count: original).write(to: file)
            try await repo.attachOriginal(fileURL: file, contentType: "application/pdf", to: id)
        }
        try await repo.writeChunks((0..<chunks).map {
            var chunk = RepoFixture.chunk(id, generation, $0, text: "alpha \(id) \($0)")
            if let chunkModel { chunk.embeddingModel = chunkModel }
            return chunk
        })
        if images > 0 { try await repo.writeImages((0..<images).map { CouchbaseImageTests.image(id, generation, $0) }) }
        try await repo.activate(generation: generation, for: id)
    }

    func keywordHits(_ term: String = "alpha") async throws -> Int {
        try await repo.keywordSearch(
            terms: [term], limit: 100, filter: SearchFilter(documentIDs: nil, embeddingModel: RepoFixture.identity.tag)
        ).count
    }
}

/// Waits until `condition` holds, polling; fails the test with `message` after `timeout` seconds.
func eventually(
    _ message: @autoclosure () -> String = "condition", timeout: TimeInterval = 20, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("Timed out waiting for \(message())", sourceLocation: sourceLocation)
}

/// Waits for `state` to be the sync's status.
func waitForState(_ sync: CouchbaseLibrarySync, _ state: SyncState, timeout: TimeInterval = 20, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    try await eventually("sync state \(state)", timeout: timeout, sourceLocation: sourceLocation) { await sync.status.state == state }
}
