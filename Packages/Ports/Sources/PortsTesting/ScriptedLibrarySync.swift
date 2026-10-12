import Foundation
import Ports

/// A `LibrarySync` that does nothing but report the statuses a test or a UI-test launch scripts for it, and remember
/// how it was started and stopped.
public actor ScriptedLibrarySync: LibrarySync {
    public private(set) var configurations: [SyncConfiguration] = []
    public private(set) var stopCount = 0
    private var current: SyncStatus
    private var unshared: [UnsharedDocument]
    private var subscribers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    /// What `start` reports next, in order; once used up, `start` reports `.upToDate`.
    private var onStart: [SyncState]

    public init(initial: SyncStatus = SyncStatus(), onStart: [SyncState] = [], unshared: [UnsharedDocument] = []) {
        current = initial
        self.onStart = onStart
        self.unshared = unshared
    }

    /// Whether `start` has been called since the last `stop`.
    public var isRunning: Bool { configurations.count > stopCount }

    public var status: SyncStatus { current }

    public func start(_ configuration: SyncConfiguration) {
        configurations.append(configuration)
        for state in onStart.isEmpty ? [.upToDate] : onStart { emit(state) }
        onStart = []
    }

    public func stop() {
        stopCount += 1
        emit(.off)
    }

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        continuation.yield(current)
        return stream
    }

    public func unsharedDocuments() -> [UnsharedDocument] { unshared }

    // MARK: Scripting

    /// Reports a new state, as the replicator would.
    public func emit(_ state: SyncState, sent: Int? = nil, received: Int? = nil) {
        current.state = state
        if let sent { current.sent = sent }
        if let received { current.received = received }
        if sent != nil || received != nil { current.records += 1 }
        if state == .upToDate { current.lastSync = Date() }
        for continuation in subscribers.values { continuation.yield(current) }
    }

    public func setUnshared(_ documents: [UnsharedDocument]) { unshared = documents }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}
