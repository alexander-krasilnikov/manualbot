import Foundation
import Ports

public enum ModelStoreError: Error, Equatable {
    case unknownModel(String)
    case insufficientStorage(required: Int64, available: Int64)
}

/// Tracks which models are installed and drives their one-time download and verification.
/// After everything is installed, nothing here touches the network.
public actor ModelStore {
    public nonisolated let manifest: ModelManifest
    private let downloader: any ModelDownloading
    private let files: any ModelFiles
    private let safetyMargin: Int64

    private var states: [String: ModelState]
    private var observers: [UUID: AsyncStream<[String: ModelState]>.Continuation] = [:]

    public init(
        manifest: ModelManifest, downloader: any ModelDownloading, files: any ModelFiles,
        safetyMargin: Int64 = 256 * 1024 * 1024
    ) {
        self.manifest = manifest
        self.downloader = downloader
        self.files = files
        self.safetyMargin = safetyMargin
        self.states = Dictionary(uniqueKeysWithValues: manifest.models.map { ($0.id, ModelState.missing) })
    }

    // MARK: Observation

    public func snapshot() -> [String: ModelState] { states }

    public func state(of id: String) -> ModelState? { states[id] }

    /// Emits the current states immediately and again after every change. By default a slow observer
    /// only sees the newest state (right for a UI); pass `.unbounded` to receive every transition.
    public func updates(
        buffering: AsyncStream<[String: ModelState]>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<[String: ModelState]> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<[String: ModelState]>.makeStream(bufferingPolicy: buffering)
        observers[token] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(token) } }
        continuation.yield(states)
        return stream
    }

    // MARK: Readiness

    public func isInstalled(_ role: ModelRole) -> Bool {
        let specs = manifest.models.filter { $0.role == role }
        return !specs.isEmpty && specs.allSatisfy { states[$0.id] == .installed }
    }

    /// Documents can be imported and indexed once the embedding model is installed.
    public var canImport: Bool { isInstalled(.embedder) }

    /// Chat needs every model.
    public var canChat: Bool { ModelRole.allCases.allSatisfy(isInstalled) }

    /// Models whose files are not (yet) usable.
    public func missingModels() -> [ModelSpec] {
        manifest.models.filter { states[$0.id] != .installed }
    }

    // MARK: Launch check

    /// Reconciles state with what is on disk. A model that was installed earlier but whose file is
    /// gone goes back to `missing` so the setup flow can offer it again. Downloads in flight are left alone.
    public func refresh() {
        // Models the manifest no longer lists (an earlier language model after a switch, say) are deleted first, so an
        // update does not leave gigabytes behind. Nothing listed is touched.
        files.removeUnlisted(keeping: manifest)
        for spec in manifest.models {
            switch states[spec.id] {
            case .downloading, .verifying: continue
            default: break
            }
            if files.isInstalled(spec) {
                states[spec.id] = .installed
            } else {
                states[spec.id] = .missing
            }
        }
        publish()
    }

    // MARK: Download

    /// Bytes still to download, and whether they fit on the device with the safety margin.
    public func storageRequirement() throws -> (required: Int64, available: Int64) {
        let required = missingModels().reduce(0) { $0 + $1.bytes } + safetyMargin
        return (required, try files.availableBytes())
    }

    /// Downloads and installs every model that is not installed, embedder first. Models fail
    /// independently: one failure does not stop the others. Throws only for problems that
    /// prevent starting at all (unknown model, not enough space).
    public func start(only ids: Set<String>? = nil) async throws {
        if let ids, let unknown = ids.first(where: { manifest.spec(id: $0) == nil }) {
            throw ModelStoreError.unknownModel(unknown)
        }
        let queue = missingModels()
            .filter { ids?.contains($0.id) ?? true }
            .filter { if case .downloading = states[$0.id] { return false } else { return true } }
            .sorted { ($0.role, $0.id) < ($1.role, $1.id) }
        guard !queue.isEmpty else { return }

        let required = queue.reduce(0) { $0 + $1.bytes } + safetyMargin
        let available = try files.availableBytes()
        guard available >= required else {
            throw ModelStoreError.insufficientStorage(required: required, available: available)
        }

        for spec in queue { await install(spec) }
    }

    /// Retries one failed (or missing) model.
    public func retry(_ id: String) async throws {
        guard manifest.spec(id: id) != nil else { throw ModelStoreError.unknownModel(id) }
        try await start(only: [id])
    }

    private func install(_ spec: ModelSpec) async {
        set(spec.id, .downloading(fraction: 0))
        var downloaded: URL?
        do {
            let id = spec.id
            let file = try await downloader.download(spec) { [weak self] fraction in
                Task { await self?.setProgress(id, fraction) }
            }
            downloaded = file
            set(spec.id, .verifying)
            let digest = try await files.sha256(of: file)
            guard digest.lowercased() == spec.sha256.lowercased() else {
                files.discard(file)
                set(spec.id, .failed("Checksum mismatch: the downloaded file is corrupt."))
                return
            }
            try files.install(file, for: spec)
            set(spec.id, .installed)
        } catch is CancellationError {
            if let downloaded { files.discard(downloaded) }
            set(spec.id, .missing)
        } catch {
            if let downloaded { files.discard(downloaded) }
            set(spec.id, .failed(error.localizedDescription))
        }
    }

    // MARK: State plumbing

    private func setProgress(_ id: String, _ fraction: Double) {
        // Late progress callbacks must not overwrite a state that has moved on.
        guard case .downloading = states[id] else { return }
        set(id, .downloading(fraction: min(max(fraction, 0), 1)))
    }

    private func set(_ id: String, _ state: ModelState) {
        states[id] = state
        publish()
    }

    private func publish() {
        for continuation in observers.values { continuation.yield(states) }
    }

    private func removeObserver(_ token: UUID) { observers[token] = nil }
}
