import Foundation

/// A collection in the app's scope, as the database explorer lists it.
public struct CollectionSummary: Sendable, Equatable, Identifiable {
    public var name: String
    /// Never replicated: lives on this device only.
    public var localOnly: Bool
    public var count: Int

    public var id: String { name }

    public init(name: String, localOnly: Bool, count: Int) {
        self.name = name
        self.localOnly = localOnly
        self.count = count
    }
}

/// An index, with its settings when the app defines it (the database reports only the name).
public struct IndexSummary: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case vector, fullText, value }

    public struct Settings: Sendable, Equatable {
        public var kind: Kind
        /// The indexed expression or fields, as written in the index definition.
        public var expression: String
        public var dimensions: Int?
        public var metric: String?
        public var centroids: Int?
        public var encoding: String?

        public init(
            kind: Kind, expression: String, dimensions: Int? = nil, metric: String? = nil, centroids: Int? = nil,
            encoding: String? = nil
        ) {
            self.kind = kind
            self.expression = expression
            self.dimensions = dimensions
            self.metric = metric
            self.centroids = centroids
            self.encoding = encoding
        }
    }

    public var name: String
    public var collection: String
    /// `nil` for an index the app does not define.
    public var settings: Settings?

    public var id: String { "\(collection)/\(name)" }

    public init(name: String, collection: String, settings: Settings? = nil) {
        self.name = name
        self.collection = collection
        self.settings = settings
    }
}

/// The content of a stored blob, for previews.
public struct BlobContent: Sendable, Equatable {
    public var contentType: String
    public var data: Data

    public init(contentType: String, data: Data) {
        self.contentType = contentType
        self.data = data
    }
}

/// The IDs of the passages and images that belong to a document record.
public struct DocumentChildren: Sendable, Equatable {
    public var chunks: [String]
    public var images: [String]

    public init(chunks: [String] = [], images: [String] = []) {
        self.chunks = chunks
        self.images = images
    }
}

/// What a read-only query returned, already shortened for display.
public struct QueryRows: Sendable, Equatable {
    public var columns: [String]
    /// One pretty-printed JSON object per row.
    public var rows: [String]
    /// More rows existed than the limit allowed.
    public var truncated: Bool
    /// Execution plus reading the rows.
    public var duration: Duration

    public init(columns: [String], rows: [String], truncated: Bool, duration: Duration) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
        self.duration = duration
    }
}
