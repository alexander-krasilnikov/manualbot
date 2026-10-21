import Adapters
import Core
import Foundation
import Ports
import PortsTesting

enum AppEnvironmentError: LocalizedError {
    case manifestMissing
    case catalogMissing
    case manualCatalogMissing

    var errorDescription: String? {
        switch self {
        case .manifestMissing: "The model manifest is missing from the app bundle."
        case .catalogMissing: "The embedder catalog is missing from the app bundle."
        case .manualCatalogMissing: "The manual catalog is missing from the app bundle."
        }
    }
}

/// Wires the real adapters together, or stubs them for UI tests.
///
/// UI tests launch with `-uiTestModelStub <scenario>` (fake downloads: `happy`, `llmFailsOnce`, `lowStorage`),
/// optionally `-uiTestSeed` (five sample documents already indexed, among them a photo and a PDF with a photo) or
/// `-uiTestSeedDemo` (the two Couchbase PDFs that Reset demo imports), `-uiTestCatalogFailing <entry id>,<entry id>` (those
/// catalog entries cannot be downloaded: the publisher refuses), `-uiTestCatalogSlow` (catalog downloads take a few seconds,
/// so they can be cancelled; the downloads themselves are always a stub), `-uiTestPhoto sample` (the attach button attaches the
/// demo's sample photo instead of the X200 nameplate), `-uiTestSlow`
/// (answers stream slowly), `-uiTestSearch <scenario>` (what the Models page finds: `results`, the default, or `offline`)
/// and `-uiTestSync <scenario>` (what sync does: `off`, the default, `syncing`, `upToDate`, `paused` or `error`; any other
/// than `off` also fills in the sync settings and turns sync on; `live` runs the real replicator against `localhost:4984` as
/// the account named by `-uiTestSyncUser <name>`, `ipad1` by default). A stub launch never touches the real defaults or Keychain:
/// its catalog notices and answer style live in a throwaway suite.
@MainActor
enum AppEnvironment {
    static func makeAppModel() throws -> AppModel {
        let arguments = ProcessInfo.processInfo.arguments
        let demo = DemoSession()
        if arguments.contains("-uiTestModelStub") {
            let scenario = Self.value(of: "-uiTestModelStub", in: arguments) ?? "happy"
            let models = ModelSetupViewModel(store: stubStore(scenario: scenario))
            let failing = Set((Self.value(of: "-uiTestCatalogFailing", in: arguments) ?? "").split(separator: ",").map(String.init))
            let downloader = StubManualDownloader(failing: failing, slow: arguments.contains("-uiTestCatalogSlow"))
            // Notices already accepted are not carried from one launch to the next.
            let suite = "uitest-catalog-\(UUID().uuidString)"
            let catalogDefaults = UserDefaults(suiteName: suite) ?? .standard
            catalogDefaults.removePersistentDomain(forName: suite)
            var options = StubServiceFactory.Options()
            options.seedDocuments = arguments.contains("-uiTestSeed")
            options.seedDemoSamples = arguments.contains("-uiTestSeedDemo")
            options.attachesSamplePhoto = Self.value(of: "-uiTestPhoto", in: arguments) == "sample"
            options.slowAnswers = arguments.contains("-uiTestSlow")
            demo.xray.usesStubModels = true
            let search = Self.value(of: "-uiTestSearch", in: arguments) ?? "results"
            options.sync = StubServiceFactory.SyncScenario(rawValue: Self.value(of: "-uiTestSync", in: arguments) ?? "off") ?? .off
            return AppModel(
                models: models, factory: StubServiceFactory(options: options, tracer: demo.tracer),
                catalog: StubServiceFactory.catalog, finder: stubFinder(scenario: search), demo: demo,
                syncSettings: stubSyncSettings(options.sync, user: Self.value(of: "-uiTestSyncUser", in: arguments)),
                manualCatalog: try Self.manualCatalog(), manualDownloader: downloader, catalogDefaults: catalogDefaults,
                answerSettings: AnswerSettings(defaults: catalogDefaults))
        }
        return try liveModel(demo: demo)
    }

    /// The curated list of public PDFs that ships with the app.
    static func manualCatalog() throws -> ManualCatalog {
        guard let url = Bundle.main.url(forResource: "ManualCatalog", withExtension: "json") else {
            throw AppEnvironmentError.manualCatalogMissing
        }
        return try ManualCatalog.decode(from: Data(contentsOf: url))
    }

    /// The value after a launch flag, such as `happy` after `-uiTestModelStub`; `nil` when the flag is absent or last.
    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Sync settings of a stub launch: kept in a throwaway suite and in memory, and filled in unless the scenario is `off`.
    private static func stubSyncSettings(_ scenario: StubServiceFactory.SyncScenario, user: String? = nil) -> SyncSettings {
        let suite = "uitest-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let settings = SyncSettings(defaults: defaults, secrets: InMemorySecretStore())
        if scenario != .off {
            settings.address = "localhost:4984"
            settings.username = user ?? "ipad1"
            settings.password = scenario == .live ? "manualbot-ipad" : "secret"
            settings.isEnabled = true
        }
        return settings
    }

