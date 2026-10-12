import Foundation
import Ports
import Testing
@testable import ManualBot

@Suite struct SyncAttributesJSONTests {
    @Test func highlightedAndCopiedJSONPreserveUnsignedIntegerPrecisionAndNulls() {
        let attributes = DocumentSyncAttributes(
            id: "record", scope: "manualbot", collection: "documents", revisionID: nil,
            sequence: 9_007_199_254_740_993, timestamp: .max, expiration: nil)

        let copied = SyncAttributesJSON.encode(attributes)
        let shown = String(SyncAttributesJSON.highlight(attributes).characters)
        #expect(copied.contains("9007199254740993"))
        #expect(copied.contains("18446744073709551615"))
        #expect(copied.contains("\"expiration\" : null"))
        #expect(copied.contains("\"revisionID\" : null"))
        #expect(shown.contains("9007199254740993"))
        #expect(shown.contains("18446744073709551615"))
        #expect(shown.contains("\"expiration\": null"))
        #expect(shown.contains("\"revisionID\": null"))
        #expect(!copied.contains("\"title\""))
    }

    @Test func copiedExpirationIsAnISO8601UTCString() throws {
        let attributes = DocumentSyncAttributes(
            id: "record", scope: "manualbot", collection: "documents", revisionID: "rev", sequence: 1,
            timestamp: 2, expiration: Date(timeIntervalSince1970: 2_000_000_000))
        let copied = SyncAttributesJSON.encode(attributes)
        let object = try #require(JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any])
        #expect(object["expiration"] as? String == "2033-05-18T03:33:20.000Z")
    }
}
