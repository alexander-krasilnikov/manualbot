import Foundation
import Ports
import PortsTesting
import Testing
@testable import Core

private let hexA = String(repeating: "a", count: 64)
private let hexB = String(repeating: "b", count: 64)

private func makeManifest() -> ModelManifest {
    ModelManifest(models: [
        ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://example.com/llm")!,
                  bytes: 3_000, sha256: hexB, fileName: "llm.bin"),
        ModelSpec(id: "embed", version: "1", role: .embedder, url: URL(string: "https://example.com/embed")!,
                  bytes: 300, sha256: hexA, fileName: "embed.mlmodelc"),
    ])
}

private func makeStore(margin: Int64 = 10) -> (ModelStore, FakeModelBackend) {
    let backend = FakeModelBackend()
    return (ModelStore(manifest: makeManifest(), downloader: backend, files: backend, safetyMargin: margin), backend)
}

@Suite struct ModelManifestTests {
    private func json(_ models: String) -> Data { Data("{\"models\": [\(models)]}".utf8) }
    private func model(_ id: String, role: String, sha: String = hexA, bytes: Int = 10) -> String {
        "{\"id\":\"\(id)\",\"version\":\"1\",\"role\":\"\(role)\",\"url\":\"https://example.com/\(id)\",\"bytes\":\(bytes),\"sha256\":\"\(sha)\",\"fileName\":\"\(id).bin\"}"
    }

    @Test func decodesAValidManifest() throws {
        let m = try ModelManifest.decode(from: json(model("e", role: "embedder") + "," + model("g", role: "generator")))
        #expect(m.models.count == 2)
        #expect(m.totalBytes == 20)
        #expect(m.spec(id: "g")?.role == .generator)
    }

    @Test func rejectsMalformedManifests() {
        #expect(throws: ManifestError.invalidChecksum("e")) {
            try ModelManifest.decode(from: json(model("e", role: "embedder", sha: "xyz") + "," + model("g", role: "generator")))
        }
        #expect(throws: ManifestError.missingRole(.generator)) {
            try ModelManifest.decode(from: json(model("e", role: "embedder")))
        }
        #expect(throws: ManifestError.duplicateModel("e")) {
            try ModelManifest.decode(from: json(model("e", role: "embedder") + "," + model("e", role: "generator")))
        }
        #expect(throws: ManifestError.invalidSize("e")) {
            try ModelManifest.decode(from: json(model("e", role: "embedder", bytes: 0) + "," + model("g", role: "generator")))
        }
    }
}

@Suite struct ModelStoreTests {
    @Test func startsMissing() async {
        let (store, _) = makeStore()
        let snapshot = await store.snapshot()
        #expect(snapshot == ["llm": .missing, "embed": .missing])
        #expect(await store.canImport == false)
        #expect(await store.canChat == false)
    }

    @Test func happyPathWalksThroughEveryState() async throws {
        let (store, backend) = makeStore()
        let stream = await store.updates(buffering: .unbounded)  // subscribe before starting so the first element is .missing
        let observer = Task { () -> [ModelState] in
            var seen: [ModelState] = []
            for await snapshot in stream {
                if let embed = snapshot["embed"], seen.last != embed { seen.append(embed) }
                if snapshot["llm"] == .installed { break }
            }
            return seen
        }
        try await store.start()
        let seen = await observer.value

        #expect(seen.first == .missing)
        #expect(seen.contains { if case .downloading = $0 { true } else { false } })
        #expect(seen.contains(.verifying))
        #expect(seen.last == .installed)
        #expect(await store.snapshot() == ["llm": .installed, "embed": .installed])
        #expect(backend.backupExcluded == ["llm", "embed"])
    }

    @Test func embedderDownloadsFirst() async throws {
        let (store, backend) = makeStore()
        try await store.start()
        #expect(backend.downloads == ["embed", "llm"])
    }

    @Test func checksumMismatchDiscardsTheFileAndFails() async throws {
        let (store, backend) = makeStore()
        backend.setBehavior(.corrupt, for: "embed")
        try await store.start()
        guard case .failed(let reason) = await store.state(of: "embed") else {
            Issue.record("expected failed"); return
        }
        #expect(reason.contains("corrupt"))
        #expect(backend.discarded.count == 1)
        #expect(!backend.isInstalledID("embed"))
        // The other model is unaffected.
        #expect(await store.state(of: "llm") == .installed)
    }

