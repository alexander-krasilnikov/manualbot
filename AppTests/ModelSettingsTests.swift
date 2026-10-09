import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

@MainActor @Suite(.serialized) struct ModelSettingsTests {
    private let embedderA = StubServiceFactory.catalog.embedders[0]
    private let embedderB = StubServiceFactory.catalog.embedders[1]
    private let llm = ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://x.invalid/l")!, bytes: 3_000,
                                sha256: String(repeating: "c", count: 64), fileName: "l", displayName: "LLM", licence: "Apache License 2.0")

    /// A switch that only records what it was asked to do, with a cost it was told to report.
    private final class FakeSwitching: ModelSwitching {
        var cost = AppModel.SwitchCost(role: .embedder, documentsToReindex: 5, supportsPhotos: false)
        var switched: [String] = []
        var failure: (any Error)?

        func switchCost(to id: String) async -> AppModel.SwitchCost? { cost }
        func switchModel(to id: String) async throws {
            if let failure { throw failure }
            switched.append(id)
        }
    }

    private struct Rig {
        let model: ModelSettingsViewModel
        let store: ModelStore
        let backend: FakeModelBackend
        let switching: FakeSwitching
        let search: FakeModelSearch
        let probe: FakeHeaderProbe
        let tracer: RecordingTracer
    }

    private func rig(searchResults: [ModelSpec] = [], validator: (any ModelValidating)? = nil) async throws -> Rig {
        let backend = FakeModelBackend()
        let store = ModelStore(manifest: ModelManifest(models: [embedderA.spec, llm]), downloader: backend, files: backend, validator: validator, safetyMargin: 0)
        try await store.start()
        let switching = FakeSwitching()
        let search = FakeModelSearch(results: searchResults)
        let probe = FakeHeaderProbe()
        let finder = ModelCandidateFinder(search: search, probe: probe, runtimeVersion: "0.18.0", physicalMemory: 8_000_000_000)
        let tracer = RecordingTracer()
        let model = ModelSettingsViewModel(
            store: store, catalog: StubServiceFactory.catalog, finder: finder, switching: switching, tracer: tracer)
        await model.reload()
        return Rig(model: model, store: store, backend: backend, switching: switching, search: search, probe: probe, tracer: tracer)
    }

    private func embedderResult(_ id: String) -> ModelSpec {
        var spec = result(id)
        spec.role = .embedder
        spec.sha256 = String(repeating: "f", count: 64)
        return spec
    }

    private func result(_ id: String, bytes: Int64 = 1_000_000_000) -> ModelSpec {
        ModelSpec(id: id, version: "rev", role: .generator, url: URL(string: "https://example.invalid/\(id).litertlm")!, bytes: bytes,
                  sha256: String(repeating: "e", count: 64), fileName: "\(id).litertlm", displayName: id, licence: "mit")
    }

    // MARK: What is listed

    @Test func theModelsInUseAreListedAndMarked() async throws {
        let rig = try await rig()
        #expect(rig.model.installed.map(\.id) == [embedderA.spec.id, "llm"])
        #expect(rig.model.installed.allSatisfy { $0.isActive })
        #expect(rig.model.installed.first { $0.id == "llm" }?.licence == "Apache License 2.0")
    }

    @Test func catalogEmbeddersThatAreNotInstalledAreOfferedWithWhetherTheyAnalyzePhotos() async throws {
        let rig = try await rig()
        #expect(rig.model.availableEmbedders.map(\.id) == [embedderB.spec.id], "the embedder in use is installed, so not offered again")
        #expect(rig.model.availableEmbedders.first?.supportsPhotos == false)
        #expect(rig.model.availableEmbedders.first?.canDownload == true)
    }

    @Test func anInstalledModelIsNotInUseUntilItIsActivated() async throws {
        let rig = try await rig()
        try await rig.store.install(ModelRecord(spec: embedderB.spec, source: .catalog, chosenByUser: true))
        await rig.model.reload()
        #expect(rig.model.installed.first { $0.id == embedderB.spec.id }?.isActive == false)
        #expect(rig.model.availableEmbedders.isEmpty)
    }

    @Test func theRealManifestAndCatalogOfferTheOtherEmbeddersOnceTheDefaultsAreInstalled() async throws {
        func bundled(_ name: String) throws -> Data {
            let url = try #require(Bundle(for: SettingsBundleToken.self).url(forResource: name, withExtension: "json")
                ?? Bundle.main.url(forResource: name, withExtension: "json"))
            return try Data(contentsOf: url)
        }
        let manifest = try ModelManifest.decode(from: bundled("ModelManifest"))
        let catalog = try EmbedderCatalog.decode(from: bundled("EmbedderCatalog"))
        let backend = FakeModelBackend()
        let store = ModelStore(manifest: manifest, downloader: backend, files: backend, safetyMargin: 0)
        try await store.start()
        let finder = ModelCandidateFinder(search: FakeModelSearch(), probe: FakeHeaderProbe(), runtimeVersion: "0.18.0")
        let model = ModelSettingsViewModel(store: store, catalog: catalog, finder: finder, switching: FakeSwitching())
        await model.reload()

        #expect(model.installed.map(\.id) == ["embeddinggemma-2-text-vision-440m", "gemma-4-e2b"])
        #expect(model.availableEmbedders.map(\.id) == ["embeddinggemma-2-text-270m", "embeddinggemma-2-740m"])
        #expect(model.availableEmbedders.map(\.canDownload) == [true, true])
    }

    // MARK: Changing the model in use

    @Test func activatingAsksFirstAndNamesTheCostWithoutChangingAnything() async throws {
        let rig = try await rig()
        try await rig.store.install(ModelRecord(spec: embedderB.spec, source: .catalog, chosenByUser: true))
        await rig.model.reload()

        await rig.model.requestActivation(of: embedderB.spec.id)

        let confirmation = try #require(rig.model.confirmation)
        #expect(confirmation.title == "Stub Text Embedder")
        #expect(confirmation.message.contains("5 documents will be re-indexed"))
        #expect(confirmation.message.contains("keywords only"))
        #expect(confirmation.message.contains("cannot analyze photos"))
        #expect(rig.switching.switched.isEmpty, "nothing changes until the user confirms")
        #expect(await rig.store.activeSpec(for: .embedder)?.id == embedderA.spec.id)
    }

    @Test func dismissingTheConfirmationChangesNothing() async throws {
        let rig = try await rig()
        try await rig.store.install(ModelRecord(spec: embedderB.spec, source: .catalog, chosenByUser: true))
        await rig.model.reload()
        await rig.model.requestActivation(of: embedderB.spec.id)

        rig.model.dismissConfirmation()
        await rig.model.confirm()   // nothing is pending, so confirming does nothing either

        #expect(rig.model.confirmation == nil)
        #expect(rig.switching.switched.isEmpty)
        #expect(await rig.store.activeSpec(for: .embedder)?.id == embedderA.spec.id)
    }

    @Test func confirmingStillSwitchesWhenTheDialogClearedThePendingConfirmationFirst() async throws {
        // Tapping a button of the dialog dismisses it, which clears the pending confirmation before the switch starts.
        let rig = try await rig()
        try await rig.store.install(ModelRecord(spec: embedderB.spec, source: .catalog, chosenByUser: true))
        await rig.model.reload()
        await rig.model.requestActivation(of: embedderB.spec.id)
        let shown = try #require(rig.model.confirmation)
        rig.model.dismissConfirmation()

        await rig.model.confirm(shown)

        #expect(rig.switching.switched == [embedderB.spec.id])
    }

    @Test func confirmingSwitchesAndAFailureIsReportedWithThePreviousModelBack() async throws {
        let rig = try await rig()
        try await rig.store.install(ModelRecord(spec: embedderB.spec, source: .catalog, chosenByUser: true))
        await rig.model.reload()
        await rig.model.requestActivation(of: embedderB.spec.id)
        await rig.model.confirm()
        #expect(rig.switching.switched == [embedderB.spec.id])
        #expect(rig.model.isSwitching == false && rig.model.errorMessage == nil)

        rig.switching.failure = StubServiceFactory.CannotLoad(title: "Stub Text Embedder")
        await rig.model.requestActivation(of: embedderB.spec.id)
        await rig.model.confirm()
        let message = try #require(rig.model.errorMessage)
        #expect(message.contains("could not be loaded") && message.contains("previous model is back in use"))
    }

    @Test func theMessageForALanguageModelSaysTheAnswerWillStop() {
        let message = ModelSettingsViewModel.message(for: .init(role: .generator, documentsToReindex: 0, supportsPhotos: true))
        #expect(message == "An answer that is being written will stop.")
    }

    @Test func theMessageForAnEmbedderWithPhotosSaysPhotoSearchPausesUntilTheReindexFinishes() {
        let message = ModelSettingsViewModel.message(for: .init(role: .embedder, documentsToReindex: 1, supportsPhotos: true))
        #expect(message.contains("1 document will be re-indexed") && message.contains("until the re-index finishes"))
    }

    // MARK: Deleting

    @Test func theModelInUseCannotBeDeleted() async throws {
        let rig = try await rig()
        await rig.model.delete("llm")
        #expect(rig.model.errorMessage?.contains("in use") == true)
        #expect(rig.model.installed.contains { $0.id == "llm" })
    }

    @Test func aModelNotInUseCanBeDeletedAndIsOfferedAgain() async throws {
        let rig = try await rig()
        try await rig.store.install(ModelRecord(spec: embedderB.spec, source: .catalog, chosenByUser: true))
        await rig.model.reload()
        await rig.model.delete(embedderB.spec.id)
        #expect(rig.model.errorMessage == nil)
        #expect(!rig.model.installed.contains { $0.id == embedderB.spec.id })
        #expect(rig.model.availableEmbedders.map(\.id) == [embedderB.spec.id])
    }

    // MARK: Searching and downloading

    @Test func aSearchListsModelsOfBothKindsWithWhatIsKnownBeforeDownloading() async throws {
        let small = result("small"), embedder = result("embedder"), huge = result("huge", bytes: 40_000_000_000)
        let rig = try await rig(searchResults: [small, embedder, huge])
        rig.probe.set(ModelHeader(kind: .llm, formatVersion: "1.5.0"), for: small.url)
        rig.probe.set(ModelHeader(kind: .embedder, formatVersion: "1.7.0"), for: embedder.url)
        rig.model.query = "gemma"

        await rig.model.search()

        #expect(rig.model.searchState == .results)
        #expect(rig.model.results.map(\.id) == ["small", "embedder", "huge"])
        #expect(rig.model.results.map { $0.verdict?.label } == ["Checked after download", "Checked after download", "Too large for this iPad"])
        #expect(rig.model.results.map(\.canDownload) == [true, true, false], "a model the checks ruled out cannot be downloaded")
        #expect(rig.model.results.map(\.isEmbedder) == [false, true, false])
        #expect(rig.model.results.map(\.isUntestedEmbedder) == [false, true, false], "an embedding model outside the built-in list is untested")
        #expect(rig.search.queries == ["gemma"])
    }

    @Test func aFileOfAnUnknownKindCannotBeDownloaded() async throws {
        let odd = result("odd")
        let rig = try await rig(searchResults: [odd])
        rig.probe.set(ModelHeader(kind: .unknown, formatVersion: "1.5.0"), for: odd.url)
        rig.model.query = "odd"
        await rig.model.search()
        #expect(rig.model.results.first?.verdict?.label == "Unknown kind of model")
        #expect(rig.model.results.first?.canDownload == false)
    }

    @Test func aSearchResultThatIsACatalogFileInstallsAsTheTestedEntry() async throws {
        var same = embedderB.spec
        same.id = "found-by-search"
        let rig = try await rig(searchResults: [same])
        rig.probe.set(ModelHeader(kind: .embedder, formatVersion: "1.7.0"), for: same.url)
        rig.model.query = "embed"
        await rig.model.search()
        let row = try #require(rig.model.results.first)
        #expect(row.isUntestedEmbedder == false)

        await rig.model.download(row)

        let installed = try #require(rig.model.installed.first { $0.id == embedderB.spec.id })
        #expect(installed.isUntested == false)
        #expect(await rig.store.record(for: embedderB.spec.id)?.source == .catalog)
    }

    @Test func anEmbeddingModelFoundBySearchInstallsInactiveAndUntested() async throws {
        let found = embedderResult("found-embedder")
        let rig = try await rig(searchResults: [found], validator: FakeModelValidator())
        rig.probe.set(ModelHeader(kind: .embedder, formatVersion: "1.7.0"), for: found.url)
        rig.model.query = "embed"
        await rig.model.search()

        await rig.model.download(try #require(rig.model.results.first))

        let row = try #require(rig.model.installed.first { $0.id == "found-embedder" })
        #expect(row.role == .embedder && row.isActive == false && row.isUntested)
        let record = try #require(await rig.store.record(for: "found-embedder"))
        #expect(record.source == .search)
        #expect(record.embedding?.dimension == 768, "what the runtime read from the file is kept")
        #expect(await rig.store.activeSpec(for: .embedder)?.id == embedderA.spec.id)
    }

    @Test func theConfirmationForAnUntestedEmbedderSaysSearchQualityIsUnknown() async throws {
        let rig = try await rig()
        try await rig.store.install(ModelRecord(spec: embedderB.spec, source: .catalog, chosenByUser: true))
        await rig.model.reload()
        rig.switching.cost = AppModel.SwitchCost(role: .embedder, documentsToReindex: 5, supportsPhotos: true, untested: true)
        await rig.model.requestActivation(of: embedderB.spec.id)
        let message = try #require(rig.model.confirmation?.message)
        #expect(message.contains("has not been tested"))
        #expect(message.contains("5 documents"))
    }

    @Test func anOfflineSearchSaysSoAndLeavesTheInstalledModelsAlone() async throws {
        let rig = try await rig()
        rig.search.fail(with: ModelSearchError.offline)
        rig.model.query = "gemma"
        await rig.model.search()
        #expect(rig.model.searchState == .offline)
        #expect(rig.model.results.isEmpty)
        #expect(rig.model.installed.count == 2)
    }

    @Test func aBlankSearchDoesNothing() async throws {
        let rig = try await rig()
        rig.model.query = "   "
        await rig.model.search()
        #expect(rig.model.searchState == .idle)
        #expect(rig.search.queries.isEmpty)
    }

    @Test func downloadingAResultInstallsItInactiveWithItsLicence() async throws {
        let small = result("small")
        let rig = try await rig(searchResults: [small])
        rig.probe.set(ModelHeader(kind: .llm, formatVersion: "1.5.0"), for: small.url)
        rig.model.query = "small"
        await rig.model.search()

        await rig.model.download(try #require(rig.model.results.first))

        let row = try #require(rig.model.installed.first { $0.id == "small" })
        #expect(row.isActive == false && row.licence == "mit")
        #expect(rig.model.results.first?.state == .installed)
        #expect(await rig.store.activeSpec(for: .generator)?.id == "llm", "downloading does not switch the model in use")
    }

    @Test func notEnoughSpaceIsSaidAndNothingIsDownloaded() async throws {
        let big = result("big", bytes: 2_000_000_000)
        let rig = try await rig(searchResults: [big])
        rig.backend.setFreeBytes(1_000_000_000)
        rig.probe.set(ModelHeader(kind: .llm, formatVersion: "1.5.0"), for: big.url)
        rig.model.query = "big"
        await rig.model.search()
        await rig.model.download(try #require(rig.model.results.first))
        #expect(rig.model.errorMessage?.contains("free up") == true)
        #expect(!rig.model.installed.contains { $0.id == "big" })
    }

    // MARK: Network use is labelled (design D10)

    @Test func aSearchAndADownloadAreEachRecordedAsALabelledRequest() async throws {
        let small = result("small")
        let rig = try await rig(searchResults: [small])
        rig.probe.set(ModelHeader(kind: .llm, formatVersion: "1.5.0"), for: small.url)
        rig.model.query = "gemma"
        await rig.model.search()
        await rig.model.download(try #require(rig.model.results.first))

        let requests = rig.tracer.events.compactMap { event -> (TraceOperation.Kind?, ModelRequestPurpose, String, String)? in
            guard case .modelRequest(let purpose, let host, let subject) = event.kind else { return nil }
            return (event.operation?.kind, purpose, host, subject)
        }
        #expect(requests.count == 2)
        #expect(requests[0] == (.modelSearch, .search, "huggingface.co", "gemma"))
        #expect(requests[1] == (.modelDownload, .download, "example.invalid", "small"))
    }

    @Test func importingAndAskingRecordNoModelRequestAtAll() async throws {
        // Core use of the app, on the stand-in services with a recording tracer: nothing reaches a model repository.
        let tracer = RecordingTracer()
        let backend = FakeModelBackend()
        let store = ModelStore(manifest: ModelManifest(models: [embedderA.spec, llm]), downloader: backend, files: backend, safetyMargin: 0)
        let models = ModelSetupViewModel(store: store)
        let app = AppModel(models: models, factory: StubServiceFactory(options: .init(seedDocuments: true), tracer: tracer), catalog: StubServiceFactory.catalog)
        let run = Task { await app.run() }
        defer { run.cancel() }
        await models.start()
        let deadline = ContinuousClock.now + .seconds(30)
        while app.preparation != .ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(app.preparation == .ready)
        let observer = Task { await app.library?.observe() }
        defer { observer.cancel() }
        while app.library?.items.allSatisfy({ $0.status == .ready }) != true, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let chat = try #require(app.chat)
        chat.updateDocuments(try #require(app.library).items)
        chat.draft = "How do I reset the X200 to factory defaults?"
        await chat.send()

        #expect(tracer.events.count > 10, "the tracer saw the imports and the question")
        #expect(!tracer.kinds.contains { if case .modelRequest = $0 { true } else { false } })
    }
}

private final class SettingsBundleToken {}
