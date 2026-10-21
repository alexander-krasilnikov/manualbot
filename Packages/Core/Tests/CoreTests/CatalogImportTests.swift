import Foundation
import Ports
import PortsTesting
import Synchronization
import Testing
@testable import Core

/// A catalog import is the existing import preceded by a download (manual-catalog and document-ingestion specs).
@Suite struct CatalogImportTests {
    private let chunker = Chunker(configuration: ChunkerConfiguration(targetTokens: 40, maxTokens: 70, overlapTokens: 10, minTailTokens: 15))

    private func entry(_ id: String = "nrel-wind", documentId: String? = nil) -> ManualCatalogEntry {
        ManualCatalogEntry(
            id: id, category: "Wind turbines", kind: .manual, title: "Wind Plant Operations", publisher: "NREL",
            url: URL(string: "https://docs.nlr.gov/docs/\(id).pdf")!, bytes: 1000, pages: 20,
            sha256: String(repeating: "a", count: 64), licenceNote: "US government work", documentId: documentId)
    }

    private func text() -> ExtractedDocument {
        ExtractedDocument(
            blocks: [Block(text: (0..<10).map { "K\($0) " + (0..<8).map { "w\($0)" }.joined(separator: " ") + "." }.joined(separator: " "), page: 1)],
            pageCount: 1)
    }

    private struct Rig {
        let repo = InMemoryDocumentRepository()
        let downloader = FakeManualDownloader()
        let ingestion: IngestionService
        let importer: CatalogImporter

        init(chunker: Chunker, results: [String: Result<ExtractedDocument, Error>]) {
            ingestion = IngestionService(
                extractor: FakeExtractor(results: results), embedder: FakeEmbedder(), repository: repo, jobs: repo, chunker: chunker,
                batchSize: 4, supportedType: { ["pdf": DocumentType.pdf][$0.pathExtension.lowercased()] })
            importer = CatalogImporter(downloader: downloader, ingestion: ingestion, repository: repo)
        }
    }

    private func rig(_ ids: String...) -> Rig {
        Rig(chunker: chunker, results: Dictionary(uniqueKeysWithValues: ids.map { ("\($0).pdf", .success(text())) }))
    }