    @Test func downloadErrorFailsOnlyThatModelAndRetrySucceeds() async throws {
        let (store, backend) = makeStore()
        backend.setBehavior(.fail("network lost"), for: "llm")
        try await store.start()
        #expect(await store.state(of: "llm") == .failed("network lost"))
        #expect(await store.state(of: "embed") == .installed)

        backend.setBehavior(.succeed, for: "llm")
        try await store.retry("llm")
        #expect(await store.state(of: "llm") == .installed)
    }

    @Test func insufficientStorageBlocksStartWithoutChangingState() async throws {
        let (store, backend) = makeStore(margin: 100)
        backend.setFreeBytes(3_000)  // needs 3_300 + 100
        await #expect(throws: ModelStoreError.insufficientStorage(required: 3_400, available: 3_000)) {
            try await store.start()
        }
        #expect(await store.snapshot() == ["llm": .missing, "embed": .missing])
        #expect(backend.downloads.isEmpty)
    }

    @Test func storageRequirementOnlyCountsMissingModels() async throws {
        let (store, backend) = makeStore(margin: 10)
        backend.markInstalled("embed")
        await store.refresh()
        let req = try await store.storageRequirement()
        #expect(req.required == 3_010)
    }

    @Test func stagedReadinessEmbedderBeforeLLM() async throws {
        let (store, backend) = makeStore()
        backend.setBehavior(.fail("offline"), for: "llm")
        try await store.start()
        #expect(await store.canImport)
        #expect(await store.canChat == false)
        #expect(await store.missingModels().map(\.id) == ["llm"])
    }

    @Test func unknownModelIsRejected() async {
        let (store, _) = makeStore()
        await #expect(throws: ModelStoreError.unknownModel("nope")) { try await store.retry("nope") }
        await #expect(throws: ModelStoreError.unknownModel("nope")) { try await store.start(only: ["nope"]) }
    }

    @Test func cancellationReturnsTheModelToMissing() async throws {
        let (store, backend) = makeStore()
        backend.setBehavior(.suspend, for: "embed")
        let task = Task { try await store.start(only: ["embed"]) }
        while case .missing? = await store.state(of: "embed") { await Task.yield() }
        task.cancel()
        try await task.value
        #expect(await store.state(of: "embed") == .missing)
    }

    @Test func refreshMarksExistingFilesInstalled() async {
        let (store, backend) = makeStore()
        backend.markInstalled("embed")
        backend.markInstalled("llm")
        await store.refresh()
        #expect(await store.canChat)
    }
}

/// The embedding model is downloaded like the language model (model-provisioning spec).
@Suite struct DownloadedEmbedderTests {
    private func manifest() -> ModelManifest {
        ModelManifest(models: [
            ModelSpec(id: "llm", version: "1", role: .generator, url: URL(string: "https://example.com/llm")!,
                      bytes: 3_000, sha256: hexB, fileName: "llm.litertlm"),
            ModelSpec(id: "embed", version: "1", role: .embedder, url: URL(string: "https://example.com/embed")!,
                      bytes: 300, sha256: hexA, fileName: "embed.litertlm"),
        ])
    }

    @Test func aFreshInstallListsBothModelsAndDownloadsTheEmbedderFirst() async throws {
        let backend = FakeModelBackend()
        let store = ModelStore(manifest: manifest(), downloader: backend, files: backend, safetyMargin: 10)
        await store.refresh()
        #expect(Set(await store.missingModels().map(\.id)) == ["embed", "llm"])
        #expect(try await store.storageRequirement().required == 3_310, "both downloads plus the margin")
        #expect(await store.canImport == false, "nothing can be imported before the embedding model is installed")

        try await store.start()
        #expect(backend.downloads == ["embed", "llm"])
        #expect(await store.canImport)
        #expect(await store.canChat)
    }

    @Test func importIsAvailableOnceTheEmbedderIsInstalledEvenWhileTheLanguageModelIsStillDownloading() async throws {
        let backend = FakeModelBackend()
        backend.setBehavior(.suspend, for: "llm")
        let store = ModelStore(manifest: manifest(), downloader: backend, files: backend, safetyMargin: 10)
        let task = Task { try await store.start() }
        while await store.state(of: "embed") != .installed { try await Task.sleep(for: .milliseconds(5)) }

        #expect(await store.canImport, "import starts before the larger model has arrived")
        #expect(await store.canChat == false, "chat waits for the language model")
        task.cancel()
        _ = try? await task.value
    }

