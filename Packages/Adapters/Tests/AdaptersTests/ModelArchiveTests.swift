import CryptoKit
import Core
import Foundation
import Ports
import Testing
@testable import Adapters

@Suite(.serialized) struct ModelArchiveTests {
    private let fx = Fixtures()

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func spec(_ zip: URL, url: URL = URL(string: "https://example.invalid/m.zip")!) throws -> ModelSpec {
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as! NSNumber
        return ModelSpec(id: "embed", version: "1", role: .embedder, url: url, bytes: size.int64Value,
                         sha256: try sha(zip), fileName: "encoder.mlmodelc", packaging: .zip)
    }

    private var modelEntries: [(path: String, data: Data)] {
        [("encoder.mlmodelc/coremldata.bin", Data("core".utf8)),
         ("encoder.mlmodelc/weights/weight.bin", Data(repeating: 7, count: 50_000)),
         ("tokenizer.json", Data("{}".utf8))]
    }

    @Test func aZippedModelIsDownloadedVerifiedAndUnpacked() async throws {
        let server = try TestHTTPServer(); try await server.start(); defer { server.stop() }
        let zip = fx.zip(modelEntries)
        server.serve("/m.zip", body: try Data(contentsOf: zip))
        let spec = try spec(zip, url: server.url("/m.zip"))
        let root = fx.url("root")
        let files = FileModelFiles(root: root)
        let downloader = URLSessionModelDownloader(configuration: .ephemeral, staging: fx.url("staging"), resumeStore: fx.url("resume"))
        defer { downloader.invalidate() }

        let store = ModelStore(manifest: ModelManifest(models: [spec, Self.stub(role: .generator)]),
                               downloader: Router(real: downloader, only: spec.id), files: files, safetyMargin: 0)
        try await store.start(only: [spec.id])

        #expect(await store.state(of: spec.id) == .installed)
        let loadable = files.installedURL(for: spec)
        #expect(loadable.lastPathComponent == "encoder.mlmodelc")
        #expect(try Data(contentsOf: loadable.appendingPathComponent("weights/weight.bin")).count == 50_000)
        #expect(FileManager.default.fileExists(atPath: loadable.deletingLastPathComponent().appendingPathComponent("tokenizer.json").path))
        #expect(try root.appendingPathComponent("embed").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        // A relaunch sees it as installed; the temporary archive and scratch space are gone.
        #expect(FileModelFiles(root: root).isInstalled(spec))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".unpack") }
        #expect(leftovers.isEmpty)
    }

    @Test func aModelWithoutTheInstallMarkerIsNotInstalled() throws {
        let zip = fx.zip(modelEntries)
        let spec = try spec(zip)
        let files = FileModelFiles(root: fx.url("root"))
        try files.install(zip, for: spec)
        #expect(files.isInstalled(spec))

        // An interrupted unpack would not have written the marker.
        try FileManager.default.removeItem(at: files.installedURL(for: spec).deletingLastPathComponent().appendingPathComponent(".installed"))
        #expect(!files.isInstalled(spec))
    }

    @Test func aZipSlipArchiveIsRejectedAndNothingIsWritten() throws {
        let zip = fx.zip([("../evil.txt", Data("pwned".utf8)), ("encoder.mlmodelc/coremldata.bin", Data("x".utf8))])
        let spec = try spec(zip)
        let root = fx.url("root")
        let files = FileModelFiles(root: root)

        #expect(throws: ModelInstallError.unsafeArchiveEntry("../evil.txt")) { try files.install(zip, for: spec) }
        #expect(!files.isInstalled(spec))
        #expect(!FileManager.default.fileExists(atPath: fx.directory.appendingPathComponent("evil.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evil.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("embed").path), "no version directory for a rejected model")
    }

    @Test func anAbsolutePathEntryIsRejected() throws {
        let zip = fx.zip([("/tmp/absolute-evil.txt", Data("x".utf8))])
        let files = FileModelFiles(root: fx.url("root"))
        #expect(throws: ModelInstallError.self) { try files.install(zip, for: try spec(zip)) }
    }

    @Test func anArchiveWithoutTheExpectedModelFails() throws {
        let zip = fx.zip([("tokenizer.json", Data("{}".utf8))])
        let files = FileModelFiles(root: fx.url("root"))
        #expect(throws: ModelInstallError.missingEntry("encoder.mlmodelc")) { try files.install(zip, for: try spec(zip)) }
    }

    @Test func aNonZipFileFails() throws {
        let junk = fx.write(Data("not a zip".utf8), as: "junk.zip")
        var spec = try spec(fx.zip(modelEntries))
        spec.sha256 = try sha(junk)
        #expect(throws: ModelInstallError.invalidArchive) { try FileModelFiles(root: fx.url("root")).install(junk, for: spec) }
    }

