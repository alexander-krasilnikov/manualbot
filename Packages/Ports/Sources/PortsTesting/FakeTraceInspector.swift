import Foundation
import Ports

/// An in-memory `TraceInspector`: documents are JSON strings in named collections, queries return what was set.
public final class FakeTraceInspector: TraceInspector, @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [CollectionSummary]
    private var documents: [String: [String: String]]
    private var fullDocuments: [String: [String: String]] = [:]
    private var blobs: [String: BlobContent] = [:]
    private var childRecords: [String: DocumentChildren] = [:]
    private var indexList: [IndexSummary] = []
    private var queryResult = QueryRows(columns: [], rows: [], truncated: false, duration: .zero)
    private var queryError: (any Error)?
    private var queryDelay: Duration = .zero
    private var queryCount = 0

    /// `documents` maps each collection name to its documents by ID.
    public init(
        documents: [String: [String: String]] = [:], localOnly: Set<String> = []
    ) {
        self.documents = documents
        summaries = documents.keys.sorted().map {
            CollectionSummary(name: $0, localOnly: localOnly.contains($0), count: documents[$0]?.count ?? 0)
        }
    }

    // MARK: Setup

    public func setFullDocument(collection: String, id: String, json: String) {
        lock.withLock { fullDocuments[collection, default: [:]][id] = json }
    }

    public func setBlob(_ blob: BlobContent, collection: String, id: String, key: String) {
        lock.withLock { blobs["\(collection)/\(id)/\(key)"] = blob }
    }

    public func setChildren(_ children: DocumentChildren, of documentID: String) {
        lock.withLock { childRecords[documentID] = children }
    }

    public func setIndexes(_ indexes: [IndexSummary]) { lock.withLock { indexList = indexes } }

    public func setQuery(result: QueryRows, delay: Duration = .zero) {
        lock.withLock {
            queryResult = result
            queryDelay = delay
        }
    }

    public func setQueryError(_ error: (any Error)?) { lock.withLock { queryError = error } }

    public func add(collection: String, id: String, json: String) {
        lock.withLock {
            documents[collection, default: [:]][id] = json
            refreshCounts()
        }
    }

    public func remove(collection: String, id: String) {
        lock.withLock {
            documents[collection]?[id] = nil
            refreshCounts()
        }
    }

    /// How many times `query(sql:limit:)` was called.
    public var queryCalls: Int { lock.withLock { queryCount } }

    private func refreshCounts() {
        summaries = summaries.map { CollectionSummary(name: $0.name, localOnly: $0.localOnly, count: documents[$0.name]?.count ?? 0) }
    }

    // MARK: TraceInspector

    public func plan(sql: String) async throws -> String { "plan for: \(sql)" }

    public func storedDocument(collection: String, id: String, fullVectors: Bool) async throws -> String? {
        lock.withLock { (fullVectors ? fullDocuments[collection]?[id] : nil) ?? documents[collection]?[id] }
    }

    public func collectionSummaries() async throws -> [CollectionSummary] { lock.withLock { summaries } }

    public func documentIDs(collection: String, after: String?, containing: String?, limit: Int) async throws -> [String] {
        lock.withLock {
            (documents[collection] ?? [:]).keys.sorted()
                .filter { after == nil || $0 > after! }
                .filter { containing == nil || containing!.isEmpty || $0.contains(containing!) }
                .prefix(limit).map { $0 }
        }
    }

    public func blob(collection: String, id: String, key: String) async throws -> BlobContent? {
        lock.withLock { blobs["\(collection)/\(id)/\(key)"] }
    }

    public func children(documentID: String) async throws -> DocumentChildren {
        lock.withLock { childRecords[documentID] ?? DocumentChildren() }
    }

    public func indexes() async throws -> [IndexSummary] { lock.withLock { indexList } }

    public func query(sql: String, limit: Int) async throws -> QueryRows {
        let (result, error, delay) = lock.withLock { () -> (QueryRows, (any Error)?, Duration) in
            queryCount += 1
            return (queryResult, queryError, queryDelay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        return result
    }
}