    @Test func anEmbedderThatDisappearedReturnsToSetupAndImportStopsUntilItIsBack() async throws {
        let backend = FakeModelBackend()
        let store = ModelStore(manifest: manifest(), downloader: backend, files: backend, safetyMargin: 10)
        try await store.start()
        #expect(await store.canImport)

        backend.uninstall(try #require(manifest().spec(id: "embed")))   // deleted outside the app
        await store.refresh()
        #expect(await store.state(of: "embed") == .missing)
        #expect(await store.canImport == false)
        #expect(await store.state(of: "llm") == .installed, "the other model is untouched")

        try await store.start()
        #expect(await store.canImport)
    }

    @Test func refreshDeletesModelsTheManifestNoLongerListsAndKeepsTheListedOnes() async {
        let backend = FakeModelBackend()
        backend.markInstalled("embed"); backend.markInstalled("llm"); backend.markInstalled("old-llm")
        let store = ModelStore(manifest: manifest(), downloader: backend, files: backend, safetyMargin: 10)
        await store.refresh()
        #expect(backend.removedAbandoned == ["old-llm"])
        #expect(!backend.isInstalledID("old-llm"))
        #expect(await store.canChat, "the listed models stay installed")
        await store.refresh()
        #expect(backend.removedAbandoned == ["old-llm"], "nothing more to remove the second time")
    }
}

/// Models installed from the Models page sit next to the defaults and are used only once activated (model-catalog spec).
@Suite struct ModelSelectionTests {
    private let alt = ModelSpec(id: "gemma-alt", version: "1", role: .generator, url: URL(string: "https://example.com/alt")!,
                                bytes: 500, sha256: hexA, fileName: "alt.litertlm")

    private func makeStoreWithDefaults() async throws -> (ModelStore, FakeModelBackend) {
        let (store, backend) = makeStore(margin: 0)
        try await store.start()
        return (store, backend)
    }

    @Test func aModelInstalledFromSearchStaysInactiveUntilActivated() async throws {
        let (store, backend) = try await makeStoreWithDefaults()
        try await store.install(ModelRecord(spec: alt, source: .search, chosenByUser: true))
        #expect(backend.downloads.last == "gemma-alt")
        #expect(await store.state(of: "gemma-alt") == .installed)
        #expect(await store.activeSpec(for: .generator)?.id == "llm", "installing does not switch the model in use")
        #expect(await store.installedModels().map(\.spec.id).contains("gemma-alt"))

        try await store.activate("gemma-alt")
        #expect(await store.activeSpec(for: .generator)?.id == "gemma-alt")
    }

    @Test func theChoiceSurvivesANewStoreAndReadinessFollowsIt() async throws {
        let (store, backend) = try await makeStoreWithDefaults()
        try await store.install(ModelRecord(spec: alt, source: .search, chosenByUser: true))
        try await store.activate("gemma-alt")

        let relaunched = ModelStore(manifest: makeManifest(), downloader: backend, files: backend, safetyMargin: 0)
        await relaunched.refresh()
        #expect(await relaunched.activeSpec(for: .generator)?.id == "gemma-alt")
        #expect(await relaunched.canChat)
        #expect(await relaunched.installedModels().map(\.spec.id).sorted() == ["embed", "gemma-alt", "llm"])
    }

    @Test func activatingNeedsAKnownModelAndTheModelInUseCannotBeDeleted() async throws {
        let (store, backend) = try await makeStoreWithDefaults()
        await #expect(throws: ModelStoreError.unknownModel("gemma-alt")) { try await store.activate("gemma-alt") }
        await #expect(throws: ModelStoreError.activeModel("llm")) { try await store.delete("llm") }

        try await store.install(ModelRecord(spec: alt, source: .search, chosenByUser: true))
        try await store.activate("gemma-alt")
        try await store.delete("llm")   // no longer in use, so it can go
        #expect(await store.state(of: "llm") == .missing)
        #expect(!backend.isInstalledID("llm"))
        #expect(await store.canChat, "the model in use is still installed")
    }

    @Test func theDefaultIsInUseEvenBeforeItIsInstalled() async {
        let (store, _) = makeStore()
        #expect(await store.activeSpec(for: .generator)?.id == "llm")
        #expect(await store.activeSpec(for: .embedder)?.id == "embed")
        #expect(await store.isInstalled(.generator) == false)
    }

    @Test func aMissingActiveModelReturnsToSetupWithoutActivatingAnotherInstalledModel() async throws {
        let (store, backend) = try await makeStoreWithDefaults()
        try await store.install(ModelRecord(spec: alt, source: .search, chosenByUser: true))
        try await store.activate("gemma-alt")

        backend.uninstall(alt)   // deleted outside the app
        await store.refresh()
        #expect(await store.state(of: "gemma-alt") == .missing)
        #expect(await store.activeSpec(for: .generator)?.id == "gemma-alt", "no silent switch to the default")
        #expect(await store.canChat == false)
        #expect(await store.missingModels().map(\.id) == ["gemma-alt"])
        #expect(await store.state(of: "llm") == .installed, "the default stays installed and is not used")
    }