    private static func liveModel(demo: DemoSession) throws -> AppModel {
        guard let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") else {
            throw AppEnvironmentError.manifestMissing
        }
        let manifest = try ModelManifest.decode(from: Data(contentsOf: url))
        guard let catalogURL = Bundle.main.url(forResource: "EmbedderCatalog", withExtension: "json") else {
            throw AppEnvironmentError.catalogMissing
        }
        let catalog = try EmbedderCatalog.decode(from: Data(contentsOf: catalogURL))
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // Both models are downloaded into Application Support.
        let files = FileModelFiles(root: support.appendingPathComponent("Models", isDirectory: true))
        let downloader = URLSessionModelDownloader.background(
            identifier: "com.manualbot.app.models",
            staging: support.appendingPathComponent("ModelStaging", isDirectory: true),
            resumeStore: support.appendingPathComponent("ModelResume", isDirectory: true))
        // Every downloaded model is checked by the runtime before it is installed (model-catalog spec).
        let validator = LiteRTModelValidator(requiredContextTokens: LiteRTGenerator.defaultContextTokens, catalog: catalog)
        let store = ModelStore(manifest: manifest, downloader: downloader, files: files, validator: validator)
        let factory = LiveServiceFactory(files: files, applicationSupport: support, caches: caches, tracer: demo.tracer)
        // The Models page searches the public litert-community models, and reads the start of each file to judge it.
        let finder = ModelCandidateFinder(
            search: HuggingFaceModelSearch(), probe: RangeModelHeaderProbe(), runtimeVersion: LiteRTModelValidator.bundledRuntimeVersion)
        return AppModel(
            models: ModelSetupViewModel(store: store), factory: factory, catalog: catalog, finder: finder, demo: demo,
            manualCatalog: try manualCatalog(), manualDownloader: URLSessionManualDownloader())
    }

    /// What the Models page finds in UI tests: a language model that passes, a file that holds an embedding model, and one
    /// too large for the device. `offline` fails like a device with no connection.
    private static func stubFinder(scenario: String) -> ModelCandidateFinder {
        func model(_ id: String, _ title: String, bytes: Int64) -> ModelSpec {
            ModelSpec(
                id: id, version: "rev1", role: .generator, url: URL(string: "https://example.invalid/\(id).litertlm")!, bytes: bytes,
                sha256: String(repeating: "e", count: 64), fileName: "\(id).litertlm", displayName: title, licence: "mit",
                repository: URL(string: "https://example.invalid/\(id)"))
        }
        let small = model("stub-gemma-small", "Stub Gemma Small", bytes: 1_200_000_000)
        var embedderFile = model("stub-embedder-file", "Stub Embedder File", bytes: 300_000_000)
        embedderFile.role = .embedder
        embedderFile.sha256 = String(repeating: "d", count: 64)
        let huge = model("stub-gemma-huge", "Stub Gemma Huge", bytes: 40_000_000_000)
        let search = FakeModelSearch(results: [small, embedderFile, huge])
        if scenario == "offline" { search.fail(with: ModelSearchError.offline) }
        let probe = FakeHeaderProbe()
        probe.set(ModelHeader(kind: .llm, formatVersion: "1.5.0"), for: small.url)
        probe.set(ModelHeader(kind: .embedder, formatVersion: "1.7.0"), for: embedderFile.url)
        probe.set(ModelHeader(kind: .llm, formatVersion: "1.5.0"), for: huge.url)
        return ModelCandidateFinder(search: search, probe: probe, runtimeVersion: "0.18.0", physicalMemory: 8_000_000_000)
    }

    private static func stubStore(scenario: String) -> ModelStore {
        let hash = String(repeating: "a", count: 64)
        let manifest = ModelManifest(models: [
            ModelSpec(id: "embeddinggemma-2-text-vision-440m", version: "1", role: .embedder,
                      url: URL(string: "https://example.invalid/embed")!, bytes: 388_000_000, sha256: hash,
                      fileName: "embed.bin", displayName: "EmbeddingGemma 2", licence: "Apache License 2.0"),
            ModelSpec(id: "gemma-4-e2b", version: "1", role: .generator,
                      url: URL(string: "https://example.invalid/llm")!, bytes: 2_600_000_000, sha256: hash,
                      fileName: "llm.bin", displayName: "Gemma 4 E2B", licence: "Apache License 2.0"),
        ])
        let backend = FakeModelBackend()
        var free: Int64 = 100_000_000_000
        switch scenario {
        case "llmFailsOnce": backend.setBehavior(.failOnce("Connection lost."), for: "gemma-4-e2b")
        case "lowStorage": free = 1_000_000_000
        default: break
        }
        backend.setFreeBytes(free)
        // The stand-in validator reports a vector size for an embedding model, as the runtime does for a real file.
        return ModelStore(manifest: manifest, downloader: backend, files: backend, validator: FakeModelValidator(), safetyMargin: 0)
    }
}
