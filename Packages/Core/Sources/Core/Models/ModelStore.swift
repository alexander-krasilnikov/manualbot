import Foundation
import Ports

public enum ModelStoreError: Error, Equatable {
    case unknownModel(String)
    case insufficientStorage(required: Int64, available: Int64)
    /// Only an installed model can be activated.
    case notInstalled(String)
    /// The model a role is using cannot be deleted. Activate another model first.
    case activeModel(String)
    /// The model is being downloaded or verified right now.
    case busy(String)
}

/// Tracks which models are installed, which one each role uses, and drives their download and verification.
/// Once the models in use are installed, nothing here touches the network.
public actor ModelStore {
    public nonisolated let manifest: ModelManifest
    private let downloader: any ModelDownloading
    private let files: any ModelFiles
    private let validator: (any ModelValidating)?
    private let safetyMargin: Int64

    /// Every model the store knows: the manifest's defaults, and models installed from the Models page.
    private var specs: [String: ModelSpec]
    /// Records of installed models, by id.
    private var records: [String: ModelRecord]
    /// Records of downloads that have started but not finished, so a retry installs the same model with the same choice.
    private var pending: [String: ModelRecord] = [:]
    private var active: ActiveModels
    private var states: [String: ModelState]
    private var observers: [UUID: AsyncStream<[String: ModelState]>.Continuation] = [:]

    public init(
        manifest: ModelManifest, downloader: any ModelDownloading, files: any ModelFiles,
        validator: (any ModelValidating)? = nil, safetyMargin: Int64 = 256 * 1024 * 1024
    ) {
        self.manifest = manifest
        self.downloader = downloader
        self.files = files
        self.validator = validator
        self.safetyMargin = safetyMargin
        self.active = files.loadActive()
        var records: [String: ModelRecord] = [:]
        for record in files.records() { records[record.spec.id] = record }
        self.records = records
        var specs = Dictionary(uniqueKeysWithValues: manifest.models.map { ($0.id, $0) })
        for (id, record) in records where specs[id] == nil { specs[id] = record.spec }
        self.specs = specs
        self.states = Dictionary(uniqueKeysWithValues: specs.keys.map { ($0, ModelState.missing) })
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

    // MARK: Models in use

    /// The model a role uses: the one the user activated, or the manifest's default.
    public func activeSpec(for role: ModelRole) -> ModelSpec? {
        if let id = active.id(for: role), let spec = specs[id], spec.role == role { return spec }
        return manifest.models.first { $0.role == role }
    }

    public func isActive(_ id: String) -> Bool {
        ModelRole.allCases.contains { activeSpec(for: $0)?.id == id }
    }

    /// Models installed on this device, ordered by role.
    public func installedModels() -> [ModelRecord] {
        specs.values
            .filter { states[$0.id] == .installed }
            .map { records[$0.id] ?? manifestRecord(for: $0) }
            .sorted { ($0.spec.role, $0.spec.id) < ($1.spec.role, $1.spec.id) }
    }

    public func isInstalled(_ role: ModelRole) -> Bool {
        guard let spec = activeSpec(for: role) else { return false }
        return states[spec.id] == .installed
    }

    /// Documents can be imported and indexed once the embedding model in use is installed.
    public var canImport: Bool { isInstalled(.embedder) }

    /// Chat needs every model in use.
    public var canChat: Bool { ModelRole.allCases.allSatisfy(isInstalled) }

    /// Models in use that are not installed (or not usable).
    public func missingModels() -> [ModelSpec] {
        ModelRole.allCases.compactMap { activeSpec(for: $0) }.filter { states[$0.id] != .installed }
    }

    /// The record of an installed model: where it came from, and for an embedding model what its file said about it.
    public func record(for id: String) -> ModelRecord? {
        guard let spec = specs[id], states[id] == .installed else { return nil }
        return records[id] ?? manifestRecord(for: spec)
    }

    /// Makes an installed model the one its role uses. Nothing is downloaded, and the choice is kept across launches.
    public func activate(_ id: String) throws {
        guard let spec = specs[id] else { throw ModelStoreError.unknownModel(id) }
        guard states[id] == .installed else { throw ModelStoreError.notInstalled(id) }
        var record = records[id] ?? manifestRecord(for: spec)
        record.chosenByUser = true
        try files.writeRecord(record)
        records[id] = record
        active.set(id, for: spec.role)
        try files.saveActive(active)
        publish()
    }

    /// Deletes an installed model with its files. The model a role uses cannot be deleted.
    public func delete(_ id: String) throws {
        guard let spec = specs[id] else { throw ModelStoreError.unknownModel(id) }
        guard !isActive(id) else { throw ModelStoreError.activeModel(id) }
        guard !isBusy(id) else { throw ModelStoreError.busy(id) }
        files.uninstall(spec)
        records[id] = nil
        pending[id] = nil
        if manifest.spec(id: id) == nil {
            specs[id] = nil
            states[id] = nil
        } else {
            states[id] = .missing
        }
        publish()
    }

    // MARK: Readiness

    /// Reconciles state with what is on disk. A model that was installed earlier but whose file is gone goes back to
    /// `missing` so the setup flow can offer it again. Downloads in flight are left alone. Models that nothing keeps
    /// any more are deleted.
    public func refresh() {
        for record in files.records() where !isBusy(record.spec.id) {
            records[record.spec.id] = record
            specs[record.spec.id] = specs[record.spec.id] ?? record.spec
        }
        // Models installed before records existed are the first-run defaults.
        for spec in manifest.models where records[spec.id] == nil && files.isInstalled(spec) {
            let record = manifestRecord(for: spec)
            try? files.writeRecord(record)
            records[spec.id] = record
        }
        // Kept: the defaults, the models in use, and every model the user chose. Models replaced by an update
        // (a new language model, say) must not leave gigabytes behind.
        let keep = manifest.models
            + ModelRole.allCases.compactMap { activeSpec(for: $0) }
            + records.values.filter(\.chosenByUser).map(\.spec)
        files.removeAbandoned(keeping: keep)
        let kept = Set(keep.map(\.id))
        records = records.filter { kept.contains($0.key) }
        specs = specs.filter { kept.contains($0.key) || pending[$0.key] != nil }
        for (id, spec) in specs where !isBusy(id) {
            states[id] = files.isInstalled(spec) ? .installed : .missing
        }
        states = states.filter { specs[$0.key] != nil }
        publish()
    }

    // MARK: Download

    /// Bytes still to download, and whether they fit on the device with the safety margin.
    public func storageRequirement() throws -> (required: Int64, available: Int64) {
        let required = missingModels().reduce(0) { $0 + $1.bytes } + safetyMargin
        return (required, try files.availableBytes())
    }

    /// Downloads and installs every model in use that is not installed, embedder first. Models fail
    /// independently: one failure does not stop the others. Throws only for problems that prevent starting at
    /// all (unknown model, not enough space). With `ids`, exactly those models are installed, whether or not they are in use.
    public func start(only ids: Set<String>? = nil) async throws {
        if let ids, let unknown = ids.first(where: { specs[$0] == nil }) {
            throw ModelStoreError.unknownModel(unknown)
        }
        let candidates = if let ids { ids.compactMap { specs[$0] } } else { missingModels() }
        let queue = candidates
            .filter { states[$0.id] != .installed && !isBusy($0.id) }
            .sorted { ($0.role, $0.id) < ($1.role, $1.id) }
            .map { pending[$0.id] ?? records[$0.id] ?? manifestRecord(for: $0) }
        try await download(queue)
    }

    /// Retries one failed (or missing) model.
    public func retry(_ id: String) async throws {
        guard specs[id] != nil else { throw ModelStoreError.unknownModel(id) }
        try await start(only: [id])
    }

    /// Downloads a model chosen on the Models page. It is installed but not activated; `activate` makes it the one in use.
    public func install(_ record: ModelRecord) async throws {
        let id = record.spec.id
        switch states[id] {
        case .installed?: return
        case .downloading?, .verifying?: throw ModelStoreError.busy(id)
        default: break
        }
        try await download([record])
    }

    private func download(_ queue: [ModelRecord]) async throws {
        guard !queue.isEmpty else { return }
        let required = queue.reduce(0) { $0 + $1.spec.bytes } + safetyMargin
        let available = try files.availableBytes()
        guard available >= required else {
            throw ModelStoreError.insufficientStorage(required: required, available: available)
        }
        for record in queue { await fetch(record) }
    }

    /// Downloads, verifies and installs one model. Its record is written only once the model is installed.
    private func fetch(_ record: ModelRecord) async {
        let spec = record.spec
        specs[spec.id] = spec
        pending[spec.id] = record
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
            var installed = record
            if let validator {
                let description = try validator.validate(file, for: spec)
                // What the runtime read from an embedding model's file is all the app has for one it has not tested.
                if spec.role == .embedder, let size = description.embeddingDimension {
                    installed.embedding = EmbeddingDescription(
                        dimension: size, supportsImages: description.supportsImages,
                        maxInputLength: EmbeddingDescription.inputLength(from: description.embeddingInputLengths))
                }
            }
            try files.install(file, for: spec)
            try files.writeRecord(installed)
            records[spec.id] = installed
            pending[spec.id] = nil
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

    private func manifestRecord(for spec: ModelSpec) -> ModelRecord {
        ModelRecord(spec: spec, source: .manifest, chosenByUser: false)
    }

    private func isBusy(_ id: String) -> Bool {
        switch states[id] {
        case .downloading?, .verifying?: true
        default: false
        }
    }

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
