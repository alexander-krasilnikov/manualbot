@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports

/// Read-only views of the database for the X-ray panel.
extension CouchbaseDocumentRepository: TraceInspector {
    /// The plan the database reports for `sql`. The plan does not depend on parameter values, so each
    /// `$name` is bound to a stand-in of the right shape: a zero vector for `$vector`, an empty string otherwise.
    public func plan(sql: String) throws -> String {
        let query = try database.createQuery(sql)
        let parameters = Parameters()
        // Image queries bind a vector of the image feature model's size, chunk queries of the embedding model's.
        let dimensions = sql.contains("\(CouchbaseSchema.scope).\(CouchbaseSchema.images)")
            ? imageFeatures.dimensions : embedding.dimensions
        let names = try NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(sql.startIndex..., in: sql)
        for match in names.matches(in: sql, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: sql) else { continue }
            let name = String(sql[nameRange])
            if name == "vector" {
                parameters.setValue([Float](repeating: 0, count: dimensions), forName: name)
            } else {
                parameters.setString("", forName: name)
            }
        }
        query.parameters = parameters
        return try query.explain()
    }

    public func storedDocument(collection: String, id: String, fullVectors: Bool) throws -> String? {
        guard let target = try database.collection(name: collection, scope: CouchbaseSchema.scope),
            let doc = try target.document(id: id)
        else { return nil }
        return Self.json(doc.toDictionary(), fullVectors: fullVectors)
    }

    public func syncAttributes(collection: String, id: String) async throws -> DocumentSyncAttributes? {
        guard let target = try database.collection(name: collection, scope: CouchbaseSchema.scope),
            let doc = try target.document(id: id)
        else { return nil }
        return DocumentSyncAttributes(
            id: doc.id, scope: doc.collection?.scope.name ?? CouchbaseSchema.scope, collection: collection,
            revisionID: doc.revisionID, sequence: doc.sequence, timestamp: doc.timestamp,
            expiration: try target.getDocumentExpiration(id: id))
    }

    // MARK: Explorer

    /// Collections in the order the explorer lists them; any other collection follows by name.
    private static let collectionOrder = [
        CouchbaseSchema.documents, CouchbaseSchema.chunks, CouchbaseSchema.images, CouchbaseSchema.chats,
        CouchbaseSchema.messages, CouchbaseSchema.ingestJobs, CouchbaseSchema.localMeta,
    ]
    private static let localOnly = CouchbaseSchema.deviceLocal

    public func collectionSummaries() throws -> [CollectionSummary] {
        try database.collections(scope: CouchbaseSchema.scope)
            .map { CollectionSummary(name: $0.name, localOnly: Self.localOnly.contains($0.name), count: Int($0.count)) }
            .sorted {
                let order = (Self.collectionOrder.firstIndex(of: $0.name) ?? .max, Self.collectionOrder.firstIndex(of: $1.name) ?? .max)
                return order.0 == order.1 ? $0.name < $1.name : order.0 < order.1
            }
    }

    public func documentIDs(collection: String, after: String?, containing: String?, limit: Int) throws -> [String] {
        // A collection name cannot be bound as a parameter, nor can LIMIT: the name is checked against the scope and the
        // limit is an Int, so both are safe to put in the text.
        guard try database.collections(scope: CouchbaseSchema.scope).contains(where: { $0.name == collection }) else {
            throw CouchbaseStoreError.unknownCollection(collection)
        }
        var conditions: [String] = []
        let parameters = Parameters()
        if let after {
            conditions.append("meta().id > $after")
            parameters.setString(after, forName: "after")
        }
        if let containing, !containing.isEmpty {
            conditions.append("CONTAINS(meta().id, $containing)")
            parameters.setString(containing, forName: "containing")
        }
        let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let query = try database.createQuery(
            "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).\(collection)\(filter) ORDER BY meta().id LIMIT \(max(limit, 0))")
        query.parameters = parameters
        return try query.execute().allResults().compactMap { $0.string(forKey: "id") }
    }

    public func blob(collection: String, id: String, key: String) throws -> BlobContent? {
        guard let target = try database.collection(name: collection, scope: CouchbaseSchema.scope),
            let blob = try target.document(id: id)?.blob(forKey: key), let data = blob.content
        else { return nil }
        return BlobContent(contentType: blob.contentType ?? "", data: data)
    }

    /// The chunks and images of a document. Those of the active generation, or of every generation while the
    /// document has none yet (it is still being imported).
    public func children(documentID: String) throws -> DocumentChildren {
        let generation = try collections.documents.document(id: documentID)
            .flatMap { $0.contains(key: "activeGeneration") ? $0.int(forKey: "activeGeneration") : nil }
        func ids(in collection: String, order: String) throws -> [String] {
            let filter = generation == nil ? "" : " AND generation = $generation"
            let query = try database.createQuery(
                "SELECT meta().id AS id FROM \(CouchbaseSchema.scope).\(collection) WHERE docId = $docId\(filter) ORDER BY generation, \(order)")
            let parameters = Parameters().setString(documentID, forName: "docId")
            if let generation { parameters.setInt(generation, forName: "generation") }
            query.parameters = parameters
            return try query.execute().allResults().compactMap { $0.string(forKey: "id") }
        }
        return DocumentChildren(
            chunks: try ids(in: CouchbaseSchema.chunks, order: "ordinal"),
            images: try ids(in: CouchbaseSchema.images, order: "n"))
    }

    public func indexes() throws -> [IndexSummary] {
        let recorded = try collections.localMeta.document(id: CouchbaseSchema.vectorDimensionsDocument)
        let definitions = CouchbaseSchema.indexDefinitions(
            embeddingDimensions: embedding.dimensions, imageDimensions: imageFeatures.dimensions)
        return try database.collections(scope: CouchbaseSchema.scope).flatMap { collection in
            try collection.indexes().map { name -> IndexSummary in
                guard var settings = definitions.first(where: { $0.name == name && $0.collection == collection.name })?.settings
                else { return IndexSummary(name: name, collection: collection.name) }
                if settings.kind == .vector, recorded?.contains(key: name) == true { settings.dimensions = recorded?.int(forKey: name) }
                return IndexSummary(name: name, collection: collection.name, settings: settings)
            }
        }
        .sorted { ($0.collection, $0.name) < ($1.collection, $1.name) }
    }

    /// Runs `sql` as typed and keeps at most `limit` rows. SQL++ in Couchbase Lite only reads, and the text is not
    /// rewritten, so errors and plans refer to exactly what was typed.
    public func query(sql: String, limit: Int) throws -> QueryRows {
        let start = ContinuousClock.now
        let query = try database.createQuery(sql)
        var rows: [String] = []
        var columns: [String] = []
        var truncated = false
        for result in try query.execute() {
            if rows.count == limit {
                truncated = true
                break
            }
            if rows.isEmpty { columns = result.keys }
            rows.append(Self.json(result.toDictionary(), fullVectors: false) ?? "{}")
        }
        return QueryRows(columns: columns, rows: rows, truncated: truncated, duration: start.duration(to: .now))
    }

    private static func json(_ dictionary: [String: Any], fullVectors: Bool) -> String? {
        let display = dictionary.mapValues { displayValue($0, fullVectors: fullVectors) }
        guard JSONSerialization.isValidJSONObject(display) else { return String(describing: display) }
        guard let data = try? JSONSerialization.data(
            withJSONObject: display, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(describing: display) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Vectors shortened (unless `fullVectors`), blobs reduced to type, length and digest, dates as text.
    static func displayValue(_ value: Any, fullVectors: Bool = false) -> Any {
        switch value {
        case let blob as Blob:
            return [
                "@type": "blob", "content_type": blob.contentType ?? "", "length": Int(blob.length),
                "digest": blob.digest ?? "",
            ] as [String: Any]
        case let dictionary as [String: Any]:
            return dictionary.mapValues { displayValue($0, fullVectors: fullVectors) }
        case let array as [Any]:
            let numbers = array.compactMap { ($0 as? NSNumber)?.floatValue }
            if !fullVectors, array.count > TraceFormat.leadingValues, numbers.count == array.count {
                return TraceFormat.shorten(numbers)
            }
            return array.map { displayValue($0, fullVectors: fullVectors) }
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            return value
        }
    }
}
