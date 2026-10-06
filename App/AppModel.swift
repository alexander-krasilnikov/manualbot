import Core
import Foundation
import Observation
import BackgroundTasks
import Ports
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
    private(set) var preparation = Preparation.waitingForModels
    private(set) var library: LibraryViewModel?
    private(set) var chat: ChatViewModel?
    private(set) var source: SourceViewerModel?

    private let factory: any ServiceFactory
    private var core: CoreServices?
    private var chatService: ChatService?
    private var building = false

    init(models: ModelSetupViewModel, factory: any ServiceFactory, demo: DemoSession? = nil) {
        self.models = models
        self.factory = factory
        self.demo = demo ?? DemoSession()
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
            if readiness.canImport, core == nil {
                preparation = .preparing("Starting…")
                let core = try await factory.makeCore { message in Task { @MainActor in self.preparation = .preparing(message) } }
                self.core = core
                demo.xray.inspector = core.repository
                let retriever = core.retriever
                library = LibraryViewModel(documents: core.repository, jobs: core.repository, ingestion: core.ingestion) {
                    _ = try? await retriever.retrieve("index warm-up")
                }
                source = SourceViewerModel(documents: core.repository, extractor: core.extractor, tracer: demo.tracer)
                chat = ChatViewModel(chats: core.repository, documents: core.repository, ingestion: core.ingestion)
                demo.xray.resetAction = { [weak self] in await self?.resetDemo() }
            }
            if readiness.canChat, let core, chatService == nil {
                preparation = .preparing("Loading the language model…")
                let service = try await factory.makeChat(core: core)
                chatService = service
                chat?.attach(service)
            }
            if core != nil { preparation = .ready }
        } catch {
            preparation = .failed(error.localizedDescription)
        }
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
            for url in samples { _ = try? await ingestion.enqueue(fileURL: url) }
        }
        source?.close()
        await chat.load()
        await library.refresh()
        Task { await ingestion.run() }
    }

    // MARK: Opening files from other apps

    func open(_ urls: [URL]) async { await library?.importFiles(urls) }
}
