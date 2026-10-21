import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

/// The manual catalog's view model, against the real library view model, importer and ingestion over in-memory stand-ins.
@MainActor @Suite struct CatalogViewModelTests {
    @MainActor private struct Rig {
        let repo = InMemoryDocumentRepository()
        let downloader = FakeManualDownloader()
        let library: LibraryViewModel
        let ingestion: IngestionService
        let network = NetworkMonitor()
        let defaults: UserDefaults
        let suite: String
        let catalog: ManualCatalog
        let model: CatalogViewModel

        init(entries: [ManualCatalogEntry], defaults suite: String? = nil, maxConcurrent: Int = 2) {
            let page = ExtractedDocument(blocks: [Block(text: "Check the oil level before every start. " + String(repeating: "More text. ", count: 20), page: 1)], pageCount: 1)
            let extractor = FakeExtractor(results: Dictionary(uniqueKeysWithValues: entries.map { ("\($0.id).pdf", .success(page)) }))
            ingestion = IngestionService(
                extractor: extractor, embedder: FakeEmbedder(), repository: repo, jobs: repo,
                supportedType: { $0.pathExtension.lowercased() == "pdf" ? .pdf : nil })
            library = LibraryViewModel(documents: repo, jobs: repo, ingestion: ingestion)
            self.suite = suite ?? "catalog-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: self.suite)!
            catalog = ManualCatalog(entries: entries)
            model = CatalogViewModel(
                catalog: catalog, library: library,
                importer: CatalogImporter(downloader: downloader, ingestion: ingestion, repository: repo),
                network: network, defaults: defaults, maxConcurrent: maxConcurrent)
            // Hosts already accepted, unless a test is about the notice.
            defaults.set(Array(Set(entries.map(\.host))), forKey: "manualCatalog.acknowledgedHosts")
            model.reloadAcknowledgedHosts()
        }

        /// A new view model over the same defaults, as after a relaunch.
        func relaunched() -> CatalogViewModel {
            CatalogViewModel(
                catalog: catalog, library: library,
                importer: CatalogImporter(downloader: downloader, ingestion: ingestion, repository: repo),
                network: network, defaults: defaults)
        }

        func clearAcknowledgedHosts() {
            defaults.removeObject(forKey: "manualCatalog.acknowledgedHosts")
            model.reloadAcknowledgedHosts()
        }

        func state(_ id: String) -> CatalogViewModel.EntryState { model.state(of: catalog.entry(id: id)!) }

        func waitUntilReady(_ id: String) async -> Bool {
            await eventually { await library.refresh(); return library.items.first { $0.id == "catalog-\(id)" }?.status == .ready }
        }
    }

    private static func entry(
        _ id: String, _ category: String = "Ships", _ kind: ManualKind = .manual, title: String? = nil, publisher: String = "Acme Marine",
        host: String = "example.com"
    ) -> ManualCatalogEntry {
        ManualCatalogEntry(
            id: id, category: category, kind: kind, title: title ?? "Manual \(id)", publisher: publisher,
            url: URL(string: "https://\(host)/\(id).pdf")!, bytes: 3_000_000, pages: 40, sha256: String(repeating: "a", count: 64),
            licenceNote: "Free download")
    }

    private static let sample: [ManualCatalogEntry] = [
        entry("outboard-guide", "Yachts", .manual, title: "Outboard owner’s manual", publisher: "Tohatsu"),
        entry("engine-catalog", "Yachts", .catalog, title: "Marine engines", publisher: "Yanmar"),
        entry("hull-guide", "Ships", .manual, title: "Hull maintenance", publisher: "Navy Training"),
        entry("whitepaper-a", "Couchbase", .whitepaper, title: "Architecture", publisher: "Couchbase, Inc."),
        entry("sail-catalog", "Yachts", .catalog, title: "Sails 2026", publisher: "North Sails"),
    ]

    // MARK: The bundled list

