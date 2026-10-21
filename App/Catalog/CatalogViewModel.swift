import Core
import Foundation
import Observation
import Ports

/// The manual catalog: the bundled list, what the user filtered it to, and where each entry stands. An entry's state is
/// not stored: it follows from the library's documents (an entry is imported when a document has its identity, whether
/// this iPad imported it or another one that shares the library) and from the downloads in flight here.
@MainActor @Observable
final class CatalogViewModel {
    enum EntryState: Equatable {
        case notImported
        /// A download is running, or waiting for its turn. `nil` while its size is not known yet.
        case downloading(Double?)
        /// Downloaded and waiting to be indexed.
        case queued
        case inLibrary
        case failed(Failure)
    }

    struct Failure: Equatable {
        var message: String
        /// The publisher refused, or moved the file: the address is worth opening in the browser.
        var canOpenInBrowser: Bool
    }

    /// The first download from a host asks the user to accept going online to it.
    struct HostNotice: Equatable, Identifiable {
        let hosts: [String]
        let entryIDs: [String]
        var id: String { entryIDs.joined(separator: ",") }
    }

    let catalog: ManualCatalog
    var searchText = ""
    /// Only entries of this kind; `nil` for all.
    var kind: ManualKind?
    /// The category chosen in the sidebar; `nil` for all.
    var category: String?
    /// Entries ticked for a multiple import.
    var selection: Set<String> = []

    private(set) var notice: HostNotice?
    /// How many downloads run at once. The rest wait, in the order they were asked for.
    let maxConcurrent: Int

    private var downloads: [String: Double] = [:]
    private var failures: [String: Failure] = [:]
    private var updated: Set<String> = []
    private var queue: [String] = []
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    private(set) var acknowledgedHosts: Set<String>

    private let library: LibraryViewModel
    private let importer: CatalogImporter
    private let network: NetworkMonitor
    @ObservationIgnored private let defaults: UserDefaults
    private static let acknowledgedKey = "manualCatalog.acknowledgedHosts"

    init(
        catalog: ManualCatalog, library: LibraryViewModel, importer: CatalogImporter, network: NetworkMonitor,
        defaults: UserDefaults = .standard, maxConcurrent: Int = 2
    ) {
        self.catalog = catalog
        self.library = library
        self.importer = importer
        self.network = network
        self.defaults = defaults
        self.maxConcurrent = max(1, maxConcurrent)
        acknowledgedHosts = Set(defaults.stringArray(forKey: Self.acknowledgedKey) ?? [])
    }

    /// Reads the accepted hosts again. For tests that change them behind the model's back.
    func reloadAcknowledgedHosts() { acknowledgedHosts = Set(defaults.stringArray(forKey: Self.acknowledgedKey) ?? []) }

    // MARK: Browsing

    var isOnline: Bool { network.isOnline }

    /// Starts watching the connection, for the offline message.
    func startMonitoringNetwork() { network.start() }

