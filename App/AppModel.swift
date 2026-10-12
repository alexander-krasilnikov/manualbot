import Core
import Foundation
import Observation
import BackgroundTasks
import Ports
import PortsTesting
import UIKit

/// Owns the screens' state and builds the real services as the models become ready: the embedder
/// unlocks import and search, the language model unlocks chat.
@MainActor @Observable
final class AppModel {
    enum Preparation: Equatable {
        case waitingForModels
        case preparing(String)
        case ready
        case failed(String)
    }

    struct Readiness: Equatable, Sendable {
        var canImport: Bool
        var canChat: Bool
    }

    let models: ModelSetupViewModel
    let demo: DemoSession
    /// Sync of the library with a server: its settings, and the replicator of the library that is open.
    let sync: SyncModel
    private(set) var preparation = Preparation.waitingForModels
    private(set) var library: LibraryViewModel?
    private(set) var chat: ChatViewModel?
    private(set) var source: SourceViewerModel?

    private let factory: any ServiceFactory
    /// The embedding models the app has a profile for. The one in use is looked up here when the services are built.
    private let catalog: EmbedderCatalog
    private let finder: ModelCandidateFinder
    private var core: CoreServices?
    private var chatService: ChatService?
    private var building = false

    /// The Settings page showing, if any. It is presented from the root view, so that it stays when the workspace is
    /// rebuilt for a switch of models.
    var presentedSettings: SettingsEntry?
    /// The embedding model in use, as it is named to the user.
    private var embedderTitle = ""

    /// The Models page: its models, its search and the switch of the model in use.
    @ObservationIgnored private(set) lazy var settings = ModelSettingsViewModel(
        store: models.store, catalog: catalog, finder: finder, switching: self, tracer: demo.tracer)

    init(
        models: ModelSetupViewModel, factory: any ServiceFactory, catalog: EmbedderCatalog,
        finder: ModelCandidateFinder = AppModel.offlineFinder, demo: DemoSession? = nil, syncSettings: SyncSettings? = nil
    ) {
        self.sync = SyncModel(settings: syncSettings ?? SyncSettings())
        self.models = models
        self.factory = factory
        self.catalog = catalog
        self.finder = finder
        self.demo = demo ?? DemoSession()
    }

    /// A finder with nothing to search: its search is offline. For an app model whose Models page is not used.
    static var offlineFinder: ModelCandidateFinder {
        let search = FakeModelSearch()
        search.fail(with: ModelSearchError.offline)
        return ModelCandidateFinder(search: search, probe: FakeHeaderProbe(), runtimeVersion: "0")
    }

