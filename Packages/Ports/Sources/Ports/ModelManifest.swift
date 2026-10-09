import Foundation

public enum ModelRole: String, Sendable, Codable, Comparable, CaseIterable {
    case embedder, generator

    /// The embedder is installed first so that documents can be indexed while the larger model downloads.
    private var order: Int { self == .embedder ? 0 : 1 }
    public static func < (a: ModelRole, b: ModelRole) -> Bool { a.order < b.order }
}

public enum ModelPackaging: String, Sendable, Codable {
    /// One file, stored under `fileName`.
    case file
    /// A zip archive that is verified and then unpacked; `fileName` is the entry to load (a file or directory) inside it.
    case zip
}

public struct ModelSpec: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var version: String
    public var role: ModelRole
    public var url: URL
    public var bytes: Int64
    public var sha256: String
    /// File name the model is stored under inside its version directory.
    public var fileName: String
    /// Name shown to the user; falls back to `id`.
    public var displayName: String?
    public var packaging: ModelPackaging
    /// Licence as stated by the model's publisher, shown on the About screen.
    public var licence: String?
    /// The repository the file came from, for a link on the About screen.
    public var repository: URL?

    public var title: String { displayName ?? id }

    public init(
        id: String, version: String, role: ModelRole, url: URL, bytes: Int64, sha256: String, fileName: String,
        displayName: String? = nil, packaging: ModelPackaging = .file, licence: String? = nil, repository: URL? = nil
    ) {
        self.packaging = packaging
        self.id = id
        self.version = version
        self.role = role
        self.url = url
        self.bytes = bytes
        self.sha256 = sha256
        self.fileName = fileName
        self.displayName = displayName
        self.licence = licence
        self.repository = repository
    }

    enum CodingKeys: String, CodingKey {
        case id, version, role, url, bytes, sha256, fileName, displayName, packaging, licence, repository
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = try c.decode(String.self, forKey: .version)
        role = try c.decode(ModelRole.self, forKey: .role)
        url = try c.decode(URL.self, forKey: .url)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        sha256 = try c.decode(String.self, forKey: .sha256)
        fileName = try c.decode(String.self, forKey: .fileName)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        packaging = try c.decodeIfPresent(ModelPackaging.self, forKey: .packaging) ?? .file
        licence = try c.decodeIfPresent(String.self, forKey: .licence)
        repository = try c.decodeIfPresent(URL.self, forKey: .repository)
    }
}

/// How a model came to be installed.
public enum ModelSource: String, Sendable, Codable {
    /// Listed in the built-in manifest: the first-run defaults.
    case manifest
    /// Chosen from the embedder catalog that ships with the app.
    case catalog
    /// Found by searching the model repositories.
    case search
}

/// What the runtime read from an embedding model's file once it was downloaded: all the app knows about a model that is not
/// in its built-in list, so all it has to build generic settings from.
public struct EmbeddingDescription: Sendable, Codable, Hashable {
    /// The vector size the file reports: its largest output.
    public var dimension: Int
    /// Whether the model also embeds photos.
    public var supportsImages: Bool
    /// The text input length, in tokens, to ask the engine for.
    public var maxInputLength: Int

    public init(dimension: Int, supportsImages: Bool, maxInputLength: Int) {
        self.dimension = dimension
        self.supportsImages = supportsImages
        self.maxInputLength = maxInputLength
    }

    /// The longest input length up to 512 tokens that the file supports (longer ones are slower and no use to chunks of a
    /// few hundred words), else its shortest. 512 when the file does not say.
    public static func inputLength(from supported: [Int]?) -> Int {
        guard let supported = supported?.filter({ $0 > 0 }), !supported.isEmpty else { return 512 }
        return supported.filter { $0 <= 512 }.max() ?? supported.min()!
    }
}

/// What the app knows about an installed model, written next to its file as `model.json`.
public struct ModelRecord: Sendable, Codable, Hashable {
    public var spec: ModelSpec
    public var source: ModelSource
    /// The user installed or activated this model on the Models page. Such a model stays installed until the user
    /// deletes it, even after an update changes the default for its role.
    public var chosenByUser: Bool
    /// For an embedding model: what the runtime read from its file when it was installed.
    public var embedding: EmbeddingDescription?

    public init(spec: ModelSpec, source: ModelSource, chosenByUser: Bool, embedding: EmbeddingDescription? = nil) {
        self.spec = spec
        self.source = source
        self.chosenByUser = chosenByUser
        self.embedding = embedding
    }
}

/// The model each role uses. `nil` means the built-in default for that role.
public struct ActiveModels: Sendable, Codable, Equatable {
    public var embedder: String?
    public var generator: String?

    public init(embedder: String? = nil, generator: String? = nil) {
        self.embedder = embedder
        self.generator = generator
    }

    public func id(for role: ModelRole) -> String? { role == .embedder ? embedder : generator }

    public mutating func set(_ id: String?, for role: ModelRole) {
        switch role {
        case .embedder: embedder = id
        case .generator: generator = id
        }
    }
}

/// The models the app is allowed to download and load by default. Compiled into the app.
public struct ModelManifest: Sendable, Codable, Equatable {
    public var models: [ModelSpec]

    public init(models: [ModelSpec]) { self.models = models }

    public static func decode(from data: Data) throws -> ModelManifest {
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        var seen = Set<String>()
        for model in manifest.models {
            guard seen.insert(model.id).inserted else { throw ManifestError.duplicateModel(model.id) }
            guard model.bytes > 0 else { throw ManifestError.invalidSize(model.id) }
            guard model.sha256.count == 64, model.sha256.allSatisfy(\.isHexDigit) else {
                throw ManifestError.invalidChecksum(model.id)
            }
        }
        for role in ModelRole.allCases where !manifest.models.contains(where: { $0.role == role }) {
            throw ManifestError.missingRole(role)
        }
        return manifest
    }

    public func spec(id: String) -> ModelSpec? { models.first { $0.id == id } }
    public var totalBytes: Int64 { models.reduce(0) { $0 + $1.bytes } }
}

public enum ManifestError: Error, Equatable {
    case duplicateModel(String)
    case invalidSize(String)
    case invalidChecksum(String)
    case missingRole(ModelRole)
}

public enum ModelState: Sendable, Equatable {
    case missing
    case downloading(fraction: Double)
    case verifying
    case installed
    case failed(String)
}
