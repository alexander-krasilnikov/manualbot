import CoreML
import Foundation
import Ports

public enum EmbedderError: Error, LocalizedError, Equatable {
    case missingOutput
    case wrongDimensions(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .missingOutput: "The embedding model returned no embedding."
        case .wrongDimensions(let expected, let got): "The embedding model returned \(got) values where \(expected) were expected."
        }
    }
}

/// EmbeddingGemma 300M as a compiled Core ML model (INT8, fixed 256-token input, 768-dimensional output),
/// scheduled on the Neural Engine so the GPU stays free for the language model.
public actor CoreMLEmbedder: Embedder {
    public static let sequenceLength = 256
    private static let titleLimit = 60

    public nonisolated let identity: EmbeddingModelIdentity
    private let modelURL: URL
    private let tokenizer: GemmaTokenizer
    private let computeUnits: MLComputeUnits
    private var model: MLModel?

    public init(
        modelURL: URL, tokenizer: GemmaTokenizer, identity: EmbeddingModelIdentity,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine
    ) {
        self.modelURL = modelURL
        self.tokenizer = tokenizer
        self.identity = identity
        self.computeUnits = computeUnits
    }

    /// Frees the model's memory; it reloads on the next use.
    public func unload() { model = nil }

    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        let model = try loadedModel()
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            result.append(try encode(Self.prompt(for: text, kind: kind), with: model))
        }
        return result
    }

    // MARK: Prompt templates (from the model's `model_config.json`)

    static func prompt(for text: String, kind: EmbeddingKind) -> String {
        switch kind {
        case .query:
            return "task: search result | query: \(text)"
        case .passage(let title):
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return "title: \(clean.isEmpty ? "none" : String(clean.prefix(titleLimit))) | text: \(text)"
        }
    }

    // MARK: Inference

    private func loadedModel() throws -> MLModel {
        if let model { return model }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let loaded = try MLModel(contentsOf: modelURL, configuration: configuration)
        model = loaded
        return loaded
    }

    private func encode(_ prompt: String, with model: MLModel) throws -> [Float] {
        let length = Self.sequenceLength
        let ids = tokenizer.encode(prompt, limit: length)
        let inputIDs = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
        for i in 0..<length {
            inputIDs[i] = NSNumber(value: i < ids.count ? ids[i] : GemmaTokenizer.pad)
            mask[i] = NSNumber(value: i < ids.count ? 1.0 : 0.0)
        }
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["input_ids": inputIDs, "attention_mask": mask]))
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue else { throw EmbedderError.missingOutput }
        guard embedding.count == identity.dimensions else {
            throw EmbedderError.wrongDimensions(expected: identity.dimensions, got: embedding.count)
        }
        var vector = (0..<embedding.count).map { embedding[$0].floatValue }
        // The model emits half-precision values; renormalize so cosine distance is exact.
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { for i in vector.indices { vector[i] /= norm } }
        return vector
    }
}
