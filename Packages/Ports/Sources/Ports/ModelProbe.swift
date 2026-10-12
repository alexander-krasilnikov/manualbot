import Foundation

/// What the first bytes of a model file say about the model, read without downloading the whole file.
public struct ModelHeader: Sendable, Equatable {
    public var kind: ModelDescription.Kind
    public var supportsImages: Bool
    /// The file format's version, for example "1.5.0".
    public var formatVersion: String?
    /// The oldest runtime that can run the model, when the header states it. No file seen so far does.
    public var minRuntimeVersion: String?

    public init(kind: ModelDescription.Kind, supportsImages: Bool = false, formatVersion: String? = nil, minRuntimeVersion: String? = nil) {
        self.kind = kind
        self.supportsImages = supportsImages
        self.formatVersion = formatVersion
        self.minRuntimeVersion = minRuntimeVersion
    }

    /// Not a LiteRT-LM file at all: the bytes do not start with its magic.
    public static let unknown = ModelHeader(kind: .unknown)

    /// Whether the bytes were those of a LiteRT-LM file (they named a format version), whatever the model inside is.
    public var isLiteRTLM: Bool { formatVersion != nil }
}

public protocol ModelHeaderProbing: Sendable {
    /// Reads the start of the file at `url`. Throws when the file cannot be reached.
    func probe(_ url: URL) async throws -> ModelHeader
}
