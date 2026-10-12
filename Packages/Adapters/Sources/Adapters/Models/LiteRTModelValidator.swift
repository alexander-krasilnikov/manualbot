import Core
import Foundation
import LiteRTLM
import Ports

/// Judges a downloaded `.litertlm` file with the bundled LiteRT-LM runtime, which is the final word on whether the
/// file can run (design D4). The runtime reads the file's own description: its type, the oldest runtime it needs,
/// and its context or embedding size.
public struct LiteRTModelValidator: ModelValidating {
    /// The LiteRT-LM runtime this build contains. A file that needs a newer one is rejected.
    public static let bundledRuntimeVersion = "0.18.0"

    /// The context the language model must support: the app's answers need this many tokens.
    public let requiredContextTokens: Int
    /// The embedding models the app has tested. One of them must be able to produce the vector size its profile asks for; any
    /// other embedding model only has to report a vector size, for the generic settings are built from it.
    public let catalog: EmbedderCatalog
    public let runtimeVersion: String

    public init(requiredContextTokens: Int, catalog: EmbedderCatalog = .empty, runtimeVersion: String = bundledRuntimeVersion) {
        self.requiredContextTokens = requiredContextTokens
        self.catalog = catalog
        self.runtimeVersion = runtimeVersion
    }

    @discardableResult
    public func validate(_ file: URL, for spec: ModelSpec) throws -> ModelDescription {
        guard let info = ModelInfo(modelPath: file.path) else { throw ModelValidationError.unreadable }
        let description = ModelDescription(
            kind: info.isLlmModel() ? .llm : info.isEmbeddingModel() ? .embedder : .unknown,
            supportsImages: info.inputModalities.vision,
            minRuntimeVersion: info.minRuntimeVersion,
            maxContextTokens: info.isLlmModel() ? info.maxContextTokens() : nil,
            embeddingDimension: info.isEmbeddingModel() ? info.embedding?.dimension() : nil,
            embeddingInputLengths: info.isEmbeddingModel() ? info.embedding?.signatureSelection() : nil)

        switch spec.role {
        case .generator:
            guard info.isLlmModel() else { throw ModelValidationError.notALanguageModel }
            guard description.maxContextTokens ?? 0 >= requiredContextTokens else { throw ModelValidationError.contextTooSmall }
        case .embedder:
            guard info.isEmbeddingModel() else { throw ModelValidationError.notAnEmbeddingModel }
            // The file's dimension is its largest output; a tested model's profile may ask for a smaller one (truncated output).
            let native = description.embeddingDimension ?? 0
            let asked = catalog.entry(id: spec.id)?.profile.outputSize
            guard native > 0, asked.map({ $0 <= native }) ?? true else {
                throw ModelValidationError.wrongDimension(expected: asked ?? 1, found: native)
            }
        }
        if let required = description.minRuntimeVersion, RuntimeVersion.isNewer(required, than: runtimeVersion) {
            throw ModelValidationError.needsNewerRuntime
        }
        return description
    }
}
