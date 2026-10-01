import CouchbaseLiteSwift

/// One-time process setup for Couchbase Lite. Must run before any database is opened.
public enum CouchbaseBootstrap {
    private static let enable: Swift.Result<Void, Error> = Swift.Result { try Extension.enableVectorSearch() }

    public static func enableVectorSearch() throws {
        try enable.get()
    }
}
