import Adapters
import Foundation
import Ports
import PortsTesting
import Core
import Testing
@testable import ManualBot

@MainActor @Suite struct ModelSetupViewModelTests {
    private func makeModel(llmBehavior: FakeModelBackend.Behavior = .succeed, free: Int64 = .max) -> (ModelSetupViewModel, FakeModelBackend) {
        let hash = String(repeating: "a", count: 64)
        let manifest = ModelManifest(models: [
            ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://x.invalid/l")!, bytes: 3_000, sha256: hash, fileName: "l", displayName: "LLM"),
            ModelSpec(id: "emb", version: "1", role: .embedder, url: URL(string: "https://x.invalid/e")!, bytes: 300, sha256: hash, fileName: "e", displayName: "Embedder"),
        ])
        let backend = FakeModelBackend()
        backend.setBehavior(llmBehavior, for: "llm")
        backend.setFreeBytes(free)
        let store = ModelStore(manifest: manifest, downloader: backend, files: backend, safetyMargin: 0)
        return (ModelSetupViewModel(store: store), backend)
    }

    @Test func rowsListEmbedderFirst() {
        let (model, _) = makeModel()
        #expect(model.rows.map(\.id) == ["emb", "llm"])
        #expect(model.canImport == false)
    }

    @Test func stagedReadinessAfterPartialFailure() async {
        let (model, _) = makeModel(llmBehavior: .fail("offline"))
        let observer = Task { await model.observe() }
        await model.start()
        for _ in 0..<200 where !model.canImport { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.canImport)
        #expect(!model.canChat)
        #expect(model.hasFailure)
        #expect(model.pendingRows.map(\.id) == ["llm"])
        observer.cancel()
    }

    @Test func insufficientStorageIsReported() async {
        let (model, _) = makeModel(free: 1_000)
        let observer = Task { await model.observe() }
        for _ in 0..<200 where model.storage == nil { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.storage?.isSufficient == false)
        #expect(model.storage?.shortfall == 2_300)
        observer.cancel()
    }
}

@Suite struct BundledManifestTests {
    @Test func theBundledManifestIsValidAndCoversBothRoles() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "ModelManifest", withExtension: "json")
            ?? Bundle.main.url(forResource: "ModelManifest", withExtension: "json"))
        let manifest = try ModelManifest.decode(from: Data(contentsOf: url))
        let embedder = try #require(manifest.models.first { $0.role == .embedder })
        let generator = try #require(manifest.models.first { $0.role == .generator })
        #expect(embedder.packaging == .bundled && embedder.fileName == "encoder.mlmodelc")
        #expect(generator.packaging == .file && generator.fileName.hasSuffix(".litertlm"))
        #expect(generator.bytes == 3_659_530_240)
    }
}

private final class BundleToken {}

@Suite struct BundledEmbedderTests {
    @Test func theEmbeddingModelShipsInsideTheApp() throws {
        let url = try #require(Bundle.main.url(forResource: "ModelManifest", withExtension: "json"))
        let manifest = try ModelManifest.decode(from: Data(contentsOf: url))
        let embedder = try #require(manifest.models.first { $0.role == .embedder })
        let root = try #require(Bundle.main.resourceURL).appendingPathComponent("BundledModels", isDirectory: true)
        let files = FileModelFiles(root: FileManager.default.temporaryDirectory, bundleRoot: root)

        #expect(files.isInstalled(embedder), "run ./scripts/fetch-embedder.sh, then xcodegen generate")
        let model = files.installedURL(for: embedder)
        #expect(FileManager.default.fileExists(atPath: model.appendingPathComponent("weights/weight.bin").path))
        // The tokenizer sits next to the model, where the live setup looks for it.
        #expect(FileManager.default.fileExists(atPath: model.deletingLastPathComponent().appendingPathComponent("hf_model/tokenizer.json").path))
    }
}