    /// The entries that pass the kind filter and the search, in the catalog's order.
    var filteredEntries: [ManualCatalogEntry] {
        let words = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        return catalog.entries.filter { entry in
            if let kind, entry.kind != kind { return false }
            let haystack = "\(entry.title) \(entry.publisher) \(entry.category)"
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }

    /// The categories that still have an entry after filtering. A category with none is hidden.
    var visibleCategories: [String] {
        let present = Set(filteredEntries.map(\.category))
        return catalog.categories.filter { present.contains($0) }
    }

    func count(in category: String) -> Int { filteredEntries.filter { $0.category == category }.count }

    /// What the list shows: the chosen category, or every visible one, each with its entries.
    var sections: [(category: String, entries: [ManualCatalogEntry])] {
        let entries = filteredEntries
        let shown = category.map { [$0] } ?? visibleCategories
        return shown.compactMap { name in
            let inCategory = entries.filter { $0.category == name }
            return inCategory.isEmpty ? nil : (name, inCategory)
        }
    }

    func entry(id: String) -> ManualCatalogEntry? { catalog.entry(id: id) }

    // MARK: State

    func state(of entry: ManualCatalogEntry) -> EntryState {
        if let progress = downloads[entry.id] { return .downloading(progress > 0 ? progress : nil) }
        if let item = library.items.first(where: { $0.id == entry.documentID }) {
            return item.status == .queued ? .queued : .inLibrary
        }
        if let failure = failures[entry.id] { return .failed(failure) }
        return .notImported
    }

    /// Whether the entry can be imported now: it is not in the library and nothing is downloading it.
    func canImport(_ entry: ManualCatalogEntry) -> Bool {
        switch state(of: entry) {
        case .notImported, .failed: true
        case .downloading, .queued, .inLibrary: false
        }
    }

    /// The publisher has replaced the file since the catalog recorded it, found when this entry was downloaded.
    func publisherUpdatedFile(_ entry: ManualCatalogEntry) -> Bool { updated.contains(entry.id) }

    // MARK: Importing

    /// The ticked entries that can be imported.
    var importableSelection: [ManualCatalogEntry] { catalog.entries.filter { selection.contains($0.id) && canImport($0) } }

    func toggleSelection(_ entry: ManualCatalogEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else if canImport(entry) { selection.insert(entry.id) }
    }

    /// Imports these entries, after the user has accepted going online to a host they have not downloaded from before.
    /// Does nothing offline: the sheet says why.
    func requestImport(_ ids: [String]) {
        guard isOnline else { return }
        let entries = ids.compactMap { entry(id: $0) }.filter(canImport)
        guard !entries.isEmpty else { return }
        let hosts = Set(entries.map(\.host)).subtracting(acknowledgedHosts)
        if hosts.isEmpty {
            start(entries.map(\.id))
        } else {
            notice = HostNotice(hosts: hosts.sorted(), entryIDs: entries.map(\.id))
        }
    }

    func requestImportOfSelection() { requestImport(importableSelection.map(\.id)) }

    /// The user accepted the notice: the hosts are remembered, so they are not asked again, and the downloads start.
    func confirmNotice() {
        guard let notice else { return }
        self.notice = nil
        acknowledgedHosts.formUnion(notice.hosts)
        defaults.set(acknowledgedHosts.sorted(), forKey: Self.acknowledgedKey)
        start(notice.entryIDs)
    }

    func dismissNotice() { notice = nil }

    func retry(_ entry: ManualCatalogEntry) { requestImport([entry.id]) }

    /// Stops a download, or removes it from the queue. The entry returns to "not imported", with nothing kept.
    func cancel(_ entry: ManualCatalogEntry) {
        if let task = running[entry.id] {
            task.cancel()
        } else if let index = queue.firstIndex(of: entry.id) {
            queue.remove(at: index)
            downloads[entry.id] = nil
        }
    }

    /// Ends every download, for when the library is torn down.
    func stop() {
        queue.removeAll()
        for task in running.values { task.cancel() }
    }

    /// Waits until nothing is downloading or queued. For tests.
    func settle() async {
        while !downloads.isEmpty || !running.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func start(_ ids: [String]) {
        for id in ids where downloads[id] == nil {
            downloads[id] = 0
            failures[id] = nil
            updated.remove(id)
            selection.remove(id)
            queue.append(id)
        }
        pump()
    }

    private func pump() {
        while running.count < maxConcurrent, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let entry = entry(id: id) else { downloads[id] = nil; continue }
            running[id] = Task { [weak self] in await self?.perform(entry) }
        }
    }

    private func perform(_ entry: ManualCatalogEntry) async {
        let id = entry.id
        do {
            let result = try await importer.importEntry(entry) { [weak self] fraction in
                Task { @MainActor in self?.setProgress(fraction, for: id) }
            }
            if result.publisherUpdatedFile { updated.insert(id) }
            // The document is in the library before the download is forgotten, so the row never flickers back.
            await library.didImportFromCatalog()
        } catch is CancellationError {
            // Cancelled by the user: back to "not imported".
        } catch {
            failures[id] = CatalogText.failure(error, for: entry)
        }
        downloads[id] = nil
        running[id] = nil
        pump()
    }

    private func setProgress(_ fraction: Double, for id: String) {
        guard let current = downloads[id], running[id] != nil else { return }
        // A step of a percent is as fine as the bar can show; finer would redraw the list for nothing.
        if fraction - current >= 0.01 || fraction >= 1 { downloads[id] = fraction }
    }
}
