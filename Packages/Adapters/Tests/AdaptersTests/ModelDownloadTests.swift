import CryptoKit
import Core
import Foundation
import Ports
import Testing
@testable import Adapters

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func payload(_ count: Int, seed: UInt8 = 7) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
}

/// A temp area plus a server, torn down after each test.
private final class DownloadFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
    let server: TestHTTPServer
    let downloader: URLSessionModelDownloader
    let files: FileModelFiles

    init(freeBytes: (@Sendable () throws -> Int64)? = nil) async throws {
        server = try TestHTTPServer()
        try await server.start()
        files = FileModelFiles(root: root.appendingPathComponent("Models"), availableBytesOverride: freeBytes)
        downloader = URLSessionModelDownloader(
            configuration: .ephemeral, staging: root.appendingPathComponent("staging"),
            resumeStore: root.appendingPathComponent("resume"))
    }

    func spec(_ id: String, role: ModelRole, path: String, data: Data, claimedHash: String? = nil) -> ModelSpec {
        ModelSpec(id: id, version: "1", role: role, url: server.url(path), bytes: Int64(data.count),
                  sha256: claimedHash ?? sha256Hex(data), fileName: "\(id).bin")
    }

    func tearDown() {
        server.stop()
        downloader.invalidate()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) struct ModelDownloadTests {
    @Test func downloadsVerifiesAndInstallsEveryModel() async throws {
        let f = try await DownloadFixture(); defer { f.tearDown() }
        let embed = payload(300_000, seed: 1), llm = payload(700_000, seed: 2)
        f.server.serve("/embed", body: embed)
        f.server.serve("/llm", body: llm)
        let manifest = ModelManifest(models: [
            f.spec("embed", role: .embedder, path: "/embed", data: embed),
            f.spec("llm", role: .generator, path: "/llm", data: llm),
        ])
        let store = ModelStore(manifest: manifest, downloader: f.downloader, files: f.files, safetyMargin: 0)
        try await store.start()

        #expect(await store.canChat)
        for spec in manifest.models {
            let installed = f.files.installedURL(for: spec)
            #expect(try Data(contentsOf: installed).count == Int(spec.bytes))
            #expect(try installed.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        // A relaunch recognizes the installed files without downloading again.
        let again = ModelStore(manifest: manifest, downloader: f.downloader, files: f.files, safetyMargin: 0)
        await again.refresh()
        #expect(await again.canChat)
    }

    @Test func interruptedDownloadResumesInsteadOfRestarting() async throws {
        let f = try await DownloadFixture(); defer { f.tearDown() }
        let data = payload(1_500_000, seed: 3)
        f.server.serve("/big", body: data, dropFirstResponseAfter: 600_000)
        let spec = f.spec("big", role: .embedder, path: "/big", data: data)

        // First attempt: the connection drops part-way.
        await #expect(throws: (any Error).self) { _ = try await f.downloader.download(spec) { _ in } }

        // Second attempt resumes with a Range request and ends with the complete, correct file.
        let file = try await f.downloader.download(spec) { _ in }
        let ranges = f.server.requests.compactMap(\.range)
        #expect(ranges.contains { $0.hasPrefix("bytes=") && $0 != "bytes=0-" }, "expected a resumed range request, got \(f.server.requests)")
        #expect(try Data(contentsOf: file) == data)
        #expect(try await f.files.sha256(of: file) == spec.sha256)
    }

    @Test func corruptedDownloadFailsAndLeavesNothingInstalled() async throws {
        let f = try await DownloadFixture(); defer { f.tearDown() }
        let good = payload(200_000, seed: 4)
        var tampered = good
        tampered[1_000] ^= 0xFF
        f.server.serve("/bad", body: tampered)
        let spec = f.spec("bad", role: .embedder, path: "/bad", data: good)  // manifest hash is of the good bytes
        let llm = payload(50_000, seed: 5)
        f.server.serve("/ok", body: llm)
        let manifest = ModelManifest(models: [spec, f.spec("ok", role: .generator, path: "/ok", data: llm)])

        let store = ModelStore(manifest: manifest, downloader: f.downloader, files: f.files, safetyMargin: 0)
        try await store.start()

        guard case .failed(let reason) = await store.state(of: "bad") else { Issue.record("expected failure"); return }
        #expect(reason.lowercased().contains("checksum"))
        #expect(!f.files.isInstalled(spec))
        #expect(!FileManager.default.fileExists(atPath: f.files.installedURL(for: spec).path))
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("staging").path)) ?? []
        #expect(staged.filter { $0.hasPrefix("bad-") }.isEmpty, "corrupt staged file should be deleted: \(staged)")
        #expect(await store.state(of: "ok") == .installed)
    }

    @Test func insufficientStorageStopsBeforeAnyRequest() async throws {
        let f = try await DownloadFixture(freeBytes: { 100_000 }); defer { f.tearDown() }
        let data = payload(400_000, seed: 6)
        f.server.serve("/m", body: data)
        let manifest = ModelManifest(models: [
            f.spec("m", role: .embedder, path: "/m", data: data),
            f.spec("n", role: .generator, path: "/m", data: data),
        ])
        let store = ModelStore(manifest: manifest, downloader: f.downloader, files: f.files, safetyMargin: 1_000)
        await #expect(throws: ModelStoreError.insufficientStorage(required: 801_000, available: 100_000)) {
            try await store.start()
        }
        #expect(f.server.requests.isEmpty)
        #expect(await store.snapshot().values.allSatisfy { $0 == .missing })
    }

    @Test func httpErrorFailsTheModelWithAReadableReason() async throws {
        let f = try await DownloadFixture(); defer { f.tearDown() }
        let data = payload(10_000)
        let embed = f.spec("gone", role: .embedder, path: "/nope", data: data)
        let llm = f.spec("llm", role: .generator, path: "/llm", data: data)
        f.server.serve("/llm", body: data)
        let store = ModelStore(manifest: ModelManifest(models: [embed, llm]), downloader: f.downloader, files: f.files, safetyMargin: 0)
        try await store.start()
        guard case .failed(let reason) = await store.state(of: "gone") else { Issue.record("expected failure"); return }
        #expect(reason.contains("404"))
    }
}
