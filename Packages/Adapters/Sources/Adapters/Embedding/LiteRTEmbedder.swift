import CoreGraphics
import Foundation
import ImageIO
import LiteRTLM
import Core
import Ports
import UniformTypeIdentifiers

public enum LiteRTEmbedderError: Error, LocalizedError, Equatable {
    case modelMissing(String)
    case wrongDimensions(expected: Int, got: Int)
    case imageEncodingFailed
    case emptyInput

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let path): "The embedding model file was not found at \(path)."
        case .wrongDimensions(let expected, let got): "The embedding model returned \(got) values where \(expected) were expected."
        case .imageEncodingFailed: "The image could not be prepared for analysis."
        case .emptyInput: "There is nothing to embed."
        }
    }
}

/// An embedding model through LiteRT-LM: one model, one vector space for chunks, questions and photos. Everything that is
/// specific to the model (its identity, prompt templates, input limit and output size) comes from its `EmbedderProfile`.
///
/// The same type is the `Embedder` and the `ImageFeaturing`, with one identity, so the model-tag checks that keep
/// vectors from different models apart cannot let text and photo vectors drift. For EmbeddingGemma 2 it was settled by
/// the spike (`EmbeddingGemma2SpikeTests`): 256-dimension unit vectors, documented prompt templates, a photo embedded
/// alone, GPU on devices and Mac and CPU in the simulator.
///
/// The engine loads on first use and is released by `unload()`. Calls reach the engine's own actor one at a time,
/// so a batch never runs concurrently with another and at most one thread is blocked in native code.
public actor LiteRTEmbedder: Embedder, ImageFeaturing {
    /// Chunks per native call. A batch is not interruptible, so this bounds how long a cancel can wait.
    static let batchSize = 8
    /// Photos larger than this (longest side, in pixels) are scaled down before encoding. The model resizes them itself.
    private static let maxImageSide = 1024

    public nonisolated let profile: EmbedderProfile
    public nonisolated var identity: EmbeddingModelIdentity { profile.identity }
    private let modelPath: String
    private let cacheDirectory: String
    private let backend: GeneratorBackend
    private var engine: EmbeddingEngine?

    public init(
        profile: EmbedderProfile, modelPath: String, cacheDirectory: String = NSTemporaryDirectory(),
        backend: GeneratorBackend = .platformDefault
    ) {
        self.profile = profile
        self.modelPath = modelPath
        self.cacheDirectory = cacheDirectory
        self.backend = backend
    }

    /// Frees the model's memory; it reloads on the next use.
    public func unload() async {
        let engine = engine
        self.engine = nil
        await engine?.close()
    }

    // MARK: Embedder

    public func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let engine = try await loadedEngine()
        let prompts = texts.map { profile.prompt(for: $0, kind: kind) }
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        for start in stride(from: 0, to: prompts.count, by: Self.batchSize) {
            try Task.checkCancellation()
            result += try await embedBatch(Array(prompts[start..<min(start + Self.batchSize, prompts.count)]), on: engine)
        }
        return result
    }

    // MARK: ImageFeaturing

    public func features(of image: CGImage) async throws -> [Float] {
        let data = try Self.encoded(image)
        let engine = try await loadedEngine()
        try Task.checkCancellation()
        let response = try await engine.computeEmbedding(contents: [.imageData(data)], options: options)
        return try checked(response.embedding)
    }

    // MARK: Inference

    private var options: EmbeddingOptions { EmbeddingOptions(normalize: true, outputSize: profile.outputSize) }

    private func loadedEngine() async throws -> EmbeddingEngine {
        if let engine { return engine }
        guard FileManager.default.fileExists(atPath: modelPath) else { throw LiteRTEmbedderError.modelMissing(modelPath) }
        let engineBackend: Backend = backend == .gpu ? .gpu : .cpu()
        // A model without photos has no vision encoder: asking the engine for one makes it fail to load.
        let created = EmbeddingEngine(config: EmbeddingEngineConfig(
            modelPath: modelPath, backend: engineBackend, visionBackend: profile.supportsImages ? engineBackend : nil,
            cacheDir: cacheDirectory, maxInputLength: profile.maxInputLength))
        try await created.initialize()
        // Another call may have loaded it while this one was waiting; keep one.
        if let engine {
            await created.close()
            return engine
        }
        engine = created
        return created
    }

    private func embedBatch(_ prompts: [String], on engine: EmbeddingEngine) async throws -> [[Float]] {
        do {
            let responses = try await engine.computeEmbeddingBatch(contentsBatch: prompts.map { [.text($0)] }, options: options)
            guard responses.count == prompts.count else { throw LiteRTEmbedderError.wrongDimensions(expected: prompts.count, got: responses.count) }
            return try responses.map { try checked($0.embedding) }
        } catch where Self.isTooLong(error) {
            // One chunk in the batch is longer than the input limit, which the engine reports instead of
            // truncating. Embed each on its own, shrinking only the ones that do not fit.
            var result: [[Float]] = []
            for prompt in prompts {
                try Task.checkCancellation()
                result.append(try await embedShrinking(prompt, on: engine))
            }
            return result
        }
    }

    /// Embeds `prompt`, cutting its words down by a fifth each time the engine says it is too long. Identifier-heavy
    /// text can use several times as many tokens as its length suggests, so no estimate is safe for every chunk.
    private func embedShrinking(_ prompt: String, on engine: EmbeddingEngine) async throws -> [Float] {
        var text = prompt
        while true {
            do {
                let response = try await engine.computeEmbedding(contents: [.text(text)], options: options)
                return try checked(response.embedding)
            } catch where Self.isTooLong(error) {
                guard let shorter = Self.shrunk(text) else { throw LiteRTEmbedderError.emptyInput }
                text = shorter
            }
        }
    }

    private func checked(_ vector: [Float]) throws -> [Float] {
        guard vector.count == identity.dimensions else {
            throw LiteRTEmbedderError.wrongDimensions(expected: identity.dimensions, got: vector.count)
        }
        return vector
    }

    // MARK: Helpers

    static func isTooLong(_ error: Error) -> Bool {
        String(describing: error).contains("exceeds maximum supported signature length")
    }

    /// The first four fifths of the words (or characters, for text without spaces), or nil when nothing is left.
    static func shrunk(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count > 1 { return words.prefix(max(1, words.count * 4 / 5)).joined(separator: " ") }
        let characters = text.count
        guard characters > 1 else { return nil }
        return String(text.prefix(max(1, characters * 4 / 5)))
    }

    /// JPEG bytes, scaled down when very large. The engine decodes and resizes the image itself.
    static func encoded(_ image: CGImage) throws -> Data {
        var source = image
        let longest = max(image.width, image.height)
        if longest > maxImageSide {
            let scale = Double(maxImageSide) / Double(longest)
            let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw LiteRTEmbedderError.imageEncodingFailed }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { throw LiteRTEmbedderError.imageEncodingFailed }
            source = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LiteRTEmbedderError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, source, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LiteRTEmbedderError.imageEncodingFailed }
        return data as Data
    }
}
