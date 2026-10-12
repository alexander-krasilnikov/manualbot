import Adapters
import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

/// Simulates quitting and relaunching over real files and a real Couchbase Lite database.
@MainActor @Suite struct ModelRecoveryTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString)")
    private let hash = String(repeating: "a", count: 64)

    private func manifest() -> ModelManifest {
        ModelManifest(models: [
            ModelSpec(id: "emb", version: "1", role: .embedder, url: URL(string: "https://x.invalid/e")!, bytes: 100,
                      sha256: hash, fileName: "emb.bin", displayName: "Embedder"),
            ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://x.invalid/l")!, bytes: 200,
                      sha256: hash, fileName: "llm.bin", displayName: "LLM"),
        ])
    }

    /// A fresh "process": new store and view model over the same directories.
    private func launch(manifest: ModelManifest) async -> (ModelSetupViewModel, Task<Void, Never>) {
        let files = FileModelFiles(root: root.appendingPathComponent("Models"))
        let store = ModelStore(manifest: manifest, downloader: FakeModelBackend(), files: files)
        let model = ModelSetupViewModel(store: store)
        let observer = Task { await model.observe() }
        // The first post-refresh snapshot also publishes storage, so this marks "launch finished".
        for _ in 0..<1000 where model.storage == nil { try? await Task.sleep(for: .milliseconds(5)) }
        return (model, observer)
    }

    private func place(_ spec: ModelSpec) throws {
        let files = FileModelFiles(root: root.appendingPathComponent("Models"))
        let url = files.installedURL(for: spec)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: Int(spec.bytes)).write(to: url)
    }

    @Test func missingLanguageModelReturnsToSetupWhileLibraryAndChatsSurvive() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = manifest()
        let embedding = EmbeddingModelIdentity(id: "emb", version: "1", dimensions: 768)
        let dbDirectory = root.appendingPathComponent("db"), cache = root.appendingPathComponent("originals")

        // First run: both models installed, user has a document and a chat.
        for spec in manifest.models { try place(spec) }
        let first = try CouchbaseDocumentRepository(directory: dbDirectory, originalsCache: cache, embedding: embedding)
        try await first.upsert(DocumentRecord(id: "d1", title: "Manual A", type: .pdf, pageCount: 3, activeGeneration: 1))
        try await first.upsert(chat: ChatRecord(id: "c1", title: "Reset help", pinnedDocIds: ["d1"]))
        try await first.close()
        let (before, beforeTask) = await launch(manifest: manifest)
        #expect(before.canChat)
        beforeTask.cancel()

        // The system removes the language model file. Relaunch.
        let files = FileModelFiles(root: root.appendingPathComponent("Models"))
        try FileManager.default.removeItem(at: files.installedURL(for: manifest.models[1]))
        let (after, afterTask) = await launch(manifest: manifest)
        defer { afterTask.cancel() }

        // Setup offers only the missing model; import still works; chat waits.
        #expect(after.setupRows.map(\.id) == ["llm"])
        #expect(after.canImport)
        #expect(!after.canChat)
        #expect(after.rows.first { $0.id == "emb" }?.state == .installed)

        // Nothing the user created was lost.
        let second = try CouchbaseDocumentRepository(directory: dbDirectory, originalsCache: cache, embedding: embedding)
        #expect(try await second.document(id: "d1")?.title == "Manual A")
        #expect(try await second.chat(id: "c1")?.pinnedDocIds == ["d1"])
        try await second.close()
    }

    @Test func missingEmbedderListsOnlyTheEmbedder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = manifest()
        try place(manifest.models[1])  // only the language model exists
        let (model, task) = await launch(manifest: manifest)
        defer { task.cancel() }
        #expect(model.setupRows.map(\.id) == ["emb"])
        #expect(!model.canImport)
    }

    @Test func freshInstallListsEveryModel() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, task) = await launch(manifest: manifest())
        defer { task.cancel() }
        #expect(model.setupRows.map(\.id) == ["emb", "llm"])
    }
}
