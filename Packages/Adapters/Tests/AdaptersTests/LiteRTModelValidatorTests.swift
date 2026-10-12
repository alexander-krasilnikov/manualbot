import Core
import Foundation
import Ports
import Testing
@testable import Adapters

private let generatorFile = ProcessInfo.processInfo.environment["GENERATOR_MODEL_PATH"]
private let embedderFile = ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"]

/// A list of tested embedders with one entry, for the spec these tests use, whose profile asks for `size` values.
private func catalog(asking size: Int) -> EmbedderCatalog {
    var profile = EmbedderProfile.embeddingGemma2
    profile.identity = EmbeddingModelIdentity(id: "embed", version: "1", dimensions: size)
    profile.outputSize = size
    return EmbedderCatalog(embedders: [EmbedderCatalogEntry(spec: spec(.embedder), profile: profile)])
}

private func spec(_ role: ModelRole) -> ModelSpec {
    ModelSpec(id: role == .generator ? "llm" : "embed", version: "1", role: role, url: URL(string: "https://example.com/m")!,
              bytes: 1, sha256: String(repeating: "a", count: 64), fileName: "m.litertlm")
}

@Suite struct LiteRTModelValidatorTests {
    private let fx = Fixtures()

    @Test func aFileThatIsNotAModelIsUnreadable() {
        let junk = fx.write(Data("not a model".utf8), as: "junk.litertlm")
        let validator = LiteRTModelValidator(requiredContextTokens: 4096)
        #expect(throws: ModelValidationError.unreadable) { try validator.validate(junk, for: spec(.generator)) }
    }
}

@Suite(.enabled(if: generatorFile != nil && embedderFile != nil)) struct LiteRTModelValidatorFileTests {
    @Test func theLanguageModelPassesAsAGenerator() throws {
        let validator = LiteRTModelValidator(requiredContextTokens: 4096)
        let description = try validator.validate(URL(fileURLWithPath: generatorFile!), for: spec(.generator))
        #expect(description.kind == .llm)
        #expect(description.maxContextTokens ?? 0 >= 4096)
    }

    @Test func theEmbedderPassesAsAnEmbedderWithItsDimension() throws {
        let validator = LiteRTModelValidator(requiredContextTokens: 4096)
        let description = try validator.validate(URL(fileURLWithPath: embedderFile!), for: spec(.embedder))
        #expect(description.kind == .embedder)
        #expect(description.embeddingDimension == 768, "the file's largest output; the profile truncates to 256")
        #expect(description.supportsImages)
        #expect(description.embeddingInputLengths?.contains(512) == true, "the input lengths the file supports: \(String(describing: description.embeddingInputLengths))")
    }

    @Test func theEmbedderFailsAsAGenerator() {
        let validator = LiteRTModelValidator(requiredContextTokens: 4096)
        #expect(throws: ModelValidationError.notALanguageModel) {
            try validator.validate(URL(fileURLWithPath: embedderFile!), for: spec(.generator))
        }
    }

    @Test func theLanguageModelFailsAsAnEmbedder() {
        let validator = LiteRTModelValidator(requiredContextTokens: 4096)
        #expect(throws: ModelValidationError.notAnEmbeddingModel) {
            try validator.validate(URL(fileURLWithPath: generatorFile!), for: spec(.embedder))
        }
    }

    @Test func aContextOfAMillionTokensFails() {
        let validator = LiteRTModelValidator(requiredContextTokens: 1_000_000)
        #expect(throws: ModelValidationError.contextTooSmall) {
            try validator.validate(URL(fileURLWithPath: generatorFile!), for: spec(.generator))
        }
    }

    @Test func aTestedEmbedderThatAsksForLessThanTheFileGivesPasses() throws {
        let validator = LiteRTModelValidator(requiredContextTokens: 4096, catalog: catalog(asking: 256))
        #expect(try validator.validate(URL(fileURLWithPath: embedderFile!), for: spec(.embedder)).embeddingDimension == 768)
    }

    @Test func anEmbedderOutsideTheListOnlyHasToReportASize() throws {
        let validator = LiteRTModelValidator(requiredContextTokens: 4096, catalog: catalog(asking: 1024))
        var other = spec(.embedder)
        other.id = "found-by-search"   // not in the list, so nothing is asked of its size
        #expect(try validator.validate(URL(fileURLWithPath: embedderFile!), for: other).embeddingDimension == 768)
    }

    @Test func aDimensionLargerThanTheFileCanProduceFails() {
        let validator = LiteRTModelValidator(requiredContextTokens: 4096, catalog: catalog(asking: 1024))
        #expect(throws: ModelValidationError.wrongDimension(expected: 1024, found: 768)) {
            try validator.validate(URL(fileURLWithPath: embedderFile!), for: spec(.embedder))
        }
    }
}
