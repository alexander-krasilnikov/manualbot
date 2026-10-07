import Ports
import PortsTesting
import Testing

@Suite struct InspectorTests {
    private func inspector() -> FakeTraceInspector {
        var chunks: [String: String] = [:]
        for n in 0..<120 { chunks["chunk-\(String(format: "%03d", n))"] = "{}" }
        return FakeTraceInspector(documents: ["chunks": chunks, "ingestJobs": [:]], localOnly: ["ingestJobs"])
    }

    @Test func pagingAfterAnIDReturnsTheNextIDsInOrder() async throws {
        let fake = inspector()
        let first = try await fake.documentIDs(collection: "chunks", after: nil, containing: nil, limit: 50)
        let second = try await fake.documentIDs(collection: "chunks", after: first.last, containing: nil, limit: 50)
        let third = try await fake.documentIDs(collection: "chunks", after: second.last, containing: nil, limit: 50)
        #expect(first.first == "chunk-000")
        #expect(second.first == "chunk-050")
        #expect(first + second + third == (0..<120).map { "chunk-\(String(format: "%03d", $0))" })
    }

    @Test func theFilterNarrowsTheList() async throws {
        let ids = try await inspector().documentIDs(collection: "chunks", after: nil, containing: "-11", limit: 50)
        #expect(ids.count == 10)
    }

    @Test func theTwoArgumentStoredDocumentIsTheShortenedOne() async throws {
        let fake = FakeTraceInspector(documents: ["chunks": ["a": "short"]])
        fake.setFullDocument(collection: "chunks", id: "a", json: "full")
        #expect(try await fake.storedDocument(collection: "chunks", id: "a") == "short")
        #expect(try await fake.storedDocument(collection: "chunks", id: "a", fullVectors: true) == "full")
    }
}
