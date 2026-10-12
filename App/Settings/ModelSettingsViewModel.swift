import Core
import Foundation
import Observation
import Ports

/// What the Models page needs from the app model: what a switch costs, and the switch itself.
@MainActor
protocol ModelSwitching: AnyObject {
    func switchCost(to id: String) async -> AppModel.SwitchCost?
    func switchModel(to id: String) async throws
}

extension AppModel: ModelSwitching {}

/// The Models page: which models are installed and in use, which can be downloaded, and what changing the model in use
/// costs. Searching and downloading are the only network use after setup, and only when the user asks for them.
@MainActor @Observable
final class ModelSettingsViewModel {
    struct InstalledRow: Identifiable, Equatable {
        let id: String
        let title: String
        let role: ModelRole
        let bytes: Int64
        let licence: String?
        let repository: URL?
        let isActive: Bool
        /// An embedding model that is not in the built-in list: how well search works with it is unknown.
        var isUntested = false
    }

    /// A model that can be downloaded: an embedder from the catalog, a built-in default that was deleted, or a search result.
    struct AvailableRow: Identifiable, Equatable {
        let id: String
        let spec: ModelSpec
        let source: ModelSource
        var state: ModelState
        /// What is known before downloading, for search results.
        var verdict: ModelCandidate.Verdict?
        /// Whether an embedding model analyzes photos, for catalog entries.
        var supportsPhotos: Bool?
        /// For a search result that is the very file of an entry in the built-in list: that entry, which is tested and is what
        /// gets installed.
        var catalogSpec: ModelSpec?

        var title: String { spec.title }
        var isEmbedder: Bool { spec.role == .embedder }
        /// An embedding model found by search that is not in the built-in list.
        var isUntestedEmbedder: Bool { isEmbedder && source == .search && catalogSpec == nil }

        /// A model the checks before download ruled out cannot be downloaded; one that is being downloaded or is installed need not be.
        var canDownload: Bool {
            if case .incompatible? = verdict { return false }
            switch state {
            case .missing, .failed: return true
            case .downloading, .verifying, .installed: return false
            }
        }
    }

    /// What the user is asked before the model in use changes.
    struct Confirmation: Equatable, Identifiable {
        let id: String
        let title: String
        let message: String
    }

    enum SearchState: Equatable {
        case idle, searching, results, offline
        case failed(String)
    }

    private(set) var installed: [InstalledRow] = []
    /// Embedding models in the catalog that are not installed.
    private(set) var availableEmbedders: [AvailableRow] = []
    /// Built-in language models that are not installed (the default, after it was deleted).
    private(set) var availableDefaults: [AvailableRow] = []
    private(set) var results: [AvailableRow] = []
    private(set) var searchState = SearchState.idle
    private(set) var storageAvailable: Int64 = 0
    private(set) var isSwitching = false
    var query = ""
    var confirmation: Confirmation?
    var errorMessage: String?

    @ObservationIgnored private let store: ModelStore
    @ObservationIgnored private let catalog: EmbedderCatalog
    @ObservationIgnored private let finder: ModelCandidateFinder
    @ObservationIgnored private weak var switching: (any ModelSwitching)?
    @ObservationIgnored private let tracer: any Tracer
    @ObservationIgnored private let repositoryHost: String

    init(
        store: ModelStore, catalog: EmbedderCatalog, finder: ModelCandidateFinder, switching: any ModelSwitching,
        tracer: any Tracer = NoTracer(), repositoryHost: String = "huggingface.co"
    ) {
        self.store = store
        self.catalog = catalog
        self.finder = finder
        self.switching = switching
        self.tracer = tracer
        self.repositoryHost = repositoryHost
    }

    // MARK: Following the store

    /// Brings the page up to date, then again after every change in the store (download progress included), for as long
    /// as the caller keeps this task alive.
    func observe() async {
        await reload()
        for await snapshot in await store.updates() { await reload(snapshot) }
    }

    func reload(_ known: [String: ModelState]? = nil) async {
        let snapshot: [String: ModelState]
        if let known { snapshot = known } else { snapshot = await store.snapshot() }
        let records = await store.installedModels()
        var rows: [InstalledRow] = []
        for record in records {
            let spec = record.spec
            rows.append(InstalledRow(
                id: spec.id, title: spec.title, role: spec.role, bytes: spec.bytes, licence: spec.licence, repository: spec.repository,
                isActive: await store.isActive(spec.id), isUntested: spec.role == .embedder && catalog.entry(id: spec.id) == nil))
        }
        installed = rows
        let installedIDs = Set(records.map(\.spec.id))
        availableEmbedders = catalog.embedders.filter { !installedIDs.contains($0.id) }.map { entry in
            AvailableRow(
                id: entry.id, spec: entry.spec, source: .catalog, state: snapshot[entry.id] ?? .missing, verdict: nil,
                supportsPhotos: entry.profile.supportsImages)
        }
        let catalogIDs = Set(catalog.embedders.map(\.id))
        availableDefaults = store.manifest.models.filter { !installedIDs.contains($0.id) && !catalogIDs.contains($0.id) }.map { spec in
            AvailableRow(id: spec.id, spec: spec, source: .manifest, state: snapshot[spec.id] ?? .missing, verdict: nil, supportsPhotos: nil)
        }
        results = results.map { row in
            var row = row
            row.state = snapshot[row.id] ?? .missing
            return row
        }
        storageAvailable = (try? await store.storageRequirement().available) ?? 0
    }

