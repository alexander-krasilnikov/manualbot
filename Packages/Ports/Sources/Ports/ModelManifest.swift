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

    public var title: String { displayName ?? id }

    public init(
        id: String, version: String, role: ModelRole, url: URL, bytes: Int64, sha256: String, fileName: String,
        displayName: String? = nil, packaging: ModelPackaging = .file
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
    }

    enum CodingKeys: String, CodingKey { case id, version, role, url, bytes, sha256, fileName, displayName, packaging }

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
    }
}

/// The models the app is allowed to download and load. Compiled into the app.
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
