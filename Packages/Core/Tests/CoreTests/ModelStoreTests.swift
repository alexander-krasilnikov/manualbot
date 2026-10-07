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
        #expect(backend.removedUnlisted == ["old-llm"])
        #expect(!backend.isInstalledID("old-llm"))
        #expect(await store.canChat, "the listed models stay installed")
        await store.refresh()
        #expect(backend.removedUnlisted == ["old-llm"], "nothing more to remove the second time")
    }
}
