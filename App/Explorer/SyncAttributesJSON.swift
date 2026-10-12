import Foundation
import Ports
import SwiftUI

/// The clipboard representation and highlighted view of local document sync metadata.
enum SyncAttributesJSON {
    private static let keys = ["collection", "expiration", "id", "revisionID", "scope", "sequence", "timestamp"]

    static func encode(_ attributes: DocumentSyncAttributes) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Payload(attributes)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func highlight(_ attributes: DocumentSyncAttributes) -> AttributedString {
        let values: [String: AttributedString] = [
            "collection": JSONHighlighter.string(attributes.collection),
            "expiration": attributes.expiration.map { JSONHighlighter.string(iso8601($0)) } ?? JSONHighlighter.highlight(NSNull()),
            "id": JSONHighlighter.string(attributes.id),
            "revisionID": attributes.revisionID.map(JSONHighlighter.string) ?? JSONHighlighter.highlight(NSNull()),
            "scope": JSONHighlighter.string(attributes.scope),
            "sequence": JSONHighlighter.number(String(attributes.sequence)),
            "timestamp": JSONHighlighter.number(String(attributes.timestamp)),
        ]

        var result = JSONHighlighter.punctuation("{\n")
        for (index, key) in keys.enumerated() {
            result += AttributedString(JSONHighlighter.padding(1)) + JSONHighlighter.key(key) + values[key]!
            result += JSONHighlighter.punctuation(index < keys.count - 1 ? ",\n" : "\n")
        }
        return result + JSONHighlighter.punctuation("}")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct Payload: Encodable {
        let attributes: DocumentSyncAttributes

        init(_ attributes: DocumentSyncAttributes) { self.attributes = attributes }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: Key.self)
            try values.encode(attributes.collection, forKey: .collection)
            if let expiration = attributes.expiration {
                try values.encode(iso8601(expiration), forKey: .expiration)
            } else {
                try values.encodeNil(forKey: .expiration)
            }
            try values.encode(attributes.id, forKey: .id)
            if let revisionID = attributes.revisionID {
                try values.encode(revisionID, forKey: .revisionID)
            } else {
                try values.encodeNil(forKey: .revisionID)
            }
            try values.encode(attributes.scope, forKey: .scope)
            try values.encode(attributes.sequence, forKey: .sequence)
            try values.encode(attributes.timestamp, forKey: .timestamp)
        }

        private enum Key: String, CodingKey {
            case collection, expiration, id, revisionID, scope, sequence, timestamp
        }
    }
}
