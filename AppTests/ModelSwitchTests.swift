import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

@MainActor private func eventually(_ timeout: Duration = .seconds(30), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Switching the model in use (model-catalog spec: Activation confirmation, Immediate switch), on the stand-in services
/// with a real database. The library's own task (`observe`) is started as a view would, to let re-indexing run.
@MainActor @Suite(.serialized) struct ModelSwitchTests {
    private let embedderA = StubServiceFactory.catalog.embedders[0]
    private let embedderB = StubServiceFactory.catalog.embedders[1]
    private let llm = ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://x.invalid/l")!, bytes: 3_000,
                                sha256: String(repeating: "c", count: 64), fileName: "l", displayName: "LLM")
    private let altLLM = ModelSpec(id: "alt-llm", version: "1", role: .generator, url: URL(string: "https://x.invalid/a")!, bytes: 2_000,
                                   sha256: String(repeating: "d", count: 64), fileName: "a", displayName: "Alternative LLM",
                                   licence: "apache-2.0")

    private struct Running {
        let app: AppModel
        let store: ModelStore
        let run: Task<Void, Never>
        var observer: Task<Void, Never>?
    }

    /// The app model with both defaults installed and ready, and the other embedder and language model installed beside them.
    private func launch(
        _ options: StubServiceFactory.Options = .init(), tracer: any Tracer = NoTracer(), syncSettings: SyncSettings? = nil
    ) async throws -> Running {
        let backend = FakeModelBackend()
        let store = ModelStore(manifest: ModelManifest(models: [embedderA.spec, llm]), downloader: backend, files: backend, safetyMargin: 0)
        let models = ModelSetupViewModel(store: store)
        let app = AppModel(
            models: models, factory: StubServiceFactory(options: options, tracer: tracer), catalog: StubServiceFactory.catalog,
            syncSettings: syncSettings)
        let run = Task { await app.run() }
        await models.start()
        #expect(await eventually { app.preparation == .ready && app.chat?.availability != .modelNotReady })
        try await store.install(ModelRecord(spec: embedderB.spec, source: .catalog, chosenByUser: true))
        try await store.install(ModelRecord(spec: altLLM, source: .search, chosenByUser: true))
        return Running(app: app, store: store, run: run, observer: nil)
    }

    /// Starts the library's own task and waits until every document is searchable and none is being indexed again.
    private func settle(_ running: inout Running) async -> Bool {
        running.observer?.cancel()
        let library = running.app.library
        running.observer = Task { await library?.observe() }
        return await eventually {
            guard let items = library?.items, !items.isEmpty else { return false }
            return items.allSatisfy { $0.status == .ready }
        }
    }

    /// The embedding models that made the chunks of the library's documents, for the documents `matching` selects.
    private func chunkModels(_ app: AppModel, matching: (LibraryViewModel.Item) -> Bool = { _ in true }) async throws -> Set<String> {
        var tags = Set<String>()
        for item in try #require(app.library).items where matching(item) {
            let contents = try #require(app.makeContents(for: item))
            await contents.load()
            tags.formUnion(contents.chunks.map(\.embeddingModel))
        }
        return tags
    }

    @Test func theCostNamesTheDocumentsToIndexAgainAndWhetherPhotosSurvive() async throws {
        var running = try await launch(.init(seedDocuments: true))
        defer { running.run.cancel(); running.observer?.cancel() }
        #expect(await settle(&running))
        let documents = try #require(running.app.library).items.count
        #expect(documents == 5)

        let embedder = try #require(await running.app.switchCost(to: embedderB.spec.id))
        #expect(embedder == AppModel.SwitchCost(role: .embedder, documentsToReindex: documents, supportsPhotos: false))
        let generator = try #require(await running.app.switchCost(to: altLLM.id))
        #expect(generator == AppModel.SwitchCost(role: .generator, documentsToReindex: 0, supportsPhotos: true))
        #expect(await running.app.switchCost(to: "not-installed") == nil)
    }

    @Test func switchingTheEmbedderRebuildsTheServicesAndEveryDocumentIsIndexedAgainByTheNewModel() async throws {
        var running = try await launch(.init(seedDocuments: true))
        defer { running.run.cancel(); running.observer?.cancel() }
        #expect(await settle(&running))
        #expect(try await chunkModels(running.app) == [StubServiceFactory.profile.identity.tag])
        let oldLibrary = try #require(running.app.library)

        try await running.app.switchModel(to: embedderB.spec.id)

        #expect(running.app.embeddingIdentity == StubServiceFactory.textOnlyProfile.identity)
        let newLibrary = try #require(running.app.library)
        #expect(newLibrary !== oldLibrary, "the search services were built again")
        #expect(await running.store.activeSpec(for: .embedder)?.id == embedderB.spec.id)
        #expect(running.app.preparation == .ready)
        #expect(await settle(&running))
        let text = try await chunkModels(running.app) { $0.type != .image }
        #expect(text == [StubServiceFactory.textOnlyProfile.identity.tag], "every document that can be indexed by text is on the new model: \(text)")
        // The stored photo cannot be analyzed without an image model, so it keeps the vectors it had: search skips them
        // (they belong to another model) and they are valid again when a model with photos is back.
        let photos = try await chunkModels(running.app) { $0.type == .image }
        #expect(photos == [StubServiceFactory.profile.identity.tag], "the photo is untouched: \(photos)")
        #expect(newLibrary.items.count == 5, "no document was lost")

        try await running.app.switchModel(to: embedderA.spec.id)
        #expect(await settle(&running))
        let everything = try await chunkModels(running.app)
        #expect(everything == [StubServiceFactory.profile.identity.tag], "back on the first model, every vector is valid again: \(everything)")
    }

    @Test func anEmbedderNotInTheListIsUsedWithGenericSettingsAndAnythingCanSwitchBack() async throws {
        var running = try await launch(.init(seedDocuments: true))
        defer { running.run.cancel(); running.observer?.cancel() }
        #expect(await settle(&running))
        let found = ModelSpec(
            id: "found-embedder", version: "rev", role: .embedder, url: URL(string: "https://x.invalid/found")!, bytes: 4_000,
            sha256: String(repeating: "9", count: 64), fileName: "found.litertlm", displayName: "Found Embedder", licence: "mit")
        let description = EmbeddingDescription(dimension: 384, supportsImages: false, maxInputLength: 256)
        try await running.store.install(ModelRecord(spec: found, source: .search, chosenByUser: true, embedding: description))

        let cost = try #require(await running.app.switchCost(to: found.id))
        #expect(cost.untested && cost.documentsToReindex == 5 && cost.supportsPhotos == false)
        #expect(try #require(await running.app.switchCost(to: embedderB.spec.id)).untested == false, "a list entry is tested")

        try await running.app.switchModel(to: found.id)

        #expect(running.app.embeddingIdentity != StubServiceFactory.profile.identity)
        #expect(await settle(&running))
        let text = try await chunkModels(running.app) { $0.type != .image }
        #expect(text.count == 1 && text != [StubServiceFactory.profile.identity.tag], "every document is on the untested model: \(text)")

        try await running.app.switchModel(to: embedderA.spec.id)
        #expect(await settle(&running))
        #expect(try await chunkModels(running.app) == [StubServiceFactory.profile.identity.tag], "switching back indexes everything again")
    }

    @Test func syncPausesOnAnotherEmbedderAndResumesOnlyOnceTheLibraryIsBackOnTheFleetModel() async throws {
        let defaults = UserDefaults(suiteName: "switch-sync-\(UUID().uuidString)")!
        let settings = SyncSettings(defaults: defaults, secrets: InMemorySecretStore())
        settings.address = "localhost:4984"
        settings.username = "ipad1"
        settings.isEnabled = true
        var running = try await launch(.init(seedDocuments: true), syncSettings: settings)
        defer { running.run.cancel(); running.observer?.cancel() }
        #expect(await settle(&running))
        #expect(await eventually { running.app.sync.state == .upToDate }, "on the fleet model, sync runs: \(running.app.sync.state)")

        try await running.app.switchModel(to: embedderB.spec.id)
        #expect(running.app.sync.state == .paused(.otherEmbedder(active: "Stub Text Embedder", fleet: SyncPolicy.fleetModelName)))
        #expect(await settle(&running))
        #expect(
            running.app.sync.state == .paused(.otherEmbedder(active: "Stub Text Embedder", fleet: SyncPolicy.fleetModelName)),
            "re-indexing with the other model does not bring it back")

        try await running.app.switchModel(to: embedderA.spec.id)
        #expect(await settle(&running))
        #expect(await eventually { running.app.sync.state == .upToDate }, "back on the fleet model and re-indexed: \(running.app.sync.state)")
    }

    @Test func aResetWithSyncOnIsTracedAsOneResetOperationWithItsDeletesAndImports() async throws {
        let defaults = UserDefaults(suiteName: "reset-sync-\(UUID().uuidString)")!
        let settings = SyncSettings(defaults: defaults, secrets: InMemorySecretStore())
        settings.address = "localhost:4984"
        settings.username = "ipad1"
        settings.isEnabled = true
        let tracer = RecordingTracer()
        var running = try await launch(.init(seedDocuments: true), tracer: tracer, syncSettings: settings)
        defer { running.run.cancel(); running.observer?.cancel() }
        #expect(await settle(&running))
        #expect(running.app.sync.isEnabled)
        let before = try #require(running.app.library).items.count
        #expect(before == 5)

        await running.app.resetDemo()

        let reset = tracer.events.filter { $0.operation?.kind == .reset }
        let deletes = reset.filter { if case .documentDeleted = $0.kind { true } else { false } }
        #expect(deletes.count == before, "every document is deleted inside the reset operation, as without sync")
        #expect(Set(reset.compactMap(\.operation?.id)).count == 1, "one reset operation")
        #expect(await settle(&running), "the samples are imported again and become ready")
        // Fixed identities: the samples are the documents every device that shares the library has.
        let ids = Set(try #require(running.app.library).items.map(\.id))
        #expect(ids.allSatisfy { $0.hasPrefix("sample-") }, "\(ids)")
    }

    @Test func theConfirmationAlsoWarnsThatSyncPausesWhenItIsOn() async throws {
        let defaults = UserDefaults(suiteName: "switch-sync-\(UUID().uuidString)")!
        let settings = SyncSettings(defaults: defaults, secrets: InMemorySecretStore())
        var running = try await launch(.init(seedDocuments: true), syncSettings: settings)
        defer { running.run.cancel(); running.observer?.cancel() }
        #expect(await settle(&running))

        #expect(try #require(await running.app.switchCost(to: embedderB.spec.id)).pausesSync == false, "sync is off")
        settings.isEnabled = true
        let cost = try #require(await running.app.switchCost(to: embedderB.spec.id))
        #expect(cost.pausesSync)
        #expect(ModelSettingsViewModel.message(for: cost).contains("Sync pauses"))
    }

    @Test func theReindexAlsoFinishesWhileTheServicesAreTraced() async throws {
        // The app passes the X-ray's tracer to the services, so every step is recorded as it happens.
        var running = try await launch(.init(seedDocuments: true), tracer: RecordingTracer())
        defer { running.run.cancel(); running.observer?.cancel() }
        #expect(await settle(&running))
        try await running.app.switchModel(to: embedderB.spec.id)
        #expect(await settle(&running), "every document is searchable and none is waiting to be indexed again")
    }

    @Test func aTextOnlyEmbedderTurnsPhotosOffAndNamesItself() async throws {
        let running = try await launch(.init(seedDocuments: true))
        defer { running.run.cancel() }
        #expect(running.app.chat?.photosAvailable == true)

        try await running.app.switchModel(to: embedderB.spec.id)

        #expect(running.app.chat?.photosAvailable == false)
        let reason = try #require(running.app.chat?.photosExplanation)
        #expect(reason.contains("Stub Text Embedder"), "the explanation names the embedding model: \(reason)")
        #expect(running.app.library?.photosExplanation == reason)

        // And back: the photo controls return.
        try await running.app.switchModel(to: embedderA.spec.id)
        #expect(running.app.chat?.photosAvailable == true)
        #expect(running.app.chat?.photosExplanation == nil)
    }

    @Test func switchingTheLanguageModelKeepsTheSearchServicesAndGivesTheChatAnotherAnswerer() async throws {
        let running = try await launch(.init(seedDocuments: true))
        defer { running.run.cancel() }
        let library = try #require(running.app.library), chat = try #require(running.app.chat)

        try await running.app.switchModel(to: altLLM.id)

        #expect(running.app.library === library && running.app.chat === chat, "only the answering service is replaced")
        #expect(await running.store.activeSpec(for: .generator)?.id == altLLM.id)
        #expect(chat.availability != .modelNotReady, "an answering service is attached")
        #expect(running.app.preparation == .ready)
    }

    @Test func switchingToTheModelAlreadyInUseDoesNothing() async throws {
        let running = try await launch(.init(seedDocuments: true))
        defer { running.run.cancel() }
        let library = try #require(running.app.library)
        try await running.app.switchModel(to: embedderA.spec.id)
        try await running.app.switchModel(to: llm.id)
        #expect(running.app.library === library)
    }

    @Test func aModelThatIsNotInstalledCannotBeChosen() async throws {
        let running = try await launch()
        defer { running.run.cancel() }
        await #expect(throws: ModelStoreError.notInstalled("nope")) { try await running.app.switchModel(to: "nope") }
    }

    @Test func aLanguageModelThatCannotBeLoadedIsNotKept() async throws {
        let running = try await launch(.init(seedDocuments: true, failingModels: ["alt-llm"]))
        defer { running.run.cancel() }
        await #expect(throws: StubServiceFactory.CannotLoad.self) { try await running.app.switchModel(to: "alt-llm") }
        #expect(await running.store.activeSpec(for: .generator)?.id == "llm", "the previous model is back in use")
        #expect(running.app.chat?.availability != .modelNotReady)
        #expect(running.app.preparation == .ready)
    }

    @Test func anEmbedderThatCannotBeLoadedIsNotKeptAndTheLibraryComesBack() async throws {
        let running = try await launch(.init(seedDocuments: true, failingModels: ["stub-text-embedder"]))
        defer { running.run.cancel() }
        await #expect(throws: StubServiceFactory.CannotLoad.self) { try await running.app.switchModel(to: "stub-text-embedder") }
        #expect(await running.store.activeSpec(for: .embedder)?.id == embedderA.spec.id)
        #expect(running.app.embeddingIdentity == StubServiceFactory.profile.identity)
        #expect(running.app.library != nil && running.app.chat?.availability != .modelNotReady)
        #expect(running.app.preparation == .ready)
    }

    @Test func anAnswerBeingWrittenIsKeptAsStoppedWhenTheModelChanges() async throws {
        var running = try await launch(.init(seedDocuments: true, slowAnswers: true))
        defer { running.run.cancel(); running.observer?.cancel() }
        #expect(await settle(&running))
        let chat = try #require(running.app.chat)
        chat.updateDocuments(try #require(running.app.library).items)
        #expect(chat.availability == .ready)
        chat.draft = "How do I reset the X200 to factory defaults?"
        let sending = Task { await chat.send() }
        #expect(await eventually { chat.isGenerating && !(chat.streaming ?? "").isEmpty })

        try await running.app.switchModel(to: altLLM.id)
        await sending.value

        #expect(chat.isGenerating == false)
        let answer = try #require(chat.messages.last { $0.role == .assistant })
        #expect(answer.stopped, "the answer was cut short and is kept as a stopped answer")
    }
}
