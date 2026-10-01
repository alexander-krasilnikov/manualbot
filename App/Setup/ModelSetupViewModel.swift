import Core
import Foundation
import Observation
import Ports

/// Presents `ModelStore` state to the setup screen and the rest of the app.
@MainActor @Observable
final class ModelSetupViewModel {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let role: ModelRole
        let bytes: Int64
        var state: ModelState
    }

    struct Storage: Equatable {
        let required: Int64
        let available: Int64
        var isSufficient: Bool { available >= required }
        var shortfall: Int64 { max(required - available, 0) }
    }

    private(set) var rows: [Row] = []
    private(set) var canImport = false
    private(set) var canChat = false
    private(set) var storage: Storage?
    private(set) var isWorking = false
    /// False until the first look at what is installed, so the UI does not flash a setup screen for a moment.
    private(set) var isLoaded = false

    private let store: ModelStore

    init(store: ModelStore) {
        self.store = store
        rows = store.manifest.models
            .sorted { ($0.role, $0.id) < ($1.role, $1.id) }
            .map { Row(id: $0.id, title: $0.title, role: $0.role, bytes: $0.bytes, state: .missing) }
    }

    /// What the setup flow lists: everything on first run, but only what is missing once any model is
    /// installed (for example after the system offloaded a model file).
    var setupRows: [Row] { rows.contains { $0.state == .installed } ? pendingRows : rows }

    /// Models that are not installed, in download order.
    var pendingRows: [Row] { rows.filter { $0.state != .installed } }
    var hasFailure: Bool { rows.contains { if case .failed = $0.state { true } else { false } } }
    var totalPendingBytes: Int64 { pendingRows.reduce(0) { $0 + $1.bytes } }

    /// Reconciles with the disk, then follows the store for as long as the caller keeps this task alive.
    func observe() async {
        await store.refresh()
        for await snapshot in await store.updates() {
            await apply(snapshot)
        }
    }

    /// One reconciliation with the disk and store, for a launch that has no screen (background indexing).
    func refreshOnce() async {
        await store.refresh()
        await apply(await store.snapshot())
    }

    func start() async {
        isWorking = true
        defer { isWorking = false }
        try? await store.start()
        await refreshStorage()
    }

    func retry(_ id: String) async {
        isWorking = true
        defer { isWorking = false }
        try? await store.retry(id)
        await refreshStorage()
    }

    private func apply(_ snapshot: [String: ModelState]) async {
        for index in rows.indices {
            if let state = snapshot[rows[index].id] { rows[index].state = state }
        }
        canImport = await store.canImport
        canChat = await store.canChat
        await refreshStorage()
        isLoaded = true
    }

    private func refreshStorage() async {
        if let requirement = try? await store.storageRequirement() {
            storage = Storage(required: requirement.required, available: requirement.available)
        }
    }
}
