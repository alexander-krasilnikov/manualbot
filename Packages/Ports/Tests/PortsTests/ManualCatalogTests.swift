import Foundation
import Ports
import PortsTesting
import Testing

@Suite struct ManualCatalogTests {
    /// The catalog the app ships, found from this file's place in the repository.
    private var bundledCatalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Resources/ManualCatalog.json")
    }

    private func entryJSON(id: String = "a", url: String = "https://example.com/a.pdf", extra: String = "") -> String {
        """
        {"id":"\(id)","category":"Ships","kind":"manual","title":"A manual","publisher":"Acme","language":"en",
         "url":"\(url)","bytes":1000,"pages":10,"sha256":"\(String(repeating: "a", count: 64))",
         "licenceNote":"Free download","verifiedAt":"2026-10-13T09:59:44Z"\(extra)}
        """
    }

    private func catalogJSON(_ entries: [String], extra: String = "") -> Data {
        Data("{\"version\":1,\"entries\":[\(entries.joined(separator: ","))]\(extra)}".utf8)
    }

    @Test func decodesTheBundledCatalog() throws {
        let catalog = try ManualCatalog.decode(from: Data(contentsOf: bundledCatalogURL))
        #expect(catalog.entries.count >= 60)
        #expect(Set(catalog.categories) == ["Automotive", "Motorcycle", "Ships", "Yachts", "Manufacturing", "Wind turbines",
            "Field service", "Military", "Couchbase"])
        #expect(catalog.entries.allSatisfy { $0.url.scheme == "https" && $0.bytes <= 20 * 1_048_576 && $0.sha256.count == 64 })
    }

    @Test func bundledSamplesKeepTheirDocumentID() throws {
        let catalog = try ManualCatalog.decode(from: Data(contentsOf: bundledCatalogURL))
        let ids = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0.documentID) })
        #expect(ids.values.contains("sample-couchbase-under-the-hood"))
        #expect(ids.values.contains("sample-capella-architecture-overview"))
        for (id, documentID) in ids where !documentID.hasPrefix("sample-") { #expect(documentID == "catalog-\(id)") }
    }

    @Test func decodesAnEntryAndIgnoresUnknownFields() throws {
        let data = catalogJSON([entryJSON(extra: ",\"futureField\":{\"x\":1}")], extra: ",\"generatedBy\":\"later\"")
        let catalog = try ManualCatalog.decode(from: data)
        let entry = try #require(catalog.entries.first)
        #expect(entry.kind == .manual)
        #expect(entry.documentID == "catalog-a")
        #expect(entry.host == "example.com")
        #expect(entry.documentId == nil)
    }

    @Test func aDocumentIdOverridesTheDerivedOne() throws {
        let catalog = try ManualCatalog.decode(from: catalogJSON([entryJSON(extra: ",\"documentId\":\"sample-x\"")]))
        #expect(catalog.entries[0].documentID == "sample-x")
    }

    @Test func rejectsADuplicateIdOrAddressAndAnInsecureAddress() {
        #expect(throws: ManualCatalogError.duplicateEntry("a")) {
            try ManualCatalog.decode(from: catalogJSON([entryJSON(), entryJSON(url: "https://example.com/b.pdf")]))
        }
        #expect(throws: ManualCatalogError.duplicateAddress(URL(string: "https://example.com/a.pdf")!)) {
            try ManualCatalog.decode(from: catalogJSON([entryJSON(), entryJSON(id: "b")]))
        }
        #expect(throws: ManualCatalogError.insecureAddress("a")) {
            try ManualCatalog.decode(from: catalogJSON([entryJSON(url: "http://example.com/a.pdf")]))
        }
    }

    @Test func categoriesKeepTheFileOrder() throws {
        func entry(_ id: String, _ category: String) -> String {
            entryJSON(id: id, url: "https://example.com/\(id).pdf").replacingOccurrences(of: "\"Ships\"", with: "\"\(category)\"")
        }
        let catalog = try ManualCatalog.decode(from: catalogJSON([entry("a", "Yachts"), entry("b", "Ships"), entry("c", "Yachts")]))
        #expect(catalog.categories == ["Yachts", "Ships"])
    }

    @Test func aRecordWithoutAnOriginStillDecodes() throws {
        let json = #"{"id":"d","title":"Doc","type":"pdf","importedAt":0}"#
        let record = try JSONDecoder().decode(DocumentRecord.self, from: Data(json.utf8))
        #expect(record.origin == nil)
    }

    @Test func anOriginRoundTripsThroughTheRecord() throws {
        let origin = DocumentOrigin(entryId: "a", url: URL(string: "https://docs.nlr.gov/a.pdf")!)
        let record = DocumentRecord(id: "catalog-a", title: "A", type: .pdf, origin: origin)
        let decoded = try JSONDecoder().decode(DocumentRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.origin == origin)
        #expect(decoded.origin?.host == "docs.nlr.gov")
    }

    @Test func theInMemoryRepositoryKeepsTheOrigin() async throws {
        let repo = InMemoryDocumentRepository()
        let origin = DocumentOrigin(entryId: "a", url: URL(string: "https://example.com/a.pdf")!)
        try await repo.upsert(DocumentRecord(id: "catalog-a", title: "A", type: .pdf, origin: origin))
        #expect(try await repo.document(id: "catalog-a")?.origin == origin)
    }

    @Test func theFakeDownloaderWritesAFileAndFailsAsTold() async throws {
        let entry = ManualCatalogEntry(
            id: "a", category: "Ships", kind: .manual, title: "A", publisher: "Acme",
            url: URL(string: "https://example.com/a.pdf")!, bytes: 100, pages: 1, sha256: String(repeating: "b", count: 64),
            licenceNote: "Free")
        let fake = FakeManualDownloader()
        let download = try await fake.download(entry, progress: { _ in })
        #expect(download.fileURL.lastPathComponent == "a.pdf")
        #expect(FileManager.default.fileExists(atPath: download.fileURL.path))
        #expect(download.sha256 == entry.sha256)
        try? FileManager.default.removeItem(at: download.fileURL.deletingLastPathComponent())

        fake.setBehavior(.fail(.blocked), for: "a")
        await #expect(throws: ManualDownloadError.blocked) { try await fake.download(entry, progress: { _ in }) }
        #expect(fake.downloads == ["a", "a"])
    }
}
