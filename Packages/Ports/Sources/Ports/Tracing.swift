import Foundation

/// A user-visible action that causes database and pipeline activity (the X-ray panel groups events by it).
public struct TraceOperation: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case importDocument, ask, openSource, reindex, delete, reset
    }

    public var id: String
    public var kind: Kind
    public var title: String

    public init(id: String, kind: Kind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

/// The operation the current task is working for. Child tasks (`async let`) and actor hops inherit it,
/// so events from parallel searches land in the right group without passing IDs through the ports.
public enum TraceContext {
    @TaskLocal public static var operation: TraceOperation?
}

public enum QueryPurpose: String, Sendable {
    case vector, keyword, image, other
}

/// One pass of a search over the index: how many rows came back and how many were usable.
public struct FunnelAttempt: Sendable, Equatable {
    public var window: Int
    public var returned: Int
    public var notVisible: Int
    public var wrongModel: Int
    public var kept: Int

    /// Rows that passed the visibility check (the active generation of a ready document in scope).
    public var visible: Int { wrongModel + kept }
    /// Rows after the one that filled the result; the search stops there and never looks at them.
    public var notExamined: Int { max(returned - notVisible - wrongModel - kept, 0) }

    public init(window: Int, returned: Int, notVisible: Int, wrongModel: Int, kept: Int) {
        self.window = window
        self.returned = returned
        self.notVisible = notVisible
        self.wrongModel = wrongModel
        self.kept = kept
    }
}

public struct QueryTrace: Sendable, Equatable {
    public var sql: String
    /// Bound parameters, already shortened for display (see `TraceFormat`).
    public var parameters: [String: String]
    public var purpose: QueryPurpose
    public var returnedRows: Int
    public var attempts: [FunnelAttempt]

    public init(
        sql: String, parameters: [String: String] = [:], purpose: QueryPurpose = .other,
        returnedRows: Int, attempts: [FunnelAttempt] = []
    ) {
        self.sql = sql
        self.parameters = parameters
        self.purpose = purpose
        self.returnedRows = returnedRows
        self.attempts = attempts
    }
}

public struct FusionEntry: Sendable, Equatable {
    public var chunkID: String
    public var documentTitle: String
    /// Zero-based position in the vector results, `nil` when that search did not find the passage.
    public var vectorPosition: Int?
    public var keywordPosition: Int?
    /// Position among the passages reached through the question's photo, `nil` when it had none or did not reach this one.
    public var imagePosition: Int?
    public var distance: Double?
    public var score: Double

    public init(
        chunkID: String, documentTitle: String, vectorPosition: Int?, keywordPosition: Int?, imagePosition: Int? = nil,
        distance: Double?, score: Double
    ) {
        self.imagePosition = imagePosition
        self.chunkID = chunkID
        self.documentTitle = documentTitle
        self.vectorPosition = vectorPosition
        self.keywordPosition = keywordPosition
        self.distance = distance
        self.score = score
    }
}

public enum RelevanceOutcome: Sendable, Equatable {
    case passedOnDistance
    case passedOnIdentifier(String)
    /// A library image matched the question's photo within the image distance threshold.
    case passedOnImage(Double)
    case failed
}

public enum TraceKind: Sendable, Equatable {
    case documentSaved(collection: String, id: String)
    case messageSaved(id: String)
    case blobStored(docId: String, contentType: String, length: Int)
    case blobRead(docId: String, length: Int, cacheHit: Bool)
    /// `localOnly` marks records in a collection that is never replicated.
    case jobState(docId: String, state: String, progress: Double, localOnly: Bool)
    case batchWritten(collection: String, count: Int, dimensions: Int)
    case generationActivated(docId: String, generation: Int, removed: Int, removedImages: Int = 0)
    case documentDeleted(docId: String, passagesRemoved: Int, imagesRemoved: Int = 0)
    /// One image was read: how much text was found in it, where its caption came from, and the size of its feature vector.
    case imageAnalyzed(docId: String, generation: Int, n: Int, ocrLength: Int, captionSource: String, dimensions: Int)
    /// A batch of images (with their display copies) was written in one transaction.
    case imagesWritten(collection: String, count: Int, blobBytes: Int, dimensions: Int)
    case query(QueryTrace)
    /// The question had no searchable words, so no keyword query was run.
    case keywordSearchSkipped
    case queryRewritten(original: String, standalone: String)
    case queryEmbedded(dimensions: Int)
    case fusion(method: String, k: Double, entries: [FusionEntry])
    /// The image fields are set when the question came with a photo.
    case relevance(
        bestDistance: Double?, threshold: Double, outcome: RelevanceOutcome, bestImageDistance: Double? = nil,
        imageThreshold: Double? = nil)
    /// The photo attached to a question was read: how much text was found, the identifiers kept from it, and the
    /// size of its feature vector.
    case photoAnalyzed(recognizedLength: Int, identifiers: [String], dimensions: Int)
    /// `firstToken` is `nil` when the model was not called.
    case generation(firstToken: TimeInterval?, skipped: Bool)
}

public struct TraceEvent: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var timestamp: Date
    /// Time the traced step took, where it is measurable.
    public var duration: TimeInterval?
    /// `nil` for background activity.
    public var operation: TraceOperation?
    public var kind: TraceKind

    public init(timestamp: Date = Date(), duration: TimeInterval? = nil, operation: TraceOperation?, kind: TraceKind) {
        self.timestamp = timestamp
        self.duration = duration
        self.operation = operation
        self.kind = kind
    }
}

/// Receives what the app does behind the scenes. Implementations must not block the caller.
public protocol Tracer: Sendable {
    /// Call sites check this before building an event, so tracing costs nothing while it is off.
    var isEnabled: Bool { get }
    func record(_ event: TraceEvent)
}

extension Tracer {
    /// Builds and records an event for the current operation, only when tracing is enabled.
    public func emit(duration: TimeInterval? = nil, _ kind: @autoclosure () -> TraceKind) {
        guard isEnabled else { return }
        record(TraceEvent(duration: duration, operation: TraceContext.operation, kind: kind()))
    }

    /// Runs `body`, then records the event it describes with the time `body` took.
    public func measure<T>(_ body: () async throws -> T, event: (T) -> TraceKind) async rethrows -> T {
        guard isEnabled else { return try await body() }
        let start = ContinuousClock.now
        let result = try await body()
        emit(duration: start.duration(to: .now).seconds, event(result))
        return result
    }
}

public struct NoTracer: Tracer {
    public init() {}
    public var isEnabled: Bool { false }
    public func record(_ event: TraceEvent) {}
}

/// Reads back what is stored, for the X-ray panel. Everything returned is already shortened for display.
public protocol TraceInspector: Sendable {
    /// The query plan for `sql`, as the database reports it.
    func plan(sql: String) async throws -> String
    /// The document as stored, pretty-printed JSON; vectors shortened, blobs reduced to type, length and
    /// digest. `nil` when it does not exist.
    func storedDocument(collection: String, id: String) async throws -> String?
}

/// Shortening of large values for display.
public enum TraceFormat {
    public static let leadingValues = 4

    /// `[0.021, -0.113, 0.044, 0.007, … 768 values]`
    public static func shorten(_ vector: [Float]) -> String {
        let head = vector.prefix(leadingValues).map { String(format: "%.3f", $0) }.joined(separator: ", ")
        return vector.count <= leadingValues ? "[\(head)]" : "[\(head), … \(vector.count) values]"
    }
}

extension Duration {
    public var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