    private func noTemporaryFileLeft(_ rig: Rig) -> Bool {
        rig.downloader.writtenFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test func anImportStoresTheOriginAndTheEntrysTitleAndIdentity() async throws {
        let rig = rig("nrel-wind")
        let result = try await rig.importer.importEntry(entry())
        #expect(result == CatalogImport(documentID: "catalog-nrel-wind", outcome: .imported))
        let document = try #require(try await rig.repo.document(id: "catalog-nrel-wind"))
        #expect(document.title == "Wind Plant Operations")
        #expect(document.origin == DocumentOrigin(entryId: "nrel-wind", url: URL(string: "https://docs.nlr.gov/docs/nrel-wind.pdf")!))
        #expect(try await rig.repo.job(docId: "catalog-nrel-wind")?.state == .queued)
        #expect(try await rig.repo.originalFileURL(docId: "catalog-nrel-wind") != nil, "the original is kept with the record")
        #expect(noTemporaryFileLeft(rig), "the temporary file is removed after the hand-off")
    }

    @Test func aSampleEntryBecomesTheBundledSample() async throws {
        let rig = rig("couchbase-hood")
        try await rig.importer.importEntry(entry("couchbase-hood", documentId: "sample-couchbase-under-the-hood"))
        #expect(try await rig.repo.documents().map(\.id) == ["sample-couchbase-under-the-hood"])
    }

    @Test func aSecondImportOfTheSameEntryDownloadsAndChangesNothing() async throws {
        let rig = rig("nrel-wind")
        try await rig.importer.importEntry(entry())
        await rig.ingestion.run()
        let before = try await rig.repo.document(id: "catalog-nrel-wind")

        let again = try await rig.importer.importEntry(entry())
        #expect(again.outcome == .alreadyInLibrary)
        #expect(rig.downloader.downloads == ["nrel-wind"], "no second download")
        #expect(try await rig.repo.document(id: "catalog-nrel-wind") == before)
        #expect(try await rig.repo.documents().count == 1)
    }

    @Test func aDocumentThatArrivedFromAnotherDeviceIsNotDownloadedAgain() async throws {
        let rig = rig("nrel-wind")
        await rig.repo.upsert(DocumentRecord(id: "catalog-nrel-wind", title: "Wind", type: .pdf, activeGeneration: 1, chunkCount: 3, activeImageCount: 0))
        let result = try await rig.importer.importEntry(entry())
        #expect(result.outcome == .alreadyInLibrary)
        #expect(rig.downloader.downloads.isEmpty)
    }

    @Test func aChangedChecksumIsReportedNotRefused() async throws {
        let rig = rig("nrel-wind")
        rig.downloader.setBehavior(.updated, for: "nrel-wind")
        let result = try await rig.importer.importEntry(entry())
        #expect(result.outcome == .imported && result.publisherUpdatedFile)
        #expect(try await rig.repo.document(id: "catalog-nrel-wind") != nil)
    }

    @Test func aMatchingChecksumIsNotReported() async throws {
        let rig = rig("nrel-wind")
        #expect(try await rig.importer.importEntry(entry()).publisherUpdatedFile == false)
    }

    @Test(arguments: [
        ManualDownloadError.offline, .blocked, .gone, .notPDF, .tooLarge(bytes: 30_000_000), .http(503), .connectionLost,
    ])
    func eachDownloadFailureLeavesNoDocumentAndNoFile(_ failure: ManualDownloadError) async throws {
        let rig = rig("nrel-wind")
        rig.downloader.setBehavior(.fail(failure), for: "nrel-wind")
        await #expect(throws: failure) { try await rig.importer.importEntry(entry()) }
        #expect(try await rig.repo.documents().isEmpty)
        #expect(try await rig.repo.jobs().isEmpty)
        #expect(noTemporaryFileLeft(rig))
    }

    @Test func aFailureAfterProgressLeavesNothingEither() async throws {
        let rig = rig("nrel-wind")
        rig.downloader.setBehavior(.failAfterProgress(.connectionLost), for: "nrel-wind")
        let seen = Mutex<[Double]>([])
        await #expect(throws: ManualDownloadError.connectionLost) {
            try await rig.importer.importEntry(entry()) { fraction in seen.withLock { $0.append(fraction) } }
        }
        #expect(seen.withLock { $0 } == [0.25, 0.5])
        #expect(try await rig.repo.documents().isEmpty)
    }

    @Test func aFileTheImportRefusesLeavesNoDocumentAndNoFile() async throws {
        // The download is fine but the file is not a supported document: nothing is stored, and the file is still removed.
        let rig = Rig(chunker: chunker, results: [:])
        let docx = ManualCatalogEntry(
            id: "odd", category: "Ships", kind: .manual, title: "Odd", publisher: "P", url: URL(string: "https://example.com/odd")!,
            bytes: 10, pages: 1, sha256: String(repeating: "a", count: 64), licenceNote: "x")
        let service = IngestionService(
            extractor: FakeExtractor(results: [:]), embedder: FakeEmbedder(), repository: rig.repo, jobs: rig.repo,
            chunker: chunker, supportedType: { _ in nil })
        let importer = CatalogImporter(downloader: rig.downloader, ingestion: service, repository: rig.repo)
        await #expect(throws: IngestionError.self) { try await importer.importEntry(docx) }
        #expect(try await rig.repo.documents().isEmpty)
        #expect(noTemporaryFileLeft(rig))
    }

    @Test func cancellingStopsTheDownloadAndLeavesNothing() async throws {
        let rig = rig("nrel-wind")
        rig.downloader.setBehavior(.suspend, for: "nrel-wind")
        let task = Task { try await rig.importer.importEntry(entry()) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(rig.downloader.cancelled == ["nrel-wind"])
        #expect(try await rig.repo.documents().isEmpty)
    }

    @Test func theOriginSurvivesAReindex() async throws {
        let rig = rig("nrel-wind")
        try await rig.importer.importEntry(entry())
        await rig.ingestion.run()
        try await rig.ingestion.reindex(docId: "catalog-nrel-wind")
        await rig.ingestion.run()

        let document = try #require(try await rig.repo.document(id: "catalog-nrel-wind"))
        #expect(document.activeGeneration == 2)
        #expect(document.origin?.entryId == "nrel-wind")
    }
}
