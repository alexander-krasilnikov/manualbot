import Foundation
import Ports

/// What a catalog import did.
public struct CatalogImport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// Downloaded and queued for indexing.
        case imported
        /// Its document was already in the library, so nothing was downloaded.
        case alreadyInLibrary
    }

    public var documentID: String
    public var outcome: Outcome
    /// The download did not match the checksum recorded in the catalog: the publisher has replaced the file since.
    public var publisherUpdatedFile: Bool

    public init(documentID: String, outcome: Outcome, publisherUpdatedFile: Bool = false) {
        self.documentID = documentID
        self.outcome = outcome
        self.publisherUpdatedFile = publisherUpdatedFile
    }
}

/// Imports a catalog entry: the existing import, preceded by a download. The document gets the entry's identity, so the same
/// entry is one document on every iPad that shares the library, and the entry's origin, so the library can say where it
/// came from.
public struct CatalogImporter: Sendable {
    private let downloader: any ManualDownloading
    private let ingestion: IngestionService
    private let repository: any DocumentRepository

    public init(downloader: any ManualDownloading, ingestion: IngestionService, repository: any DocumentRepository) {
        self.downloader = downloader
        self.ingestion = ingestion
        self.repository = repository
    }

    /// Downloads the entry and queues it. A failure of any kind leaves no document and no temporary file behind.
    /// `progress` receives 0...1 while the file is downloaded.
    public func importEntry(_ entry: ManualCatalogEntry, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> CatalogImport {
        let documentID = entry.documentID
        if try await repository.document(id: documentID) != nil {
            return CatalogImport(documentID: documentID, outcome: .alreadyInLibrary)
        }
        let download = try await downloader.download(entry, progress: progress)
        defer { download.discard() }
        // A changed checksum is reported, never an error: publishers re-issue manuals under the same address.
        let updated = download.sha256.lowercased() != entry.sha256.lowercased()
        try await ingestion.enqueue(
            fileURL: download.fileURL, title: entry.title, id: documentID, origin: DocumentOrigin(entryId: entry.id, url: entry.url))
        return CatalogImport(documentID: documentID, outcome: .imported, publisherUpdatedFile: updated)
    }
}
