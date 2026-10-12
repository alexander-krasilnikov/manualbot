import Foundation
import Ports
import Synchronization

/// In-memory stand-in for both the downloader and the file layer.
public final class FakeModelBackend: ModelDownloading, ModelFiles {
    public enum Behavior: Sendable {
        case succeed
        case corrupt            // completes, but the checksum will not match
        case fail(String)       // throws while downloading
        case suspend            // never completes until the task is cancelled
        case failOnce(String)   // throws on the first attempt, succeeds afterwards
    }

    private struct State {
        var behavior: [String: Behavior] = [:]
        var installed: Set<String> = []
        var freeBytes: Int64 = .max
        var downloads: [String] = []
        var discarded: [URL] = []
        var digests: [URL: String] = [:]
        var backupExcluded: Set<String> = []
        var removedAbandoned: [String] = []
        var records: [String: ModelRecord] = [:]
        var active = ActiveModels()
    }
    private let state = Mutex(State())

    public init() {}

    // Configuration
    public func setBehavior(_ behavior: Behavior, for id: String) { state.withLock { $0.behavior[id] = behavior } }
    public func setFreeBytes(_ bytes: Int64) { state.withLock { $0.freeBytes = bytes } }
    public func markInstalled(_ id: String) { state.withLock { _ = $0.installed.insert(id) } }
    public func removeInstalled(_ id: String) { state.withLock { _ = $0.installed.remove(id) } }

    // Observation
    public var downloads: [String] { state.withLock { $0.downloads } }
    public var discarded: [URL] { state.withLock { $0.discarded } }
    public var backupExcluded: Set<String> { state.withLock { $0.backupExcluded } }
    public var removedAbandoned: [String] { state.withLock { $0.removedAbandoned } }
    /// Records as they would be on disk: written by `writeRecord`, dropped with the model.
    public var storedRecords: [ModelRecord] { state.withLock { Array($0.records.values) } }
    public func isInstalledID(_ id: String) -> Bool { state.withLock { $0.installed.contains(id) } }

    // ModelDownloading
    public func download(_ spec: ModelSpec, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let behavior = state.withLock { s -> Behavior in
            s.downloads.append(spec.id)
            let current = s.behavior[spec.id] ?? .succeed
            if case .failOnce(let message) = current {
                s.behavior[spec.id] = .succeed
                return .fail(message)
            }
            return current
        }
        switch behavior {
        case .fail(let message):
            throw FakeError(message: message)
        case .suspend:
            while true { try await Task.sleep(for: .milliseconds(10)) }
        case .succeed, .corrupt, .failOnce:
            for step in 1...4 { progress(Double(step) / 4); await Task.yield() }
            let url = URL(fileURLWithPath: "/fake/tmp/\(spec.id)-\(UUID().uuidString)")
            let digest: String
            if case .corrupt = behavior { digest = String(repeating: "0", count: 64) } else { digest = spec.sha256 }
            state.withLock { $0.digests[url] = digest }
            return url
        }
    }

    // ModelFiles
    public func availableBytes() throws -> Int64 { state.withLock { $0.freeBytes } }
    public func isInstalled(_ spec: ModelSpec) -> Bool { state.withLock { $0.installed.contains(spec.id) } }
    public func installedURL(for spec: ModelSpec) -> URL { URL(fileURLWithPath: "/fake/models/\(spec.id)/\(spec.version)/\(spec.fileName)") }
    public func sha256(of file: URL) async throws -> String { state.withLock { $0.digests[file] ?? "" } }
    public func install(_ file: URL, for spec: ModelSpec) throws {
        state.withLock { s in
            s.installed.insert(spec.id)
            s.backupExcluded.insert(spec.id)
        }
    }
    public func discard(_ file: URL) { state.withLock { $0.discarded.append(file) } }
    public func uninstall(_ spec: ModelSpec) {
        state.withLock { s in
            s.installed.remove(spec.id)
            s.records[spec.id] = nil
        }
    }
    public func writeRecord(_ record: ModelRecord) throws { state.withLock { $0.records[record.spec.id] = record } }
    public func records() -> [ModelRecord] { state.withLock { Array($0.records.values) } }
    public func loadActive() -> ActiveModels { state.withLock { $0.active } }
    public func saveActive(_ active: ActiveModels) throws { state.withLock { $0.active = active } }
    @discardableResult
    public func removeAbandoned(keeping specs: [ModelSpec]) -> [String] {
        let kept = Set(specs.map(\.id))
        return state.withLock { s in
            let stale = s.installed.subtracting(kept).sorted()
            s.installed.subtract(stale)
            for id in stale { s.records[id] = nil }
            s.removedAbandoned.append(contentsOf: stale)
            return stale
        }
    }

    public struct FakeError: Error, LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }
}