    @Test func reinstallingReplacesTheOldVersionDirectory() throws {
        let files = FileModelFiles(root: fx.url("root"))
        let first = fx.zip(modelEntries, name: "a.zip")
        try files.install(first, for: try spec(first))
        let second = fx.zip(modelEntries + [("extra.txt", Data("new".utf8))], name: "b.zip")
        let s2 = try spec(second)
        try files.install(second, for: s2)
        #expect(FileManager.default.fileExists(atPath: files.installedURL(for: s2).deletingLastPathComponent().appendingPathComponent("extra.txt").path))
        #expect(files.isInstalled(s2))
    }

    @Test func manifestDefaultsToSingleFileAndAcceptsZip() throws {
        let hex = String(repeating: "a", count: 64)
        func model(_ id: String, role: String, extra: String = "") -> String {
            "{\"id\":\"\(id)\",\"version\":\"1\",\"role\":\"\(role)\",\"url\":\"https://x.invalid/\(id)\",\"bytes\":10,\"sha256\":\"\(hex)\",\"fileName\":\"\(id)\"\(extra)}"
        }
        let json = "{\"models\":[\(model("e", role: "embedder", extra: ",\"packaging\":\"zip\"")),\(model("g", role: "generator"))]}"
        let manifest = try ModelManifest.decode(from: Data(json.utf8))
        #expect(manifest.spec(id: "e")?.packaging == .zip)
        #expect(manifest.spec(id: "g")?.packaging == .file)
    }

    // MARK: Helpers

    static func stub(role: ModelRole) -> ModelSpec {
        ModelSpec(id: "other", version: "1", role: role, url: URL(string: "https://example.invalid/o")!, bytes: 1,
                  sha256: String(repeating: "b", count: 64), fileName: "o.bin")
    }

    /// Forwards one model to the real downloader; anything else would be a test bug.
    struct Router: ModelDownloading {
        let real: any ModelDownloading
        let only: String
        func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
            precondition(spec.id == only)
            return try await real.download(spec, progress: progress)
        }
    }
}

@Suite struct BundledFileTests {
    private let fx = Fixtures()

    private func spec() -> ModelSpec {
        ModelSpec(id: "embed", version: "1", role: .embedder, url: URL(string: "https://example.com/src")!, bytes: 1,
                  sha256: String(repeating: "a", count: 64), fileName: "encoder.mlmodelc", packaging: .bundled)
    }

    private func bundle(with model: Bool) throws -> URL {
        let bundleRoot = fx.url("Resources/BundledModels")
        if model {
            let dir = bundleRoot.appendingPathComponent("embed/encoder.mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("coremldata.bin"))
        }
        return bundleRoot
    }

    @Test func aBundledModelIsFoundInsideTheAppResources() throws {
        let files = FileModelFiles(root: fx.url("Models"), bundleRoot: try bundle(with: true))
        #expect(files.isInstalled(spec()))
        #expect(files.installedURL(for: spec()).path.hasSuffix("BundledModels/embed/encoder.mlmodelc"))
    }

    @Test func aMissingBundledModelIsNotInstalled() throws {
        #expect(!FileModelFiles(root: fx.url("Models"), bundleRoot: try bundle(with: false)).isInstalled(spec()))
        #expect(!FileModelFiles(root: fx.url("Models"), bundleRoot: nil).isInstalled(spec()), "no bundle configured")
    }

    @Test func aBundledModelCannotBeInstalledOrRemoved() throws {
        let bundleRoot = try bundle(with: true)
        let files = FileModelFiles(root: fx.url("Models"), bundleRoot: bundleRoot)
        #expect(throws: ModelInstallError.bundledModel) { try files.install(fx.write(Data("z".utf8), as: "f.zip"), for: spec()) }
        files.uninstall(spec())
        #expect(files.isInstalled(spec()), "uninstalling must never delete part of the app bundle")
    }

    @Test func manifestAcceptsBundledPackaging() throws {
        let hex = String(repeating: "a", count: 64)
        let json = "{\"models\":[{\"id\":\"e\",\"version\":\"1\",\"role\":\"embedder\",\"url\":\"https://x.invalid/e\",\"bytes\":10,\"sha256\":\"\(hex)\",\"fileName\":\"e\",\"packaging\":\"bundled\"},{\"id\":\"g\",\"version\":\"1\",\"role\":\"generator\",\"url\":\"https://x.invalid/g\",\"bytes\":10,\"sha256\":\"\(hex)\",\"fileName\":\"g\"}]}"
        #expect(try ModelManifest.decode(from: Data(json.utf8)).spec(id: "e")?.packaging == .bundled)
    }
}
