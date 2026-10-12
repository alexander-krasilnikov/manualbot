import Foundation
import Ports
import Testing
@testable import Core

@Suite struct EmbedderCatalogTests {
    private func spec(_ id: String = "embeddinggemma-2-text-vision-440m", role: ModelRole = .embedder, bytes: Int64 = 1_000,
                      sha: String = String(repeating: "a", count: 64)) -> ModelSpec {
        ModelSpec(id: id, version: "1", role: role, url: URL(string: "https://example.com/\(id)")!, bytes: bytes, sha256: sha,
                  fileName: "\(id).litertlm", licence: "Apache License 2.0")
    }

    private func entry(_ spec: ModelSpec, edit: (inout EmbedderProfile) -> Void = { _ in }) -> EmbedderCatalogEntry {
        var profile = EmbedderProfile.embeddingGemma2
        profile.identity.id = spec.id
        edit(&profile)
        return EmbedderCatalogEntry(spec: spec, profile: profile)
    }

    private func decode(_ entries: [EmbedderCatalogEntry]) throws -> EmbedderCatalog {
        try EmbedderCatalog.decode(from: JSONEncoder().encode(EmbedderCatalog(embedders: entries)))
    }

    @Test func aValidCatalogDecodesAndEntriesAreFoundById() throws {
        let catalog = try decode([entry(spec()), entry(spec("second-embedder"))])
        #expect(catalog.embedders.count == 2)
        #expect(catalog.entry(id: "second-embedder")?.profile.identity.id == "second-embedder")
        #expect(catalog.entry(id: "nope") == nil)
    }

    @Test func aDuplicateIdIsRejected() {
        #expect(throws: CatalogError.duplicateModel("embeddinggemma-2-text-vision-440m")) { try decode([entry(spec()), entry(spec())]) }
    }

    @Test func aMalformedChecksumIsRejected() {
        #expect(throws: CatalogError.invalidChecksum("embeddinggemma-2-text-vision-440m")) { try decode([entry(spec(sha: "xyz"))]) }
    }

    @Test func aZeroSizeIsRejected() {
        #expect(throws: CatalogError.invalidSize("embeddinggemma-2-text-vision-440m")) { try decode([entry(spec(bytes: 0))]) }
    }

    @Test func aLanguageModelIsNotAnEmbedder() {
        #expect(throws: CatalogError.notAnEmbedder("gemma")) { try decode([entry(spec("gemma", role: .generator))]) }
    }

    @Test func aProfileForAnotherModelIsRejected() {
        #expect(throws: CatalogError.inconsistentProfile("embeddinggemma-2-text-vision-440m")) {
            try decode([entry(spec()) { $0.identity.id = "something-else" }])
        }
        #expect(throws: CatalogError.inconsistentProfile("embeddinggemma-2-text-vision-440m")) {
            try decode([entry(spec()) { $0.identity.version = "9" }])
        }
    }

    @Test func aProfileThatAsksForAnotherSizeThanItDeclaresIsRejected() {
        #expect(throws: CatalogError.inconsistentProfile("embeddinggemma-2-text-vision-440m")) {
            try decode([entry(spec()) { $0.outputSize = 128 }])
        }
    }
}
