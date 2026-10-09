import Core
import Foundation
import Observation
import Ports

/// Runs sync for the library that is open: applies the user's settings and the fleet-model rule to the replicator, and
/// reports what the Sync page and the toolbar's cloud show.
///
/// The replicator belongs to one library. When the app rebuilds its services for another embedding model the library is
/// closed and a new one opened, so the model is attached to each new library and detached before the old one closes.
@MainActor @Observable
final class SyncModel {
    /// What the model needs from the library it is attached to.
    struct Library {
        let sync: any LibrarySync
        let ingestion: IngestionService
        /// The embedding model in use, and how it is named to the user.
        let embedding: EmbeddingModelIdentity
        let embeddingName: String
        /// The model every iPad shares (the app's default embedder; only tests and stand-ins use another).
        var fleet: EmbeddingModelIdentity = SyncPolicy.fleetModel
        var fleetName: String = SyncPolicy.fleetModelName
    }

    let settings: SyncSettings
    /// What the replicator last reported.
    private(set) var status = SyncStatus()
    /// What the fleet-model rule says sync should be doing.
    private(set) var decision = SyncDecision.off
    /// Documents that stay on this iPad because their original is too large to share.
    private(set) var unshared: [UnsharedDocument] = []
    /// Called when documents were sent or received, or the state changed: the library list is out of date.
    @ObservationIgnored var onActivity: (@MainActor () async -> Void)?

    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var started: SyncConfiguration?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var applyAgain = false

    init(settings: SyncSettings) {
        self.settings = settings
    }

    /// Whether sync is turned on, running or not: the delete and reset confirmations warn about it.
    var isEnabled: Bool { settings.isEnabled }

    /// What to show: the replicator's state while it runs, otherwise why it does not.
    var state: SyncState {
        guard settings.isEnabled else { return .off }
        if settings.configuration == nil { return .error(.other("Enter the server address and a user name.")) }
        switch decision {
        case .off: return .off
        case .pause(let reason): return .paused(reason)
        case .run: return status.state == .off ? .connecting : status.state
        }
    }

    // MARK: Library

    func attach(_ library: Library) async {
        await detach()
        self.library = library
        let sync = library.sync
        tasks.append(Task { [weak self] in
            for await update in await sync.statusUpdates() {
                guard let self else { return }
                await self.received(update)
            }
        })
        tasks.append(Task { [weak self] in
            // A document finishing, such as the last one of a re-index after a switch of model, can end a pause.
            for await job in await library.ingestion.updates() where job.state == .ready || job.state == .failed {
                guard let self else { return }
                await self.apply()
            }
        })
        await apply()
    }

    /// Stops sync and lets go of the library. Call before the library is closed.
    func detach() async {
        for task in tasks { task.cancel() }
        tasks = []
        if let sync = library?.sync, started != nil { await sync.stop() }
        started = nil
        library = nil
        status = SyncStatus()
        decision = .off
        unshared = []
    }

    // MARK: Applying the settings

    /// Brings the replicator in line with the settings and the fleet-model rule. Starts it, stops it, or leaves it, and
    /// restarts it when `restart` is set or the server or account changed. Safe to call as often as something changes.
    func apply(restart: Bool = false) async {
        guard library != nil else { return }
        if applying {
            applyAgain = true
            return
        }
        applying = true
        var restart = restart
        repeat {
            applyAgain = false
            await applyOnce(restart: restart)
            restart = false
        } while applyAgain
        applying = false
    }

    private func applyOnce(restart: Bool) async {
        guard let library else { return }
        let outdated = (try? await library.ingestion.outdatedDocuments(for: library.embedding))?.count ?? 0
        decision = SyncPolicy.decide(
            enabled: settings.isEnabled, activeModel: library.embedding, activeModelName: library.embeddingName,
            outdatedDocuments: outdated, fleet: library.fleet, fleetName: library.fleetName)
        if decision == .run, let configuration = settings.configuration {
            if restart || started != configuration {
                await library.sync.start(configuration)
                started = configuration
            }
        } else if started != nil {
            await library.sync.stop()
            started = nil
        }
        unshared = await library.sync.unsharedDocuments()
    }

    private func received(_ update: SyncStatus) async {
        let changed = update.received != status.received || update.sent != status.sent || update.state != status.state
        status = update
        if update.state == .upToDate, let library { unshared = await library.sync.unsharedDocuments() }
        if changed { await onActivity?() }
    }
}
