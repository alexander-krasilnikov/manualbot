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

@Suite struct DownloadedModelFileTests {
    private let fx = Fixtures()

    private func spec(_ bytes: Int64) -> ModelSpec {
        ModelSpec(id: "embeddinggemma-2-text-vision-440m", version: "1", role: .embedder, url: URL(string: "https://example.com/src")!,
                  bytes: bytes, sha256: String(repeating: "a", count: 64), fileName: "embeddinggemma-2-text-vision-440m.litertlm")
    }

    @Test func aDownloadedModelIsInstalledByMovingItIntoItsVersionFolder() throws {
        let files = FileModelFiles(root: fx.url("Models"))
        let spec = spec(4)
        #expect(!files.isInstalled(spec))
        try files.install(fx.write(Data("abcd".utf8), as: "download.tmp"), for: spec)
        #expect(files.isInstalled(spec))
        #expect(files.installedURL(for: spec).path.hasSuffix("embeddinggemma-2-text-vision-440m/1/embeddinggemma-2-text-vision-440m.litertlm"))
        files.uninstall(spec)
        #expect(!files.isInstalled(spec))
    }

    @Test func aFileOfTheWrongSizeIsNotInstalled() throws {
        let files = FileModelFiles(root: fx.url("Models"))
        try files.install(fx.write(Data("abc".utf8), as: "short.tmp"), for: spec(4))
        #expect(!files.isInstalled(spec(4)), "a truncated file must not count")
    }

    @Test func aManifestThatNamesTheRemovedBundledPackagingIsRejected() {
        let hex = String(repeating: "a", count: 64)
        let json = "{\"models\":[{\"id\":\"e\",\"version\":\"1\",\"role\":\"embedder\",\"url\":\"https://x.invalid/e\",\"bytes\":10,\"sha256\":\"\(hex)\",\"fileName\":\"e\",\"packaging\":\"bundled\"},{\"id\":\"g\",\"version\":\"1\",\"role\":\"generator\",\"url\":\"https://x.invalid/g\",\"bytes\":10,\"sha256\":\"\(hex)\",\"fileName\":\"g\"}]}"
        #expect(throws: DecodingError.self) { try ModelManifest.decode(from: Data(json.utf8)) }
    }

    private func put(_ files: FileModelFiles, _ id: String, _ version: String, _ name: String = "model.litertlm") throws {
        let directory = files.root.appendingPathComponent(id).appendingPathComponent(version)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent(name))
    }

    @Test func modelFilesTheManifestNoLongerListsAreDeletedAndListedOnesKept() throws {
        let files = FileModelFiles(root: fx.url("Models"))
        let manifest = ModelManifest(models: [spec(1), ModelSpec(
            id: "gemma-4-e2b", version: "2", role: .generator, url: URL(string: "https://example.com/g")!, bytes: 1,
            sha256: String(repeating: "b", count: 64), fileName: "model.litertlm")])
        try put(files, "embeddinggemma-2-text-vision-440m", "1", "embeddinggemma-2-text-vision-440m.litertlm")   // listed
        try put(files, "gemma-4-e2b", "2")                                                                      // listed
        try put(files, "gemma-4-e4b", "1")                                                                      // an earlier language model, no longer listed
        try put(files, "gemma-4-e2b", "1")                                                                      // an older version of a listed model
        try put(files, "embeddinggemma-300m", "1")                                                              // the previous embedder
        try FileManager.default.createDirectory(at: files.root.appendingPathComponent(".unpack-running"), withIntermediateDirectories: true)

        let removed = files.removeUnlisted(keeping: manifest)
        #expect(removed == ["embeddinggemma-300m", "gemma-4-e2b", "gemma-4-e4b"])
        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: files.root.appendingPathComponent(path).path) }
        #expect(exists("embeddinggemma-2-text-vision-440m/1/embeddinggemma-2-text-vision-440m.litertlm"), "listed model kept")
        #expect(exists("gemma-4-e2b/2/model.litertlm"), "listed version kept")
        #expect(!exists("gemma-4-e2b/1"), "an older version of a listed model goes")
        #expect(!exists("gemma-4-e4b") && !exists("embeddinggemma-300m"), "unlisted models go")
        #expect(exists(".unpack-running"), "an unpacking in progress is not touched")
        #expect(files.removeUnlisted(keeping: manifest).isEmpty, "a second pass finds nothing")
    }

    @Test func aMissingModelsFolderIsNotAnError() {
        #expect(FileModelFiles(root: fx.url("Never-created")).removeUnlisted(keeping: ModelManifest(models: [])).isEmpty)
    }
}
