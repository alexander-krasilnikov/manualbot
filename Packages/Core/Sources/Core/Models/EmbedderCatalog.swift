import Foundation
import Ports

/// One embedding model the app can offer: the file to download, and the profile that says how to use it.
public struct EmbedderCatalogEntry: Sendable, Codable, Equatable, Identifiable {
    public var spec: ModelSpec
    public var profile: EmbedderProfile

    public var id: String { spec.id }

    public init(spec: ModelSpec, profile: EmbedderProfile) {
        self.spec = spec
        self.profile = profile
    }
}

public enum CatalogError: Error, Equatable {
    case duplicateModel(String)
    case notAnEmbedder(String)
    case invalidSize(String)
    case invalidChecksum(String)
    /// The profile does not describe the model it is listed with: another id or version, or an output size that
    /// is not the dimension it declares.
    case inconsistentProfile(String)
}

/// The embedding models the app can offer. It is compiled into the app and not fetched: each entry needs a profile
/// (prompts, chunk sizes, distances) that was settled by evaluating that model, which a download cannot carry.
public struct EmbedderCatalog: Sendable, Codable, Equatable {
    public var embedders: [EmbedderCatalogEntry]

    public static let empty = EmbedderCatalog(embedders: [])

    public init(embedders: [EmbedderCatalogEntry]) { self.embedders = embedders }

    public func entry(id: String) -> EmbedderCatalogEntry? { embedders.first { $0.id == id } }

    public static func decode(from data: Data) throws -> EmbedderCatalog {
        let catalog = try JSONDecoder().decode(EmbedderCatalog.self, from: data)
        var seen = Set<String>()
        for entry in catalog.embedders {
            let spec = entry.spec
            guard seen.insert(spec.id).inserted else { throw CatalogError.duplicateModel(spec.id) }
            guard spec.role == .embedder else { throw CatalogError.notAnEmbedder(spec.id) }
            guard spec.bytes > 0 else { throw CatalogError.invalidSize(spec.id) }
            guard spec.sha256.count == 64, spec.sha256.allSatisfy(\.isHexDigit) else { throw CatalogError.invalidChecksum(spec.id) }
            let profile = entry.profile
            guard profile.identity.id == spec.id, profile.identity.version == spec.version,
                  profile.outputSize == profile.identity.dimensions else { throw CatalogError.inconsistentProfile(spec.id) }
        }
        return catalog
    }
}