    /// Keeps the services in step with model readiness, and frees model memory on memory warnings.
    func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.models.observe() }
            group.addTask { await self.follow() }
            group.addTask { await self.watchMemory() }
            group.addTask { await self.demo.xray.run() }
        }
    }

    private func follow() async {
        for await readiness in Observations({ Readiness(canImport: self.models.canImport, canChat: self.models.canChat) }) {
            await build(for: readiness)
        }
    }

    private func build(for readiness: Readiness) async {
        guard !building else { return }
        building = true
        defer { building = false }
        do {
            try await buildServices(for: readiness)
        } catch {
            preparation = .failed(error.localizedDescription)
        }
    }

    /// Builds the services the models in use allow, in stages: search and import once the embedding model is ready,
    /// answers once the language model is too. With `verifyChat` the language model is loaded at once, so that one that
    /// cannot be loaded is found out; otherwise it loads at the first question.
    private func buildServices(for readiness: Readiness, verifyChat: Bool = false) async throws {
        if readiness.canImport, core == nil {
            preparation = .preparing("Starting…")
            let selection = try await embedderSelection()
            let core = try await factory.makeCore(embedder: selection) { message in
                Task { @MainActor in self.preparation = .preparing(message) }
            }
            self.core = core
            embedderTitle = selection.spec.title
            // A new embedding model re-indexes the library by itself; the library view runs the queued work.
            _ = try? await core.ingestion.reindexOutdated(for: core.embedding)
            demo.xray.inspector = core.repository
            demo.explorer.inspector = core.repository
            let retriever = core.retriever
            library = LibraryViewModel(documents: core.repository, jobs: core.repository, ingestion: core.ingestion) {
                _ = try? await retriever.retrieve("index warm-up")
            }
            library?.photosExplanation = core.photosExplanation
            source = SourceViewerModel(documents: core.repository, extractor: core.extractor, tracer: demo.tracer)
            chat = ChatViewModel(chats: core.repository, documents: core.repository, ingestion: core.ingestion)
            chat?.stubPhoto = factory.stubPhoto
            chat?.photosAvailable = core.supportsPhotos
            chat?.photosExplanation = core.photosExplanation
            demo.xray.resetAction = { [weak self] in await self?.resetDemo() }
            demo.xray.syncEnabled = { [weak self] in self?.sync.isEnabled ?? false }
            sync.onActivity = { [weak self] in await self?.library?.refresh() }
            await sync.attach(SyncModel.Library(
                sync: core.sync, ingestion: core.ingestion, embedding: core.embedding, embeddingName: embedderTitle,
                fleet: factory.fleetModel))
        }
        if readiness.canChat, let core, chatService == nil {
            preparation = .preparing("Loading the language model…")
            guard let generator = await models.store.activeSpec(for: .generator) else {
                throw ServiceError.modelNotInstalled("language model")
            }
            let service = try await factory.makeChat(core: core, generator: generator)
            if verifyChat { try await factory.verifyChat(generator: generator) }
            chatService = service
            chat?.attach(service)
        }
        if core != nil { preparation = .ready }
    }

    // MARK: Switching models

    /// What a switch to an installed model costs, for the confirmation before it happens.
    struct SwitchCost: Equatable {
        var role: ModelRole
        /// Documents that are indexed again. Only a different embedding model needs this.
        var documentsToReindex: Int
        /// Whether photos can be analyzed with the model in use afterwards. An embedding model without them turns photo
        /// search off for as long as it is used; one with them is only without the documents not yet re-indexed.
        var supportsPhotos: Bool
        /// An embedding model that is not in the built-in list: how well search works with it is unknown.
        var untested = false
        /// Sync is on, and this embedding model is not the one every iPad shares: sync pauses while it is in use.
        var pausesSync = false
    }

    /// `nil` when the model is not installed, or is an embedding model the app has no profile for.
    func switchCost(to id: String) async -> SwitchCost? {
        guard let record = await models.store.installedModels().first(where: { $0.spec.id == id }) else { return nil }
        switch record.spec.role {
        case .generator:
            return SwitchCost(role: .generator, documentsToReindex: 0, supportsPhotos: core?.supportsPhotos ?? true)
        case .embedder:
            guard let selection = await selection(for: record.spec) else { return nil }
            let documents = (try? await core?.ingestion.outdatedDocuments(for: selection.profile.identity))?.count ?? 0
            return SwitchCost(
                role: .embedder, documentsToReindex: documents, supportsPhotos: selection.profile.supportsImages, untested: !selection.isTested,
                pausesSync: sync.isEnabled && selection.profile.identity != factory.fleetModel.identity)
        }
    }

    /// Makes an installed model the one in use. What is running ends first: an answer being written is kept as a stopped
    /// answer, and indexing stops where it is. The services are then built again from the new model and indexing resumes:
    /// a different embedding model re-indexes the whole library, document by document. A model that cannot be loaded is
    /// not kept: the one in use before is restored and the error is thrown.
    func switchModel(to id: String) async throws {
        let store = models.store
        guard let record = await store.installedModels().first(where: { $0.spec.id == id }) else { throw ModelStoreError.notInstalled(id) }
        let role = record.spec.role
        guard let previous = await store.activeSpec(for: role), previous.id != id else { return }
        if role == .embedder, await selection(for: record.spec) == nil { throw ServiceError.unknownEmbedder(record.spec.title) }

        building = true   // readiness changes during the switch are not for `follow()` to act on
        defer { building = false }
        await chat?.stopAndWait()
        await core?.ingestion.stop()
        await factory.unloadModels()
        preparation = .preparing("Switching to \(record.spec.title)…")
        do {
            try await store.activate(id)
            try await rebuild(role)
        } catch {
            // The model in use before still works: go back to it, so the app is never left without one.
            try? await store.activate(previous.id)
            do {
                try await rebuild(role)
            } catch {
                preparation = .failed(error.localizedDescription)
            }
            await resumeIndexing()
            throw error
        }
        await resumeIndexing()
    }

    private func rebuild(_ role: ModelRole) async throws {
        let readiness = Readiness(canImport: await models.store.canImport, canChat: await models.store.canChat)
        switch role {
        case .generator:
            chatService = nil
        case .embedder:
            await tearDownServices()
        }
        try await buildServices(for: readiness, verifyChat: true)
    }

    /// Drops everything built on the embedding model, and closes the library database so that the next one opens it
    /// afresh with the new model's vector size.
    private func tearDownServices() async {
        await sync.detach()   // the replicator works on the database that is about to close
        let old = core
        core = nil
        chatService = nil
        library = nil
        source = nil
        chat = nil
        demo.xray.inspector = nil
        demo.explorer.inspector = nil
        try? await old?.repository.close()
    }

    /// Indexing that was stopped for a switch carries on where it stopped (or starts over, for a different embedding model).
    private func resumeIndexing() async {
        guard let ingestion = core?.ingestion, await ingestion.hasPendingWork() else { return }
        Task { await ingestion.run() }
    }

    /// The embedding model the library's vectors are made by right now, or `nil` before the search services are up.
    var embeddingIdentity: EmbeddingModelIdentity? { core?.embedding }

    /// The embedding model in use, with the profile the app has for it.
    private func embedderSelection() async throws -> EmbedderSelection {
        guard let spec = await models.store.activeSpec(for: .embedder) else { throw ServiceError.modelNotInstalled("embedding model") }
        guard let selection = await selection(for: spec) else { throw ServiceError.unknownEmbedder(spec.title) }
        return selection
    }

    /// The profile for an embedding model: the tested one from the built-in list, or generic settings built from what the
    /// runtime read from its file. `nil` for a model that is neither (an embedder installed before its file was read).
    private func selection(for spec: ModelSpec) async -> EmbedderSelection? {
        if let entry = catalog.entry(id: spec.id) { return EmbedderSelection(spec: spec, profile: entry.profile) }
        guard let description = await models.store.record(for: spec.id)?.embedding else { return nil }
        return EmbedderSelection(spec: spec, profile: .untested(for: spec, description: description), isTested: false)
    }

    /// The model for browsing one document's chunks and images, or `nil` before the services are up.
    func makeContents(for item: LibraryViewModel.Item) -> DocumentContentsModel? {
        guard let core else { return nil }
        return DocumentContentsModel(docId: item.id, title: item.title, type: item.type, documents: core.repository, tracer: demo.tracer)
    }

    private func watchMemory() async {
        for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
            await factory.unloadModels()
        }
    }

    // MARK: Background indexing

    static let backgroundTaskID = "com.manualbot.app.ingestion"

    /// Must be called before the app finishes launching.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in await self.runInBackground(task) }
        }
    }

    /// Asks the system for background time when documents are still being indexed as the app leaves the screen.
    func scheduleBackgroundIndexingIfNeeded() async {
        guard let core, await core.ingestion.hasPendingWork() else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runInBackground(_ task: BGProcessingTask) async {
        // A background launch has no screen, so bring the services up here.
        let work = Task { @MainActor in
            await models.refreshOnce()
            await build(for: Readiness(canImport: models.canImport, canChat: false))
            await core?.ingestion.run()
        }
        // If time runs out, stop; interrupted jobs resume where they left off.
        task.expirationHandler = { work.cancel() }
        await work.value
        task.setTaskCompleted(success: !work.isCancelled)
        await scheduleBackgroundIndexingIfNeeded()
    }

    // MARK: Demo reset

    /// Deletes every chat and document, then imports the sample documents, all traced as one operation.
    func resetDemo() async {
        guard let core, let library, let chat else { return }
        await chat.stopAndWait()
        let operation = TraceOperation(id: "reset-\(UUID().uuidString)", kind: .reset, title: "Reset demo")
        let ingestion = core.ingestion
        let repository = core.repository
        await TraceContext.$operation.withValue(operation) {
            for record in (try? await repository.chats()) ?? [] { try? await repository.deleteChat(id: record.id) }
            for document in (try? await repository.documents()) ?? [] { try? await ingestion.delete(docId: document.id) }
            let samples = (try? SampleDocuments.write(into: FileManager.default.temporaryDirectory)) ?? []
            for url in samples { _ = try? await ingestion.enqueue(fileURL: url, id: SampleDocuments.id(for: url)) }
        }
        source?.close()
        await chat.load()
        await library.refresh()
        Task { await ingestion.run() }
    }

    // MARK: Opening files from other apps

    func open(_ urls: [URL]) async { await library?.importFiles(urls) }
}