    @Test func installsAreRecordedAndModelsInstalledBeforeRecordsReportAsManifestDefaults() async throws {
        let backend = FakeModelBackend()
        backend.markInstalled("llm")   // installed by an earlier build, with no record
        let store = ModelStore(manifest: makeManifest(), downloader: backend, files: backend, safetyMargin: 0)
        await store.refresh()
        let installed = await store.installedModels()
        let llm = try #require(installed.first { $0.spec.id == "llm" })
        #expect(llm.source == .manifest)
        #expect(llm.chosenByUser == false)
        #expect(backend.storedRecords.map(\.spec.id) == ["llm"], "the record is written on refresh")

        try await store.start()
        #expect(backend.storedRecords.map(\.spec.id).sorted() == ["embed", "llm"])
        #expect(backend.storedRecords.allSatisfy { $0.source == .manifest && !$0.chosenByUser })
    }

    @Test func installingFromSearchFailsOnAChecksumMismatchAndNothingIsActivated() async throws {
        let (store, backend) = try await makeStoreWithDefaults()
        backend.setBehavior(.corrupt, for: "gemma-alt")
        try await store.install(ModelRecord(spec: alt, source: .search, chosenByUser: true))
        #expect(await store.state(of: "gemma-alt") == .failed("Checksum mismatch: the downloaded file is corrupt."))
        #expect(!backend.isInstalledID("gemma-alt"))
        #expect(await store.activeSpec(for: .generator)?.id == "llm")
    }

    @Test func refreshKeepsWhatTheUserChoseAndDeletesWhatNothingKeepsAnyMore() async throws {
        let backend = FakeModelBackend()
        let replacedNeverChosen = ModelSpec(id: "old-llm", version: "1", role: .generator, url: URL(string: "https://example.com/o")!,
                                            bytes: 100, sha256: hexA, fileName: "old.litertlm")
        let replacedAndActive = ModelSpec(id: "older-llm", version: "1", role: .generator, url: URL(string: "https://example.com/p")!,
                                          bytes: 100, sha256: hexA, fileName: "older.litertlm")
        backend.markInstalled("llm"); backend.markInstalled("embed")
        for spec in [replacedNeverChosen, replacedAndActive, alt] { backend.markInstalled(spec.id) }
        try backend.writeRecord(ModelRecord(spec: replacedNeverChosen, source: .manifest, chosenByUser: false))
        try backend.writeRecord(ModelRecord(spec: replacedAndActive, source: .manifest, chosenByUser: true))
        try backend.writeRecord(ModelRecord(spec: alt, source: .search, chosenByUser: true))
        try backend.saveActive(ActiveModels(generator: "older-llm"))

        let store = ModelStore(manifest: makeManifest(), downloader: backend, files: backend, safetyMargin: 0)
        await store.refresh()
        #expect(backend.removedAbandoned == ["old-llm"], "a replaced default the user never chose is deleted")
        #expect(Set(backend.storedRecords.map(\.spec.id)) == ["llm", "embed", "older-llm", "gemma-alt"])
        #expect(await store.canChat, "the replaced default the user activated is the model in use and stays")
    }
}

@Suite struct ModelValidationTests {
    @Test func aRejectedFileIsDiscardedAndTheReasonIsShown() async throws {
        let backend = FakeModelBackend()
        let validator = FakeModelValidator()
        validator.reject("llm", with: .needsNewerRuntime)
        let store = ModelStore(manifest: makeManifest(), downloader: backend, files: backend, validator: validator, safetyMargin: 0)
        try await store.start()
        let reason = try #require(ModelValidationError.needsNewerRuntime.errorDescription)
        #expect(await store.state(of: "llm") == .failed(reason))
        #expect(backend.discarded.count == 1)
        #expect(!backend.isInstalledID("llm"))
        #expect(await store.state(of: "embed") == .installed, "the other model is unaffected")
        #expect(await store.canChat == false)
    }
}

@Suite struct ModelFitTests {
    @Test func aModelFitsWhenItTakesLessThanTheShareOfMemory() {
        let eightGB: UInt64 = 8_000_000_000
        #expect(ModelFit.fits(bytes: 2_600_000_000, physicalMemory: eightGB))
        #expect(!ModelFit.fits(bytes: 7_000_000_000, physicalMemory: eightGB))
    }
}
