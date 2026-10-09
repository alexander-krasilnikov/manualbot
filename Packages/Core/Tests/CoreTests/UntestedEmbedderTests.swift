import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

/// An embedding model found by search is used with generic settings built from what its file says (design D12).
@Suite struct UntestedEmbedderTests {
    private let spec = ModelSpec(id: "some-embedder", version: "rev1", role: .embedder, url: URL(string: "https://example.com/e")!, bytes: 1_000,
                                 sha256: String(repeating: "a", count: 64), fileName: "e.litertlm", licence: "apache-2.0")

    @Test func theLongestInputUpTo512IsChosen() {
        #expect(EmbeddingDescription.inputLength(from: [128, 256, 512, 1024, 8192]) == 512)
        #expect(EmbeddingDescription.inputLength(from: [128, 256]) == 256)
        #expect(EmbeddingDescription.inputLength(from: [1024, 2048]) == 1024, "the shortest, when all are longer")
        #expect(EmbeddingDescription.inputLength(from: nil) == 512)
        #expect(EmbeddingDescription.inputLength(from: []) == 512)
    }

    @Test func chunksAreSizedForTheInputLength() {
        #expect(ChunkerConfiguration.sized(forInputLength: 512) == .embeddingGemma2)
        #expect(ChunkerConfiguration.sized(forInputLength: 1024) == .embeddingGemma2)
        #expect(ChunkerConfiguration.sized(forInputLength: 256).maxTokens < ChunkerConfiguration.embeddingGemma2.maxTokens)
        #expect(ChunkerConfiguration.sized(forInputLength: 128).maxTokens < ChunkerConfiguration.sized(forInputLength: 256).maxTokens)
    }

    @Test func theGenericProfileHasNoTemplatesAndTheFilesOwnSizes() {
        let profile = EmbedderProfile.untested(for: spec, description: EmbeddingDescription(dimension: 384, supportsImages: false, maxInputLength: 256))
        #expect(profile.identity == EmbeddingModelIdentity(id: "some-embedder", version: "rev1", dimensions: 384))
        #expect(profile.outputSize == 384, "no truncation: it is only safe for a model trained for it")
        #expect(profile.maxInputLength == 256 && profile.supportsImages == false)
        #expect(profile.prompt(for: "  a question ", kind: .query) == "a question")
        #expect(profile.prompt(for: "a passage", kind: .chunk(title: "Manual")) == "a passage", "the title is not used without a template")
        #expect(profile.retrievalConfiguration() == RetrievalConfiguration(), "the distances the app ships with")
    }

    @Test func installingAnEmbedderKeepsWhatTheRuntimeReadFromItsFile() async throws {
        let backend = FakeModelBackend()
        let manifest = ModelManifest(models: [
            ModelSpec(id: "emb", version: "1", role: .embedder, url: URL(string: "https://example.com/emb")!, bytes: 300,
                      sha256: String(repeating: "b", count: 64), fileName: "emb"),
            ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://example.com/llm")!, bytes: 3_000,
                      sha256: String(repeating: "c", count: 64), fileName: "llm"),
        ])
        let store = ModelStore(manifest: manifest, downloader: backend, files: backend, validator: FakeModelValidator(), safetyMargin: 0)
        try await store.start()
        try await store.install(ModelRecord(spec: spec.with(sha: "a"), source: .search, chosenByUser: true))

        let embedder = try #require(await store.record(for: "some-embedder"))
        #expect(embedder.embedding == EmbeddingDescription(dimension: 768, supportsImages: false, maxInputLength: 512))
        #expect(await store.record(for: "llm")?.embedding == nil, "a language model has none")

        let relaunched = ModelStore(manifest: manifest, downloader: backend, files: backend, validator: FakeModelValidator(), safetyMargin: 0)
        await relaunched.refresh()
        #expect(await relaunched.record(for: "some-embedder")?.embedding == embedder.embedding, "it survives a new store")
    }

    @Test func aRecordSavedBeforeEmbeddersWereSearchableStillDecodes() throws {
        let json = """
        {"spec":{"id":"e","version":"1","role":"embedder","url":"https://example.com/e","bytes":5,"sha256":"\(String(repeating: "a", count: 64))","fileName":"e"},"source":"catalog","chosenByUser":true}
        """
        let record = try JSONDecoder().decode(ModelRecord.self, from: Data(json.utf8))
        #expect(record.embedding == nil)
    }
}

private extension ModelSpec {
    func with(sha: String) -> ModelSpec {
        var copy = self
        copy.sha256 = String(repeating: sha, count: 64)
        return copy
    }
}