    // MARK: Finding language models

    /// Searches the model repository for language models, and judges each result before anything is downloaded.
    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            searchState = .idle
            return
        }
        searchState = .searching
        let operation = TraceOperation(id: "model-search-\(UUID().uuidString)", kind: .modelSearch, title: "Model search")
        do {
            let candidates = try await TraceContext.$operation.withValue(operation) {
                tracer.emit(.modelRequest(.search, host: repositoryHost, subject: text))
                return try await finder.find(text)
            }
            let snapshot = await store.snapshot()
            results = candidates.map { candidate in
                // The same file as an entry of the built-in list is that entry: tested, with its own settings.
                let tested = candidate.spec.role == .embedder
                    ? catalog.embedders.first { $0.spec.sha256 == candidate.spec.sha256 }?.spec : nil
                return AvailableRow(
                    id: candidate.id, spec: candidate.spec, source: .search, state: snapshot[tested?.id ?? candidate.id] ?? .missing,
                    verdict: candidate.verdict, supportsPhotos: nil, catalogSpec: tested)
            }
            searchState = .results
        } catch ModelSearchError.offline {
            results = []
            searchState = .offline
        } catch {
            results = []
            searchState = .failed(error.localizedDescription)
        }
    }

    // MARK: Downloading and deleting

    /// Downloads a model and installs it, inactive. Whether this runtime can run it is checked once it is downloaded.
    func download(_ row: AvailableRow) async {
        guard row.canDownload else { return }
        errorMessage = nil
        let operation = TraceOperation(id: "model-download-\(UUID().uuidString)", kind: .modelDownload, title: "Model download")
        do {
            try await TraceContext.$operation.withValue(operation) {
                tracer.emit(.modelRequest(.download, host: row.spec.url.host ?? repositoryHost, subject: row.spec.title))
                try await store.install(ModelRecord(spec: row.catalogSpec ?? row.spec, source: row.catalogSpec == nil ? row.source : .catalog, chosenByUser: true))
            }
        } catch ModelStoreError.insufficientStorage(let required, let available) {
            errorMessage = "Not enough space for \(row.title): free up \(Format.bytes(max(required - available, 0))) first."
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    /// Deletes an installed model that is not in use.
    func delete(_ id: String) async {
        errorMessage = nil
        do {
            try await store.delete(id)
        } catch ModelStoreError.activeModel {
            errorMessage = "The model in use cannot be deleted. Use another one first."
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    // MARK: Changing the model in use

    /// Asks before anything changes: names what the change costs. Nothing happens until `confirm()`.
    func requestActivation(of id: String) async {
        guard let row = installed.first(where: { $0.id == id }), !row.isActive, let cost = await switching?.switchCost(to: id) else { return }
        confirmation = Confirmation(id: id, title: row.title, message: Self.message(for: cost))
    }

    func dismissConfirmation() { confirmation = nil }

    /// Switches to the model the user confirmed. A confirmation dialog clears the pending confirmation when any of its buttons
    /// is tapped, so the view passes the one it showed; without it, the pending one is used.
    func confirm(_ shown: Confirmation? = nil) async {
        guard let confirmation = shown ?? self.confirmation else { return }
        self.confirmation = nil
        errorMessage = nil
        isSwitching = true
        do {
            try await switching?.switchModel(to: confirmation.id)
        } catch {
            errorMessage = "\(confirmation.title) could not be used: \(error.localizedDescription) The previous model is back in use."
        }
        isSwitching = false
        await reload()
    }

    /// The cost of a switch in words (the model-catalog spec's Activation confirmation requirement).
    static func message(for cost: AppModel.SwitchCost) -> String {
        switch cost.role {
        case .generator:
            return "An answer that is being written will stop."
        case .embedder:
            let documents = cost.documentsToReindex
            let reindex = documents == 0
                ? "No documents need to be re-indexed."
                : "\(documents) document\(documents == 1 ? "" : "s") will be re-indexed with this model. Until a document is done, search finds it by keywords only."
            let photos = cost.supportsPhotos
                ? "Photo search is unavailable until the re-index finishes."
                : "This model cannot analyze photos, so photo search is off for as long as it is in use."
            let untested = cost.untested
                ? " This embedding model has not been tested with ManualBot, so how well search works with it is unknown. You can switch back."
                : ""
            let sync = cost.pausesSync
                ? " Sync pauses while this model is in use, and resumes when \(FleetModel.standard.name), the model every iPad that shares the library uses, is in use again and every document has been re-indexed with it."
                : ""
            return "\(reindex) \(photos)\(untested)\(sync) An answer that is being written, and indexing in progress, will stop."
        }
    }
}

extension ModelCandidate.Verdict {
    /// What the Models page says about a search result before it is downloaded.
    var label: String {
        switch self {
        case .compatible: "Compatible"
        case .checkedAfterDownload: "Checked after download"
        case .incompatible(.notALiteRTFile): "Not a LiteRT-LM model file"
        case .incompatible(.unknownKind): "Unknown kind of model"
        case .incompatible(.tooLarge): "Too large for this iPad"
        case .incompatible(.needsNewerRuntime): "Needs a newer version of the app"
        }
    }
}
