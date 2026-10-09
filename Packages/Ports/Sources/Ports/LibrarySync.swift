import Foundation

/// Where and as whom the shared library is synced.
public struct SyncConfiguration: Sendable, Equatable {
    /// The Sync Gateway database, such as `ws://192.168.1.20:4984/manualbot`.
    public var endpoint: URL
    public var username: String
    public var password: String

    public init(endpoint: URL, username: String, password: String) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
    }
}

/// Why sync is not running although it is turned on.
public enum SyncPauseReason: Sendable, Equatable {
    /// The embedding model in use is not the one every iPad shares. Names are the models' display names.
    case otherEmbedder(active: String, fleet: String)
    /// The fleet model is in use again, but this many documents still hold vectors from another model.
    case reindexing(remaining: Int, fleet: String)
}

/// Why sync could not run.
public enum SyncFailure: Sendable, Equatable {
    /// The server refused the user name or password. Sync does not retry until they change.
    case credentialsRefused
    /// The server could not be reached. The app keeps retrying.
    case unreachable
    case other(String)
}

public enum SyncState: Sendable, Equatable {
    case off
    case connecting
    case syncing
    case upToDate
    case paused(SyncPauseReason)
    case error(SyncFailure)
}

public struct SyncStatus: Sendable, Equatable {
    public var state: SyncState
    /// When the replicator last had nothing left to send or receive.
    public var lastSync: Date?
    /// Documents sent to and received from the server since sync was started, all collections together.
    public var sent: Int
    public var received: Int

    public init(state: SyncState = .off, lastSync: Date? = nil, sent: Int = 0, received: Int = 0) {
        self.state = state
        self.lastSync = lastSync
        self.sent = sent
        self.received = received
    }
}

/// A document that stays on this device because its original is too large to share.
public struct UnsharedDocument: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var bytes: Int64

    public init(id: String, title: String, bytes: Int64) {
        self.id = id
        self.title = title
        self.bytes = bytes
    }
}

/// Two-way replication of the shared library with a server. Documents with their originals, chunks and images are
/// exchanged; chats, messages and ingestion jobs never are.
public protocol LibrarySync: Sendable {
    /// Starts replicating, or replaces a running replication that was started with another configuration.
    func start(_ configuration: SyncConfiguration) async
    func stop() async
    var status: SyncStatus { get async }
    /// Every status change from now on, starting with the current one. Ends only when the caller stops iterating.
    func statusUpdates() async -> AsyncStream<SyncStatus>
    /// Documents that are not sent because their original is larger than the limit for sharing.
    func unsharedDocuments() async -> [UnsharedDocument]
}
