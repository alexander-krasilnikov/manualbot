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
        for _ in 0..<400 where !(model.canImport && model.hasFailure) { try? await Task.sleep(for: .milliseconds(5)) }
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

    @Test func aMissingModelInUseGoesBackToSetupAloneWithoutActivatingTheInstalledDefault() async throws {
        let hash = String(repeating: "a", count: 64)
        let manifest = ModelManifest(models: [
            ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://x.invalid/l")!, bytes: 3_000, sha256: hash, fileName: "l", displayName: "LLM"),
            ModelSpec(id: "emb", version: "1", role: .embedder, url: URL(string: "https://x.invalid/e")!, bytes: 300, sha256: hash, fileName: "e", displayName: "Embedder"),
        ])
        let alternative = ModelSpec(id: "alt", version: "1", role: .generator, url: URL(string: "https://x.invalid/a")!, bytes: 500, sha256: hash, fileName: "a", displayName: "Alternative")
        let backend = FakeModelBackend()
        backend.markInstalled("llm")
        backend.markInstalled("emb")
        // Activated on an earlier launch, then deleted outside the app: its record and choice remain.
        try backend.writeRecord(ModelRecord(spec: alternative, source: .search, chosenByUser: true))
        try backend.saveActive(ActiveModels(generator: "alt"))

        let store = ModelStore(manifest: manifest, downloader: backend, files: backend, safetyMargin: 0)
        let model = ModelSetupViewModel(store: store)
        let observer = Task { await model.observe() }
        for _ in 0..<200 where !model.isLoaded { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(model.rows.map(\.id) == ["emb", "alt"], "the models in use, not every default")
        #expect(model.pendingRows.map(\.id) == ["alt"])
        #expect(model.canChat == false)
        observer.cancel()
    }
}

@Suite struct BundledManifestTests {
    @Test func theBundledManifestIsValidAndBothModelsAreDownloaded() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "ModelManifest", withExtension: "json")
            ?? Bundle.main.url(forResource: "ModelManifest", withExtension: "json"))
        let manifest = try ModelManifest.decode(from: Data(contentsOf: url))
        let embedder = try #require(manifest.models.first { $0.role == .embedder })
        let generator = try #require(manifest.models.first { $0.role == .generator })
        #expect(embedder.id == "embeddinggemma-2-text-vision-440m" && embedder.packaging == .file)
        #expect(embedder.fileName == "embeddinggemma-2-text-vision-440m.litertlm")
        #expect(embedder.bytes == 387_710_976)
        #expect(embedder.sha256 == "92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0")
        #expect(embedder.url.absoluteString == "https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/main/embeddinggemma-2-text-vision-440m.litertlm")
        #expect(embedder.displayName == "EmbeddingGemma 2")
        #expect(generator.packaging == .file && generator.fileName.hasSuffix(".litertlm"))
        #expect(generator.id == "gemma-4-e2b" && generator.displayName == "Gemma 4 E2B")
        #expect(generator.bytes == 2_588_147_712)
        #expect(generator.sha256 == "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c")
        #expect(generator.fileName == "gemma-4-E2B-it.litertlm")
        #expect(embedder.identityMatchesTheEmbedder, "the manifest's model is the one `LiteRTEmbedder` makes vectors for")
    }

    @Test func theBundledCatalogDecodesAndItsEmbedderIsTheManifestsDefault() throws {
        func bundled(_ name: String) throws -> Data {
            let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json")
                ?? Bundle.main.url(forResource: name, withExtension: "json"))
            return try Data(contentsOf: url)
        }
        let manifest = try ModelManifest.decode(from: bundled("ModelManifest"))
        let catalog = try EmbedderCatalog.decode(from: bundled("EmbedderCatalog"))
        let embedder = try #require(manifest.models.first { $0.role == .embedder })
        let entry = try #require(catalog.entry(id: embedder.id), "the default embedder is in the catalog")
        #expect(entry.spec.version == embedder.version && entry.spec.bytes == embedder.bytes && entry.spec.sha256 == embedder.sha256)
        #expect(entry.spec.url == embedder.url && entry.spec.fileName == embedder.fileName)
        #expect(entry.profile == EmbedderProfile.embeddingGemma2, "the catalog and the built-in constants say the same")
        #expect(entry.profile.supportsImages)
    }

    @Test func theCatalogOffersTheEvaluatedCandidatesWithTheShippedSettings() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "EmbedderCatalog", withExtension: "json")
            ?? Bundle.main.url(forResource: "EmbedderCatalog", withExtension: "json"))
        let catalog = try EmbedderCatalog.decode(from: Data(contentsOf: url))
        #expect(catalog.embedders.map(\.id) == ["embeddinggemma-2-text-vision-440m", "embeddinggemma-2-text-270m", "embeddinggemma-2-740m"])
        // The candidates passed the evaluation with the shipped prompts, chunk sizes and distances (design D2).
        for (id, images) in [("embeddinggemma-2-text-270m", false), ("embeddinggemma-2-740m", true)] {
            let entry = try #require(catalog.entry(id: id))
            var expected = EmbedderProfile.embeddingGemma2
            expected.identity.id = id
            expected.supportsImages = images
            #expect(entry.profile == expected, "\(id)")
            #expect(entry.spec.licence == "Apache License 2.0" && entry.spec.url.absoluteString.contains("/resolve/"), "pinned to a revision: \(id)")
        }
    }

    @Test func theManifestsEmbedderDownloadsFirstAndImportOpensBeforeTheLanguageModelArrives() async throws {
        let url = try #require(Bundle.main.url(forResource: "ModelManifest", withExtension: "json"))
        let manifest = try ModelManifest.decode(from: Data(contentsOf: url))
        let backend = FakeModelBackend()
        backend.setBehavior(.suspend, for: "gemma-4-e2b")
        let store = ModelStore(manifest: manifest, downloader: backend, files: backend, safetyMargin: 0)
        let task = Task { try await store.start() }
        while await store.state(of: "embeddinggemma-2-text-vision-440m") != .installed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await store.canImport)
        #expect(await store.canChat == false)
        task.cancel()
        _ = try? await task.value
    }
}

private extension ModelSpec {
    /// Whether this entry is the model `LiteRTEmbedder` declares.
    var identityMatchesTheEmbedder: Bool { id == EmbedderProfile.embeddingGemma2.identity.id && version == EmbedderProfile.embeddingGemma2.identity.version }
}

private final class BundleToken {}
