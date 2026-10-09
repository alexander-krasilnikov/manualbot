@preconcurrency import CouchbaseLiteSwift
import Core
import Foundation
import Ports
import Synchronization

/// Replicates the shared library (`documents` with their originals, `chunks`, `images`) with a Sync Gateway database,
/// in both directions and continuously. Chats, messages, ingestion jobs and the local metadata are not in the replicator's
/// collections, so they never leave the device.
///
/// What is sent is filtered: a document whose original is too large to attach is kept back with its chunks and images,
/// and a chunk or image whose vector is not from the fleet model is never sent, whatever else happens.
public actor CouchbaseLibrarySync: LibrarySync {
    private let repository: CouchbaseDocumentRepository
    private let fleetModelTag: String
    private let fleetImageModelTag: String
    private let maxOriginalBytes: Int64
    private let originals: OriginalSizes
    private let tracer: any Tracer
    /// The group the X-ray shows the current burst of replication in. A new one starts when the replicator becomes busy.
    private var operation: TraceOperation?

    private var replicator: Replicator?
    private var tokens: [ListenerToken] = []
    private var current = SyncStatus()
    private var subscribers: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]

    public init(
        repository: CouchbaseDocumentRepository, fleetModelTag: String = SyncPolicy.fleetModel.tag,
        fleetImageModelTag: String? = nil, maxOriginalBytes: Int64 = IngestionService.maxOriginalBytes,
        tracer: any Tracer = NoTracer()
    ) {
        self.tracer = tracer
        self.repository = repository
        self.fleetModelTag = fleetModelTag
        // Photos share the text model's vector space, so by default they carry the same tag.
        self.fleetImageModelTag = fleetImageModelTag ?? fleetModelTag
        self.maxOriginalBytes = maxOriginalBytes
        originals = OriginalSizes(limit: maxOriginalBytes, documents: repository.collections.documents)
    }

    // MARK: LibrarySync

    public var status: SyncStatus { current }

    /// Names of the collections the running replicator carries. Anything else stays on the device.
    var replicatedCollectionNames: [String] { replicator?.config.collections.map(\.collection.name) ?? [] }

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream(bufferingPolicy: .bufferingNewest(16))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        continuation.yield(current)
        return stream
    }

    public func unsharedDocuments() async -> [UnsharedDocument] {
        (try? await repository.originals(largerThan: maxOriginalBytes)) ?? []
    }

    public func start(_ configuration: SyncConfiguration) {
        teardown()
        current = SyncStatus(state: .connecting)
        publish()

        let collections = repository.collections
        let fleet = fleetModelTag
        let fleetImages = fleetImageModelTag
        let sizes = originals
        var documents = CollectionConfiguration(collection: collections.documents)
        documents.pushFilter = { doc, flags in flags.contains(.deleted) || !sizes.isLarge(doc) }
        var chunks = CollectionConfiguration(collection: collections.chunks)
        chunks.pushFilter = { doc, flags in
            flags.contains(.deleted)
                || (doc.string(forKey: "embeddingModel") == fleet && !sizes.isUnshared(docId: doc.string(forKey: "docId")))
        }
        var images = CollectionConfiguration(collection: collections.images)
        images.pushFilter = { doc, flags in
            flags.contains(.deleted)
                || (doc.string(forKey: "featureModel") == fleetImages && !sizes.isUnshared(docId: doc.string(forKey: "docId")))
        }

        var config = ReplicatorConfiguration(
            collections: [documents, chunks, images], target: URLEndpoint(url: configuration.endpoint))
        config.replicatorType = .pushAndPull
        config.continuous = true
        config.authenticator = BasicAuthenticator(username: configuration.username, password: configuration.password)
        let replicator = Replicator(config: config)
        tokens.append(replicator.addChangeListener { [weak self] change in
            let status = change.status
            Task { await self?.replicatorChanged(activity: status.activity, error: status.error) }
        })
        tokens.append(replicator.addDocumentReplicationListener { [weak self] replication in
            let documents = replication.documents.map {
                ReplicatedItem(collection: $0.collection, id: $0.id, error: $0.error?.localizedDescription)
            }
            let isPush = replication.isPush
            Task { await self?.replicated(documents, isPush: isPush) }
        })
        self.replicator = replicator
        replicator.start()
    }

    public func stop() {
        teardown()
        current.state = .off
        publish()
    }

    // MARK: Replicator events

    private func replicatorChanged(activity: Replicator.ActivityLevel, error: (any Error)?) {
        guard replicator != nil else { return }
        var described = ""
        switch activity {
        case .connecting: current.state = .connecting; described = "connecting"
        case .busy: current.state = .syncing; described = "syncing"
        case .idle:
            current.state = .upToDate
            current.lastSync = Date()
            described = "up to date"
        case .offline: current.state = .error(.unreachable); described = "offline, retrying"
        case .stopped:
            current.state = error.map { .error(Self.failure(from: $0)) } ?? .off
            described = error.map { "stopped: \($0.localizedDescription)" } ?? "stopped"
        @unknown default: break
        }
        publish()
        if !described.isEmpty {
            trace(.syncState(described))
            // A burst ends when the replicator has nothing left to do; the next one is a new group.
            if activity != .connecting, activity != .busy { operation = nil }
        }
    }

    /// One document of a replication batch: its collection, its ID, and why it failed, if it did.
    struct ReplicatedItem: Sendable {
        let collection: String
        let id: String
        let error: String?
    }

    /// Counts what moved, and for what was received, lets the repository see which received documents are now whole.
    private func replicated(_ items: [ReplicatedItem], isPush: Bool) async {
        guard replicator != nil, !items.isEmpty else { return }
        let documents = items.filter { $0.error == nil }
        if isPush { current.sent += documents.count } else { current.received += documents.count }
        publish()
        if tracer.isEnabled {
            for collection in CouchbaseSchema.replicated {
                let count = documents.filter { $0.collection == collection }.count
                if count > 0 { trace(.syncReplicated(collection: collection, count: count, push: isPush)) }
            }
            for item in items {
                if let reason = item.error { trace(.syncRefused(collection: item.collection, id: item.id, reason: reason)) }
            }
        }
        guard !isPush else { return }
        var affected = Set<String>()
        for item in documents {
            let (collection, id) = (item.collection, item.id)
            switch collection {
            case CouchbaseSchema.documents: affected.insert(id)
            case CouchbaseSchema.chunks: if let parts = Chunk.parseID(id) { affected.insert(parts.docId) }
            case CouchbaseSchema.images: if let parts = ImageRecord.parseID(id) { affected.insert(parts.docId) }
            default: break
            }
        }
        let searchable = (try? await repository.refreshArrivals(of: affected)) ?? []
        for docId in searchable {
            let title = (try? await repository.document(id: docId))?.title ?? docId
            trace(.syncDocumentSearchable(docId: docId, title: title))
        }
    }

    /// Records an event in the current burst's group, starting one if the replicator was idle.
    private func trace(_ kind: @autoclosure () -> TraceKind) {
        guard tracer.isEnabled else { return }
        if operation == nil {
            operation = TraceOperation(id: "sync-\(UUID().uuidString)", kind: .sync, title: "Sync")
        }
        TraceContext.$operation.withValue(operation) { tracer.emit(kind()) }
    }

    static func failure(from error: any Error) -> SyncFailure {
        let nsError = error as NSError
        guard nsError.domain == CBLError.domain else { return .other(nsError.localizedDescription) }
        switch nsError.code {
        case CBLError.httpAuthRequired: return .credentialsRefused
        case CBLError.unknownHost, CBLError.dnsFailure, CBLError.timeout: return .unreachable
        default: return .other(nsError.localizedDescription)
        }
    }

    // MARK: Helpers

    private func teardown() {
        replicator?.stop()
        for token in tokens { token.remove() }
        tokens = []
        replicator = nil
    }

    private func publish() {
        for continuation in subscribers.values { continuation.yield(current) }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}

/// Which documents have an original too large to share, asked of the push filters from the replicator's own threads.
/// A document's answer is remembered: an original is attached once, when the document is imported.
private final class OriginalSizes: @unchecked Sendable {
    private let limit: Int64
    private let documents: Collection
    private let large = Mutex<[String: Bool]>([:])

    init(limit: Int64, documents: Collection) {
        self.limit = limit
        self.documents = documents
    }

    /// For a `documents` record itself.
    func isLarge(_ doc: Document) -> Bool {
        let big = Self.exceeds(doc, limit)
        large.withLock { $0[doc.id] = big }
        return big
    }

    /// For a chunk or image: whether the document it belongs to is kept back.
    func isUnshared(docId: String?) -> Bool {
        guard let docId else { return false }
        if let known = large.withLock({ $0[docId] }) { return known }
        let big = ((try? documents.document(id: docId)).map { Self.exceeds($0, limit) }) ?? false
        large.withLock { $0[docId] = big }
        return big
    }

    private static func exceeds(_ doc: Document?, _ limit: Int64) -> Bool {
        guard let length = doc?.blob(forKey: "file")?.length else { return false }
        return Int64(length) > limit
    }
}
