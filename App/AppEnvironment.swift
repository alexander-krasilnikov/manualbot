import Adapters
import Core
import Foundation
import Ports
import PortsTesting

enum AppEnvironmentError: LocalizedError {
    case manifestMissing

    var errorDescription: String? { "The model manifest is missing from the app bundle." }
}

/// Wires the real adapters together, or stubs them for UI tests.
///
/// UI tests launch with `-uiTestModelStub <scenario>` (fake downloads: `happy`, `llmFailsOnce`, `lowStorage`, `bundled`),
/// optionally `-uiTestSeed` (five sample documents already indexed, among them a photo and a PDF with a photo) and `-uiTestSlow` (answers stream slowly).
@MainActor
enum AppEnvironment {
    static func makeAppModel() throws -> AppModel {
        let arguments = ProcessInfo.processInfo.arguments
        let isStub = arguments.contains("-uiTestModelStub")
        // UI tests must not inherit (or leave behind) the remembered demo-mode choice of earlier launches.
        let demo = DemoSession(
            defaults: isStub ? (UserDefaults(suiteName: "uitest-\(UUID().uuidString)") ?? .standard) : .standard)
        if let flag = arguments.firstIndex(of: "-uiTestModelStub") {
            let scenario = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "happy"
            let models = ModelSetupViewModel(store: stubStore(scenario: scenario))
            var options = StubServiceFactory.Options()
            options.seedDocuments = arguments.contains("-uiTestSeed")
            options.slowAnswers = arguments.contains("-uiTestSlow")
            demo.xray.usesStubModels = true
            return AppModel(models: models, factory: StubServiceFactory(options: options, tracer: demo.tracer), demo: demo)
        }
        return try liveModel(demo: demo)
    }

    private static func liveModel(demo: DemoSession) throws -> AppModel {
        guard let url = Bundle.main.url(forResource: "ModelManifest", withExtension: "json") else {
            throw AppEnvironmentError.manifestMissing
        }
        let manifest = try ModelManifest.decode(from: Data(contentsOf: url))
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        // The embedding model ships inside the app; the language model is downloaded into Application Support.
        let files = FileModelFiles(
            root: support.appendingPathComponent("Models", isDirectory: true),
            bundleRoot: Bundle.main.resourceURL?.appendingPathComponent("BundledModels", isDirectory: true))
        let downloader = URLSessionModelDownloader.background(
            identifier: "com.manualbot.app.models",
            staging: support.appendingPathComponent("ModelStaging", isDirectory: true),
            resumeStore: support.appendingPathComponent("ModelResume", isDirectory: true))
        let store = ModelStore(manifest: manifest, downloader: downloader, files: files)
        let factory = LiveServiceFactory(
            manifest: manifest, files: files, applicationSupport: support, caches: caches, tracer: demo.tracer)
        return AppModel(models: ModelSetupViewModel(store: store), factory: factory, demo: demo)
    }

    private static func stubStore(scenario: String) -> ModelStore {
        let hash = String(repeating: "a", count: 64)
        let manifest = ModelManifest(models: [
            ModelSpec(id: "embeddinggemma-300m", version: "1", role: .embedder,
                      url: URL(string: "https://example.invalid/embed")!, bytes: 300_000_000, sha256: hash,
                      fileName: "embed.bin", displayName: "EmbeddingGemma 300M",
                      packaging: scenario == "bundled" ? .bundled : .file),
            ModelSpec(id: "gemma-4-e4b", version: "1", role: .generator,
                      url: URL(string: "https://example.invalid/llm")!, bytes: 3_000_000_000, sha256: hash,
                      fileName: "llm.bin", displayName: "Gemma 4 E4B"),
        ])
        let backend = FakeModelBackend()
        var free: Int64 = 100_000_000_000
        switch scenario {
        case "llmFailsOnce": backend.setBehavior(.failOnce("Connection lost."), for: "gemma-4-e4b")
        case "lowStorage": free = 1_000_000_000
        case "bundled": backend.markInstalled("embeddinggemma-300m")  // shipped inside the app
        default: break
        }
        backend.setFreeBytes(free)
        return ModelStore(manifest: manifest, downloader: backend, files: backend, safetyMargin: 0)
    }
}
