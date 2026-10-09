@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports

extension CouchbaseDocumentRepository {
    /// Documents whose stored original is larger than `limit` bytes. They stay on this device: sync does not send them.
    func originals(largerThan limit: Int64) throws -> [UnsharedDocument] {
        let query = try database.createQuery(
            "SELECT meta().id AS id, title, file.length AS bytes FROM \(CouchbaseSchema.scope).documents WHERE file.length > $maxBytes")
        query.parameters = Parameters().setInt64(limit, forName: "maxBytes")
        return try query.execute().allResults().compactMap { row in
            guard let id = row.string(forKey: "id") else { return nil }
            return UnsharedDocument(id: id, title: row.string(forKey: "title") ?? id, bytes: row.int64(forKey: "bytes"))
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
}
