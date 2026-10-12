import Foundation
import Ports
import Testing
@testable import Core

/// The values EmbeddingGemma 2 shipped with before profiles existed, written out as the catalog will carry them.
private let embeddingGemma2JSON = """
{
  "identity": {"id": "embeddinggemma-2-text-vision-440m", "version": "1", "dimensions": 256},
  "prompts": {
    "query": "task: search query | text: ",
    "passageWithTitle": "task: search result | title: {title} | text: ",
    "passage": "task: search result | text: ",
    "titleLimit": 60
  },
  "maxInputLength": 512,
  "outputSize": 256,
  "chunker": {"targetTokens": 130, "maxTokens": 180, "overlapTokens": 22, "minTailTokens": 35},
  "thresholds": {"text": 0.28, "image": 0.25, "textToImage": 0.3},
  "supportsImages": true
}
"""

@Suite struct EmbedderProfileTests {
    private let profile = EmbedderProfile.embeddingGemma2

    @Test func theProfileDecodesFromJSONAndEqualsTheBuiltInOne() throws {
        let decoded = try JSONDecoder().decode(EmbedderProfile.self, from: Data(embeddingGemma2JSON.utf8))
        #expect(decoded == profile)
    }

    @Test func theProfileSurvivesARoundTrip() throws {
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(EmbedderProfile.self, from: data) == profile)
    }

    @Test func embeddingGemma2KeepsTheValuesItShippedWith() {
        #expect(profile.identity.tag == "embeddinggemma-2-text-vision-440m@1/256")
        #expect(profile.outputSize == profile.identity.dimensions)
        #expect(profile.maxInputLength == 512)
        #expect(profile.chunker == .embeddingGemma2)
        #expect(profile.supportsImages)
    }

    @Test func theProfileMakesTheRetrievalConfigurationTheAppUsedBefore() {
        #expect(profile.retrievalConfiguration() == RetrievalConfiguration())
    }

    @Test func aProfileChangesOnlyTheDistancesOfTheRetrievalConfiguration() {
        var other = profile
        other.thresholds = RelevanceThresholds(text: 0.4, image: 0.35, textToImage: 0.45)
        let base = RetrievalConfiguration(candidatesPerSearch: 7, resultLimit: 3)
        let configuration = other.retrievalConfiguration(base: base)
        #expect(configuration.maxDistance == 0.4)
        #expect(configuration.imageMaxDistance == 0.35)
        #expect(configuration.textToImageMaxDistance == 0.45)
        #expect(configuration.candidatesPerSearch == 7)
        #expect(configuration.resultLimit == 3)
    }

    @Test func queriesAndChunksUseTheDocumentedTemplates() {
        #expect(profile.prompt(for: "  how do I reset it \n", kind: .query) == "task: search query | text: how do I reset it")
        #expect(profile.prompt(for: "Hold the button.", kind: .chunk(title: " X200 Manual "))
            == "task: search result | title: X200 Manual | text: Hold the button.")
        #expect(profile.prompt(for: "Hold the button.", kind: .chunk(title: "  "))
            == "task: search result | text: Hold the button.")
    }

    @Test func aLongTitleIsCut() {
        let prompt = profile.prompt(for: "x", kind: .chunk(title: String(repeating: "T", count: 200)))
        #expect(prompt == "task: search result | title: \(String(repeating: "T", count: 60)) | text: x")
    }

    @Test func anotherModelsTemplatesAreUsedAsGiven() {
        var other = profile
        other.prompts = EmbeddingPrompts(query: "query: ", passageWithTitle: "passage ({title}): ", passage: "passage: ", titleLimit: 5)
        #expect(other.prompt(for: "q", kind: .query) == "query: q")
        #expect(other.prompt(for: "p", kind: .chunk(title: "Manual")) == "passage (Manua): p")
        #expect(other.prompt(for: "p", kind: .chunk(title: "")) == "passage: p")
    }
}
