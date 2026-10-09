import Foundation
import Ports

/// The text put around a question or a passage before a model embeds it. Each embedding model documents its own.
public struct EmbeddingPrompts: Sendable, Codable, Equatable {
    /// Put before a question.
    public var query: String
    /// Put before a passage that has a title. `{title}` stands for the title.
    public var passageWithTitle: String
    /// Put before a passage that has none.
    public var passage: String
    /// Titles longer than this many characters are cut.
    public var titleLimit: Int

    public init(query: String, passageWithTitle: String, passage: String, titleLimit: Int) {
        self.query = query
        self.passageWithTitle = passageWithTitle
        self.passage = passage
        self.titleLimit = titleLimit
    }
}

/// The cosine distances at which an embedding model's matches stop counting. They depend on the model, so each profile
/// carries its own, tuned on the evaluation sets. `RetrievalConfiguration` explains how each is used and how it was tuned.
public struct RelevanceThresholds: Sendable, Codable, Equatable {
    /// A question's best chunk is relevant at or below this.
    public var text: Double
    /// A library photo matches the question's photo at or below this.
    public var image: Double
    /// Typed words match a photo by meaning at or below this.
    public var textToImage: Double

    public init(text: Double, image: Double, textToImage: Double) {
        self.text = text
        self.image = image
        self.textToImage = textToImage
    }
}

/// Everything that is specific to one embedding model: how to ask it, how long its input may be, how to cut documents
/// for it, and where its distances separate a good match from a poor one. A second embedding model is a second profile,
/// not new code. The embedder, the chunker and the retriever are all built from it.
public struct EmbedderProfile: Sendable, Codable, Equatable {
    /// Names the vectors this model makes. Stored on every chunk, so vectors from another model are never compared.
    public var identity: EmbeddingModelIdentity
    public var prompts: EmbeddingPrompts
    /// The engine's text input limit, in tokens. Longer text is shortened by the embedder, not rejected.
    public var maxInputLength: Int
    /// The vector size asked of the engine. It equals `identity.dimensions` in any profile that works; the embedder
    /// checks every vector it gets back against `identity.dimensions`.
    public var outputSize: Int
    /// How documents are cut so that every chunk fits `maxInputLength`.
    public var chunker: ChunkerConfiguration
    public var thresholds: RelevanceThresholds
    /// Whether the model embeds photos into the same space as text. Without it, photo search is off.
    public var supportsImages: Bool

    public init(
        identity: EmbeddingModelIdentity, prompts: EmbeddingPrompts, maxInputLength: Int, outputSize: Int,
        chunker: ChunkerConfiguration, thresholds: RelevanceThresholds, supportsImages: Bool
    ) {
        self.identity = identity
        self.prompts = prompts
        self.maxInputLength = maxInputLength
        self.outputSize = outputSize
        self.chunker = chunker
        self.thresholds = thresholds
        self.supportsImages = supportsImages
    }

    /// The text sent to the model for a question or a passage: its documented template, then the trimmed text.
    public func prompt(for text: String, kind: EmbeddingKind) -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .query:
            return prompts.query + body
        case .chunk(let title):
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return prompts.passage + body }
            let shown = String(clean.prefix(prompts.titleLimit))
            return prompts.passageWithTitle.replacingOccurrences(of: "{title}", with: shown) + body
        }
    }

    /// `base` with this model's distances: the other retrieval settings do not depend on the model.
    public func retrievalConfiguration(base: RetrievalConfiguration = RetrievalConfiguration()) -> RetrievalConfiguration {
        var configuration = base
        configuration.maxDistance = thresholds.text
        configuration.imageMaxDistance = thresholds.image
        configuration.textToImageMaxDistance = thresholds.textToImage
        return configuration
    }
}

extension EmbedderProfile {
    /// Generic settings for an embedding model the app has not tested: no prompt templates, the vector size the file
    /// reports (a truncation is only safe for a model trained for it), an input length the file supports, chunk sizes
    /// to match, and the distances the app ships with. How well search works with them is unknown, which is why such a
    /// model is labelled untested wherever it appears (design D12).
    public static func untested(for spec: ModelSpec, description: EmbeddingDescription) -> EmbedderProfile {
        let defaults = RetrievalConfiguration()
        return EmbedderProfile(
            identity: EmbeddingModelIdentity(id: spec.id, version: spec.version, dimensions: description.dimension),
            prompts: EmbeddingPrompts(query: "", passageWithTitle: "", passage: "", titleLimit: 60),
            maxInputLength: description.maxInputLength,
            outputSize: description.dimension,
            chunker: .sized(forInputLength: description.maxInputLength),
            thresholds: RelevanceThresholds(text: defaults.maxDistance, image: defaults.imageMaxDistance, textToImage: defaults.textToImageMaxDistance),
            supportsImages: description.supportsImages)
    }

    /// EmbeddingGemma 2 Text Vision 440M: 256-dimension vectors (a truncation of its 768), the prompts its model card
    /// documents, a 512-token input, and photos in the same space as text. These are the values the app used before
    /// profiles existed, taken from where they were tuned (`ChunkerConfiguration.embeddingGemma2` and the defaults of
    /// `RetrievalConfiguration`), so there is still one place for the numbers and the reasons behind them.
    public static let embeddingGemma2 = EmbedderProfile(
        identity: EmbeddingModelIdentity(id: "embeddinggemma-2-text-vision-440m", version: "1", dimensions: 256),
        prompts: EmbeddingPrompts(
            query: "task: search query | text: ",
            passageWithTitle: "task: search result | title: {title} | text: ",
            passage: "task: search result | text: ",
            titleLimit: 60),
        maxInputLength: 512,
        outputSize: 256,
        chunker: .embeddingGemma2,
        thresholds: RelevanceThresholds(
            text: RetrievalConfiguration().maxDistance,
            image: RetrievalConfiguration().imageMaxDistance,
            textToImage: RetrievalConfiguration().textToImageMaxDistance),
        supportsImages: true)
}
