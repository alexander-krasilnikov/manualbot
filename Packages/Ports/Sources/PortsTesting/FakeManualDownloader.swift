import CryptoKit
import Foundation
import Ports
import Synchronization

/// Stands in for the catalog downloader: writes a small real file named `<entry id>.pdf`, so callers can check that they
/// remove it, and fails or waits as told, per entry.
public final class FakeManualDownloader: ManualDownloading {
    public enum Behavior: Sendable {
        /// Completes with a file whose checksum equals the entry's recorded one.
        case succeed
        /// Completes with a file whose checksum differs from the entry's, as if the publisher had updated it.
        case updated
        case fail(ManualDownloadError)
        /// Reports progress up to the halfway mark, then throws `error` (the connection dropped).
        case failAfterProgress(ManualDownloadError)
        /// Reports progress, then never completes until the task is cancelled.
        case suspend
    }

    private struct State {
        var behavior: [String: Behavior] = [:]
        var fallback: Behavior = .succeed
        var downloads: [String] = []
        var files: [URL] = []
        var cancelled: [String] = []
    }
    private let state = Mutex(State())

    public init() {}

    // Configuration
    public func setBehavior(_ behavior: Behavior, for entryID: String) { state.withLock { $0.behavior[entryID] = behavior } }
    public func setDefaultBehavior(_ behavior: Behavior) { state.withLock { $0.fallback = behavior } }

    // Observation
    /// The entries it was asked to download, in order.
    public var downloads: [String] { state.withLock { $0.downloads } }
    /// Every temporary file it wrote, including those the caller has removed since.
    public var writtenFiles: [URL] { state.withLock { $0.files } }
    /// The entries whose download was cancelled.
    public var cancelled: [String] { state.withLock { $0.cancelled } }

    public func download(_ entry: ManualCatalogEntry, progress: @escaping @Sendable (Double) -> Void) async throws -> ManualDownload {
        let behavior = state.withLock { s -> Behavior in
            s.downloads.append(entry.id)
            return s.behavior[entry.id] ?? s.fallback
        }
        switch behavior {
        case .fail(let error):
            throw error
        case .failAfterProgress(let error):
            progress(0.25)
            await Task.yield()
            progress(0.5)
            throw error
        case .suspend:
            progress(0.1)
            do {
                while true { try await Task.sleep(for: .milliseconds(10)) }
            } catch {
                state.withLock { $0.cancelled.append(entry.id) }
                throw error
            }
        case .succeed, .updated:
            for step in 1...4 {
                try Task.checkCancellation()
                progress(Double(step) / 4)
                await Task.yield()
            }
            var content = Data("%PDF-1.4\n% fake catalog download for \(entry.id)\n".utf8)
            if case .updated = behavior { content.append(Data("% revised by the publisher\n".utf8)) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(entry.id).pdf")
            try content.write(to: file)
            state.withLock { $0.files.append(file) }
            let digest: String
            if case .updated = behavior {
                digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
            } else {
                digest = entry.sha256
            }
            return ManualDownload(fileURL: file, bytes: Int64(content.count), sha256: digest)
        }
    }
}
