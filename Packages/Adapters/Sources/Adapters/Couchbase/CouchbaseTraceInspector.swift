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
        let names = try NSRegularExpression(pattern: #"\$([A-Za-z_][A-Za-z0-9_]*)"#)
        let range = NSRange(sql.startIndex..., in: sql)
        for match in names.matches(in: sql, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: sql) else { continue }
            let name = String(sql[nameRange])
            if name == "vector" {
                parameters.setValue([Float](repeating: 0, count: embedding.dimensions), forName: name)
            } else {
                parameters.setString("", forName: name)
            }
        }
        query.parameters = parameters
        return try query.explain()
    }

    public func storedDocument(collection: String, id: String) throws -> String? {
        guard let target = try database.collection(name: collection, scope: CouchbaseSchema.scope),
            let doc = try target.document(id: id)
        else { return nil }
        let display = doc.toDictionary().mapValues(Self.displayValue)
        guard JSONSerialization.isValidJSONObject(display) else { return String(describing: display) }
        let data = try JSONSerialization.data(
            withJSONObject: display, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Vectors shortened, blobs reduced to type, length and digest, dates as text.
    static func displayValue(_ value: Any) -> Any {
        switch value {
        case let blob as Blob:
            return [
                "@type": "blob", "content_type": blob.contentType ?? "", "length": Int(blob.length),
                "digest": blob.digest ?? "",
            ] as [String: Any]
        case let dictionary as [String: Any]:
            return dictionary.mapValues(displayValue)
        case let array as [Any]:
            let numbers = array.compactMap { ($0 as? NSNumber)?.floatValue }
            if array.count > TraceFormat.leadingValues, numbers.count == array.count {
                return TraceFormat.shorten(numbers)
            }
            return array.map(displayValue)
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            return value
        }
    }
}