    @Test func theBundledCatalogLoadsAndGroupsIntoTheNineCategories() throws {
        let catalog = try AppEnvironment.manualCatalog()
        #expect(catalog.categories == [
            "Automotive", "Motorcycle", "Ships", "Yachts", "Manufacturing", "Wind turbines", "Field service", "Military", "Couchbase",
        ])
        #expect(catalog.entries.count >= 60)
        #expect(catalog.entries.allSatisfy { $0.url.scheme == "https" })
    }

    // MARK: Finding entries

    @Test func searchMatchesTitlePublisherAndCategoryAndNothingElse() {
        let rig = Rig(entries: Self.sample)
        rig.model.searchText = "outboard"
        #expect(rig.model.filteredEntries.map(\.id) == ["outboard-guide"])
        rig.model.searchText = "yanmar"
        #expect(rig.model.filteredEntries.map(\.id) == ["engine-catalog"])
        rig.model.searchText = "couchbase"   // the category and the publisher
        #expect(rig.model.filteredEntries.map(\.id) == ["whitepaper-a"])
        rig.model.searchText = "example.com"   // the address is not searched
        #expect(rig.model.filteredEntries.isEmpty)
        rig.model.searchText = "  sails   north "
        #expect(rig.model.filteredEntries.map(\.id) == ["sail-catalog"], "words match in any order")
    }

    @Test func theKindFilterShowsOnlyThatKindAndHidesEmptyCategories() {
        let rig = Rig(entries: Self.sample)
        #expect(rig.model.visibleCategories == ["Yachts", "Ships", "Couchbase"])
        rig.model.kind = .catalog
        #expect(rig.model.filteredEntries.map(\.id) == ["engine-catalog", "sail-catalog"])
        #expect(rig.model.visibleCategories == ["Yachts"], "Ships and Couchbase have no catalog")
        #expect(rig.model.sections.map(\.category) == ["Yachts"])
    }

    @Test func aChosenCategoryShowsOnlyItsEntriesAndAllShowsEverySection() {
        let rig = Rig(entries: Self.sample)
        #expect(rig.model.sections.map(\.category) == ["Yachts", "Ships", "Couchbase"])
        rig.model.category = "Ships"
        #expect(rig.model.sections.map(\.category) == ["Ships"])
        rig.model.kind = .whitepaper
        #expect(rig.model.sections.isEmpty, "the chosen category has no whitepaper")
    }

    @Test func browsingAndSearchingMakeNoRequests() {
        let rig = Rig(entries: Self.sample)
        rig.model.searchText = "boat"
        rig.model.kind = .manual
        rig.model.category = "Yachts"
        _ = rig.model.sections
        _ = rig.model.visibleCategories
        for entry in Self.sample { _ = rig.model.state(of: entry) }
        #expect(rig.downloader.downloads.isEmpty)
    }

    // MARK: Importing

    @Test func oneEntryDownloadsAndJoinsTheLibraryWithItsTitle() async throws {
        let rig = Rig(entries: Self.sample)
        #expect(rig.state("hull-guide") == .notImported)
        rig.model.requestImport(["hull-guide"])
        #expect(rig.state("hull-guide") == .downloading(nil))
        await rig.model.settle()

        let document = try #require(try await rig.repo.document(id: "catalog-hull-guide"))
        #expect(document.title == "Hull maintenance")
        #expect(document.origin?.entryId == "hull-guide")
        #expect(await rig.waitUntilReady("hull-guide"))
        #expect(rig.state("hull-guide") == .inLibrary)
        #expect(!rig.model.canImport(rig.catalog.entry(id: "hull-guide")!), "an entry in the library offers no import")
    }

    @Test func aDocumentThatWaitsForIndexingIsQueued() async {
        let rig = Rig(entries: Self.sample)
        await rig.repo.upsert(DocumentRecord(id: "catalog-hull-guide", title: "Hull maintenance", type: .pdf))
        await rig.repo.upsert(job: IngestJobRecord(docId: "catalog-hull-guide", targetGeneration: 1))
        await rig.library.refresh()
        #expect(rig.state("hull-guide") == .queued)
    }

    @Test func downloadingShowsProgressAndCancellingReturnsToNotImported() async throws {
        let rig = Rig(entries: Self.sample)
        rig.downloader.setBehavior(.suspend, for: "hull-guide")
        let entry = rig.catalog.entry(id: "hull-guide")!
        rig.model.requestImport(["hull-guide"])
        #expect(await eventually { rig.state("hull-guide") == .downloading(0.1) })

        rig.model.cancel(entry)
        #expect(await eventually { rig.state("hull-guide") == .notImported })
        #expect(rig.downloader.cancelled == ["hull-guide"])
        #expect(try await rig.repo.documents().isEmpty)
        #expect(rig.downloader.writtenFiles.isEmpty)
    }

    @Test func severalEntriesImportAndOneFailureDoesNotStopTheOthers() async throws {
        let rig = Rig(entries: Self.sample)
        rig.downloader.setBehavior(.fail(.blocked), for: "engine-catalog")
        for id in ["outboard-guide", "engine-catalog", "hull-guide", "whitepaper-a", "sail-catalog"] { rig.model.selection.insert(id) }
        rig.model.requestImportOfSelection()
        await rig.model.settle()

        #expect(Set(try await rig.repo.documents().map(\.id)) == [
            "catalog-outboard-guide", "catalog-hull-guide", "catalog-whitepaper-a", "catalog-sail-catalog",
        ])
        guard case .failed(let failure) = rig.state("engine-catalog") else { Issue.record("the refused entry is not failed"); return }
        #expect(failure.canOpenInBrowser)
        #expect(rig.model.selection.isEmpty)
    }

    @Test func aRefusedEntryShowsAReasonAndRetryImportsIt() async throws {
        let rig = Rig(entries: Self.sample)
        rig.downloader.setBehavior(.fail(.blocked), for: "hull-guide")
        rig.model.requestImport(["hull-guide"])
        await rig.model.settle()
        guard case .failed(let failure) = rig.state("hull-guide") else { Issue.record("not failed"); return }
        #expect(failure.message.contains("does not allow automatic downloads") && failure.canOpenInBrowser)
        #expect(rig.model.canImport(rig.catalog.entry(id: "hull-guide")!), "a failed entry keeps its place and offers retry")

        rig.downloader.setBehavior(.succeed, for: "hull-guide")
        rig.model.retry(rig.catalog.entry(id: "hull-guide")!)
        await rig.model.settle()
        #expect(try await rig.repo.document(id: "catalog-hull-guide") != nil)
    }

    @Test(arguments: [
        (ManualDownloadError.offline, "internet connection"),
        (.gone, "no longer leads to a PDF"),
        (.notPDF, "no longer leads to a PDF"),
        (.http(503), "HTTP 503"),
        (.connectionLost, "connection was lost"),
    ])
    func eachFailureIsReadableAndLeavesNothingBehind(_ error: ManualDownloadError, _ words: String) async throws {
        let rig = Rig(entries: Self.sample)
        rig.downloader.setBehavior(.fail(error), for: "hull-guide")
        rig.model.requestImport(["hull-guide"])
        await rig.model.settle()
        guard case .failed(let failure) = rig.state("hull-guide") else { Issue.record("not failed"); return }
        #expect(failure.message.contains(words))
        #expect(try await rig.repo.documents().isEmpty)
    }

    @Test func anOversizeRefusalNamesTheEntryItsSizeAndTheLimit() {
        let entry = Self.entry("big", title: "Huge Manual")
        let known = CatalogText.failure(ManualDownloadError.tooLarge(bytes: 34 * 1024 * 1024), for: entry).message
        #expect(known.contains("Huge Manual") && known.contains("34 MB") && known.contains("20 MB"))
        let unknown = CatalogText.failure(ManualDownloadError.tooLarge(bytes: nil), for: entry).message
        #expect(unknown.contains("Huge Manual") && unknown.contains("20 MB"))
    }

    @Test func aChangedFileIsImportedWithANote() async throws {
        let rig = Rig(entries: Self.sample)
        rig.downloader.setBehavior(.updated, for: "hull-guide")
        rig.model.requestImport(["hull-guide"])
        await rig.model.settle()
        let entry = rig.catalog.entry(id: "hull-guide")!
        #expect(try await rig.repo.document(id: "catalog-hull-guide") != nil)
        #expect(rig.model.publisherUpdatedFile(entry))
        #expect(!rig.model.publisherUpdatedFile(rig.catalog.entry(id: "outboard-guide")!))
    }

    @Test func downloadsBeyondTheLimitOfConcurrencyWaitAndACancelledOneLeavesTheQueue() async throws {
        let rig = Rig(entries: Self.sample, maxConcurrent: 1)
        for id in ["outboard-guide", "engine-catalog", "hull-guide"] { rig.downloader.setBehavior(.suspend, for: id) }
        rig.model.requestImport(["outboard-guide", "engine-catalog", "hull-guide"])
        #expect(await eventually { rig.downloader.downloads == ["outboard-guide"] })
        #expect(rig.state("engine-catalog") == .downloading(nil), "waiting for its turn")

        rig.model.cancel(rig.catalog.entry(id: "engine-catalog")!)
        #expect(rig.state("engine-catalog") == .notImported)
        rig.model.cancel(rig.catalog.entry(id: "outboard-guide")!)
        #expect(await eventually { rig.downloader.downloads == ["outboard-guide", "hull-guide"] })
        rig.model.stop()
        await rig.model.settle()
    }

    // MARK: The library decides

    @Test func deletingTheDocumentReturnsTheEntryToNotImported() async throws {
        let rig = Rig(entries: Self.sample)
        rig.model.requestImport(["hull-guide"])
        await rig.model.settle()
        #expect(await rig.waitUntilReady("hull-guide"))
        #expect(rig.state("hull-guide") == .inLibrary)

        await rig.library.delete("catalog-hull-guide")
        #expect(rig.state("hull-guide") == .notImported)
        #expect(rig.model.canImport(rig.catalog.entry(id: "hull-guide")!))
    }

    @Test func anEntryImportedOnAnotherIPadShowsInLibraryAndIsNotDownloadedHere() async throws {
        let rig = Rig(entries: Self.sample)
        // The record arrives through sync, with the origin it was imported with.
        let origin = DocumentOrigin(entryId: "hull-guide", url: URL(string: "https://example.com/hull-guide.pdf")!)
        await rig.repo.upsert(DocumentRecord(id: "catalog-hull-guide", title: "Hull maintenance", type: .pdf, activeGeneration: 1, chunkCount: 3, activeImageCount: 0, origin: origin))
        await rig.library.refresh()
        #expect(rig.state("hull-guide") == .inLibrary)
        #expect(rig.library.items.first?.origin == origin, "the library shows where the synced document came from")

        rig.model.requestImport(["hull-guide"])
        await rig.model.settle()
        #expect(rig.downloader.downloads.isEmpty)
        #expect(try await rig.repo.documents().count == 1, "no second document")
    }

    @Test func aBundledSampleCountsAsItsCatalogEntry() async throws {
        var entry = Self.entry("couchbase-hood", "Couchbase", .whitepaper)
        entry.documentId = "sample-couchbase-under-the-hood"
        let rig = Rig(entries: [entry])
        await rig.repo.upsert(DocumentRecord(id: "sample-couchbase-under-the-hood", title: "Couchbase Under the Hood.pdf", type: .pdf, activeGeneration: 1, chunkCount: 1, activeImageCount: 0))
        await rig.library.refresh()
        #expect(rig.state("couchbase-hood") == .inLibrary)
    }

    // MARK: Offline

    @Test func offlineBrowsingWorksAndImportDoesNothing() async {
        let rig = Rig(entries: Self.sample)
        rig.network.set(online: false)
        #expect(!rig.model.isOnline)
        #expect(rig.model.filteredEntries.count == Self.sample.count, "every entry is still listed")
        rig.model.requestImport(["hull-guide"])
        await rig.model.settle()
        #expect(rig.downloader.downloads.isEmpty)
        #expect(rig.state("hull-guide") == .notImported)
        #expect(CatalogText.offlineMessage.contains("internet connection"))

        rig.network.set(online: true)
        rig.model.requestImport(["hull-guide"])
        await rig.model.settle()
        #expect(rig.downloader.downloads == ["hull-guide"])
    }

    // MARK: The first download from a host

    @Test func theFirstDownloadFromAHostNamesItAndWaitsForTheUser() async throws {
        let rig = Rig(entries: [Self.entry("nrel", "Wind turbines", host: "docs.nlr.gov"), Self.entry("other", "Ships", host: "example.com")])
        rig.clearAcknowledgedHosts()
        rig.model.requestImport(["nrel"])
        let notice = try #require(rig.model.notice)
        #expect(notice.hosts == ["docs.nlr.gov"])
        #expect(CatalogText.notice(hosts: notice.hosts).contains("docs.nlr.gov"))
        #expect(rig.downloader.downloads.isEmpty, "nothing is requested before the user accepts")
        #expect(rig.state("nrel") == .notImported)

        rig.model.confirmNotice()
        await rig.model.settle()
        #expect(rig.downloader.downloads == ["nrel"])
        #expect(rig.model.notice == nil)
    }

    @Test func decliningTheNoticeDownloadsNothingAndAsksAgain() {
        let rig = Rig(entries: [Self.entry("nrel", "Wind turbines", host: "docs.nlr.gov")])
        rig.clearAcknowledgedHosts()
        rig.model.requestImport(["nrel"])
        rig.model.dismissNotice()
        #expect(rig.downloader.downloads.isEmpty && rig.model.notice == nil)
        rig.model.requestImport(["nrel"])
        #expect(rig.model.notice != nil)
    }

    @Test func anAcceptedHostIsRememberedAcrossLaunchesButAnotherHostStillAsks() async throws {
        let rig = Rig(entries: [Self.entry("nrel", "Wind turbines", host: "docs.nlr.gov"), Self.entry("other", "Ships", host: "example.com")])
        rig.clearAcknowledgedHosts()
        rig.model.requestImport(["nrel"])
        rig.model.confirmNotice()
        await rig.model.settle()

        let relaunched = rig.relaunched()
        #expect(relaunched.acknowledgedHosts == ["docs.nlr.gov"])
        relaunched.requestImport(["other"])
        #expect(relaunched.notice?.hosts == ["example.com"], "only the new host is named")
        relaunched.dismissNotice()
        #expect(rig.downloader.downloads == ["nrel"])
    }

    @Test func severalEntriesNameEveryNewHostOnce() {
        let rig = Rig(entries: [
            Self.entry("a", host: "one.example"), Self.entry("b", host: "one.example"), Self.entry("c", host: "two.example"),
        ])
        rig.clearAcknowledgedHosts()
        rig.model.requestImport(["a", "b", "c"])
        #expect(rig.model.notice?.hosts == ["one.example", "two.example"])
        #expect(rig.model.notice?.entryIDs == ["a", "b", "c"])
    }
}
