import Foundation

/// What a catalog entry is: a manual, a product catalog or a whitepaper.
public enum ManualKind: String, Sendable, Codable, CaseIterable {
    case manual, catalog, whitepaper
}

/// One curated public PDF the user can import. The entry records what the PDF was when the catalog was prepared.
public struct ManualCatalogEntry: Sendable, Codable, Hashable, Identifiable {
    /// A stable slug, kept across catalog releases.
    public var id: String
    public var category: String
    public var kind: ManualKind
    public var title: String
    public var publisher: String
    public var language: String
    /// The publisher's own address for the PDF. HTTPS only.
    public var url: URL
    public var bytes: Int64
    public var pages: Int
    /// SHA-256 of the file as last verified, lowercase hex.
    public var sha256: String
    /// The licence as the publisher states it, such as "US government work, public domain".
    public var licenceNote: String
    public var verifiedAt: Date
    /// Set when the PDF is also a bundled sample, so that both are one document in the library.
    public var documentId: String?

    /// The library document this entry becomes: the sample's id when it is one, else one derived from the entry.
    public var documentID: String { documentId ?? "catalog-\(id)" }

    /// The publisher's host, named to the user before a first download.
    public var host: String { url.host ?? url.absoluteString }

    public init(
        id: String, category: String, kind: ManualKind, title: String, publisher: String, language: String = "en",
        url: URL, bytes: Int64, pages: Int, sha256: String, licenceNote: String, verifiedAt: Date = Date(),
        documentId: String? = nil
    ) {
        self.id = id
        self.category = category
        self.kind = kind
        self.title = title
        self.publisher = publisher
        self.language = language
        self.url = url
        self.bytes = bytes
        self.pages = pages
        self.sha256 = sha256
        self.licenceNote = licenceNote
        self.verifiedAt = verifiedAt
        self.documentId = documentId
    }
}

/// The curated list that ships with the app. It holds addresses and details, never the PDFs.
public struct ManualCatalog: Sendable, Codable, Equatable {
    public var version: Int
    public var entries: [ManualCatalogEntry]

    public init(version: Int = 1, entries: [ManualCatalogEntry]) {
        self.version = version
        self.entries = entries
    }

    /// Categories in the order they first appear, which is the order the file lists them in.
    public var categories: [String] {
        var seen = Set<String>()
        return entries.map(\.category).filter { seen.insert($0).inserted }
    }

    public func entry(id: String) -> ManualCatalogEntry? { entries.first { $0.id == id } }

    public static func decode(from data: Data) throws -> ManualCatalog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalog = try decoder.decode(ManualCatalog.self, from: data)
        var ids = Set<String>(), urls = Set<URL>()
        for entry in catalog.entries {
            guard ids.insert(entry.id).inserted else { throw ManualCatalogError.duplicateEntry(entry.id) }
            guard urls.insert(entry.url).inserted else { throw ManualCatalogError.duplicateAddress(entry.url) }
            guard entry.url.scheme?.lowercased() == "https" else { throw ManualCatalogError.insecureAddress(entry.id) }
            guard entry.bytes > 0 else { throw ManualCatalogError.invalidSize(entry.id) }
        }
        return catalog
    }
}

public enum ManualCatalogError: Error, Equatable {
    case duplicateEntry(String)
    case duplicateAddress(URL)
    case insecureAddress(String)
    case invalidSize(String)
}
