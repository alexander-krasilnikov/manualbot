import Foundation

/// What a model file says about itself, as read by the runtime.
public struct ModelDescription: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case llm, embedder, unknown
    }

    public var kind: Kind
    public var supportsImages: Bool
    /// The oldest LiteRT-LM runtime that can run the model, when the file states it.
    public var minRuntimeVersion: String?
    /// The largest context the language model supports.
    public var maxContextTokens: Int?
    /// The output size of an embedding model.
    public var embeddingDimension: Int?
    /// The text input lengths, in tokens, an embedding model supports.
    public var embeddingInputLengths: [Int]?

    public init(
        kind: Kind, supportsImages: Bool = false, minRuntimeVersion: String? = nil,
        maxContextTokens: Int? = nil, embeddingDimension: Int? = nil, embeddingInputLengths: [Int]? = nil
    ) {
        self.embeddingInputLengths = embeddingInputLengths
        self.kind = kind
        self.supportsImages = supportsImages
        self.minRuntimeVersion = minRuntimeVersion
        self.maxContextTokens = maxContextTokens
        self.embeddingDimension = embeddingDimension
    }
}

/// Why a downloaded model file cannot be used. The messages are shown to the user.
public enum ModelValidationError: Error, LocalizedError, Equatable {
    case notALanguageModel
    case notAnEmbeddingModel
    case needsNewerRuntime
    case contextTooSmall
    case wrongDimension(expected: Int, found: Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .notALanguageModel: "Not a language model."
        case .notAnEmbeddingModel: "Not an embedding model."
        case .needsNewerRuntime: "Needs a newer version of the app."
        case .contextTooSmall: "Context too small for answers."
        case .wrongDimension(let expected, let found): "The model returns \(found) values where the app expects \(expected)."
        case .unreadable: "The file could not be read as a model."
        }
    }
}

/// Checks a downloaded model file before it is installed.
public protocol ModelValidating: Sendable {
    /// Reads the file and throws a `ModelValidationError` when the app cannot use it for the spec's role.
    @discardableResult
    func validate(_ file: URL, for spec: ModelSpec) throws -> ModelDescription
}
