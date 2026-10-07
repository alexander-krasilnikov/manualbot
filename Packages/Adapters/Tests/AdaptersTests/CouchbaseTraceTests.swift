import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

@Suite struct CouchbaseTraceTests {
    private let filter = SearchFilter(embeddingModel: RepoFixture.identity.tag)

    private func tracedFixture() throws -> (RepoFixture, RecordingTracer) {
        let tracer = RecordingTracer()
        return (try RepoFixture(tracer: tracer), tracer)
    }

    // MARK: 2.1 queries

    @Test func aQueryIsReportedWithItsSQLAndRowCount() async throws {
        let (f, tracer) = try tracedFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .pdf))
        _ = try await f.repo.documents()
        let queries = tracer.queries
        #expect(queries.count == 1)
        #expect(queries[0].trace.sql.contains("FROM manualbot.documents"))
        #expect(queries[0].trace.returnedRows == 1)
        #expect(queries[0].trace.purpose == .other)
        #expect((queries[0].event.duration ?? -1) >= 0)
    }

    @Test func parametersAreShownAsBound() async throws {
        let (f, tracer) = try tracedFixture(); defer { Task { await f.cleanUp() } }
        _ = try await f.repo.chunks(docId: "d1", generation: 2)
        #expect(tracer.queries.first?.trace.parameters == ["docId": "d1", "generation": "2"])
    }

    @Test func aDisabledTracerSeesNothing() async throws {
        let tracer = RecordingTracer(isEnabled: false)
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .pdf))
        _ = try await f.repo.documents()
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0)])
        try await f.repo.activate(generation: 1, for: "d1")
        #expect(tracer.events.isEmpty)
    }

    @Test func eventsCarryTheOperationOfTheCaller() async throws {
        let (f, tracer) = try tracedFixture(); defer { Task { await f.cleanUp() } }
        let op = TraceOperation(id: "x", kind: .ask, title: "q")
        _ = try await TraceContext.$operation.withValue(op) { try await f.repo.documents() }
        _ = try await f.repo.documents()
        #expect(tracer.events.map(\.operation) == [op, nil])
    }

    // MARK: 2.2 funnel

    private func vector(hot: Int, plus other: Int? = nil) -> [Float] {
        var v = [Float](repeating: 0, count: RepoFixture.identity.dimensions)
        v[hot] = other == nil ? 1 : 0.9
        if let other { v[other] = 0.1 }
        return v
    }

    private func chunk(gen: Int, _ ordinal: Int, embedding: [Float]) -> Chunk {
        Chunk(docId: "D", generation: gen, ordinal: ordinal, page: 1, text: "chunk \(gen)-\(ordinal)",
              embedding: embedding, embeddingModel: RepoFixture.identity.tag)
    }

    @Test func theFunnelCountsWhatWasHiddenFromTheResult() async throws {
        let (f, tracer) = try tracedFixture(); defer { Task { await f.cleanUp() } }
        // Visible: D gen 1 (30). Hidden: a newer gen 2 (a re-index in progress) with 3 chunks that match best.
        try await f.repo.upsert(DocumentRecord(id: "D", title: "D", type: .pdf))
        try await f.repo.writeChunks((0..<30).map { chunk(gen: 1, $0, embedding: vector(hot: 7, plus: 100 + $0)) })
        try await f.repo.activate(generation: 1, for: "D")
        try await f.repo.writeChunks((0..<3).map { chunk(gen: 2, $0, embedding: vector(hot: 7)) })

        let hits = try await f.repo.vectorSearch(vector(hot: 7), limit: 5, filter: filter)
        #expect(hits.count == 5)

        let search = tracer.queries.filter { $0.trace.purpose == .vector }
        #expect(search.count == 1)
        let attempt = try #require(search.first?.trace.attempts.first)
        #expect(attempt.window == 15)
        #expect(attempt.returned == 15)
        #expect(attempt.notVisible == 3)
        #expect(attempt.kept == 5)
        #expect(attempt.visible == 5)
        #expect(attempt.notExamined == 7, "the search stopped once five chunks were found")
        #expect(attempt.notVisible + attempt.visible + attempt.notExamined == attempt.returned)
        #expect(search[0].trace.parameters["vector"]?.hasSuffix("768 values]") == true)
    }

    @Test func aWidenedWindowIsShownAsOneEventPerAttempt() async throws {
        let (f, tracer) = try tracedFixture(); defer { Task { await f.cleanUp() } }
        // 100 hidden chunks match the query exactly, so the first two windows (15, 60) hold nothing visible.
        try await f.repo.upsert(DocumentRecord(id: "D", title: "D", type: .pdf))
        try await f.repo.writeChunks((0..<30).map { chunk(gen: 1, $0, embedding: vector(hot: 7, plus: 100 + $0)) })
        try await f.repo.activate(generation: 1, for: "D")
        try await f.repo.writeChunks((0..<100).map { chunk(gen: 2, $0, embedding: vector(hot: 7)) })

        let hits = try await f.repo.vectorSearch(vector(hot: 7), limit: 5, filter: filter)
        #expect(hits.count == 5)

        let attempts = tracer.queries.filter { $0.trace.purpose == .vector }.compactMap { $0.trace.attempts.first }
        #expect(attempts.map(\.window) == [15, 60, 240])
        #expect(attempts[0].kept == 0 && attempts[0].notVisible == 15)
        #expect(attempts[1].kept == 0 && attempts[1].notVisible == 60)
        #expect(attempts[2].kept == 5)
    }

    @Test func keywordSearchReportsItsMatchExpression() async throws {
        let (f, tracer) = try tracedFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .pdf))
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0, text: "Error E-042 means overheating")])
        try await f.repo.activate(generation: 1, for: "d1")
        let hits = try await f.repo.keywordSearch(terms: ["E-042"], limit: 3, filter: filter)
        #expect(hits.count == 1)
        let query = try #require(tracer.queries.first { $0.trace.purpose == .keyword })
        #expect(query.trace.sql.contains("MATCH(chunks_fts, $match)"))
        #expect(query.trace.parameters["match"] == "\"E-042\"")
        #expect(query.trace.attempts.first?.kept == 1)
    }

    // MARK: 2.3 writes

    @Test func reindexingReportsThePreviousGenerationRemovedInTheSameStep() async throws {
        let (f, tracer) = try tracedFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .pdf))
        try await f.repo.writeChunks((0..<3).map { RepoFixture.chunk("d1", 1, $0) })
        try await f.repo.activate(generation: 1, for: "d1")
        try await f.repo.writeChunks((0..<2).map { RepoFixture.chunk("d1", 2, $0) })
        try await f.repo.activate(generation: 2, for: "d1")

        let activations = tracer.kinds.compactMap { kind -> (Int, Int)? in
            if case .generationActivated(_, let generation, let removed, _) = kind { return (generation, removed) }
            return nil
        }
        #expect(activations.map(\.0) == [1, 2])
        #expect(activations.map(\.1) == [0, 3])

        let batches = tracer.kinds.compactMap { kind -> (Int, Int)? in
            if case .batchWritten("chunks", let count, let dims) = kind { return (count, dims) }
            return nil
        }
        #expect(batches.map(\.0) == [3, 2])
        #expect(batches.allSatisfy { $0.1 == 768 })
    }

    @Test func blobsMessagesAndDeletionAreReported() async throws {
        let (f, tracer) = try tracedFixture(); defer { Task { await f.cleanUp() } }
        let file = f.root.appendingPathComponent("manual.txt")
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try "Hold the button.".write(to: file, atomically: true, encoding: .utf8)

        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .text))
        try await f.repo.attachOriginal(fileURL: file, contentType: "text/plain", to: "d1")
        _ = try await f.repo.originalFileURL(docId: "d1")
        _ = try await f.repo.originalFileURL(docId: "d1")
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0), RepoFixture.chunk("d1", 1, 1)])
        try await f.repo.upsert(message: MessageRecord(
            id: "m1", chatId: "c1", role: .user, text: "hi", createdAt: Date()))
        try await f.repo.deleteDocument(id: "d1")

        let kinds = tracer.kinds
        #expect(kinds.contains(.documentSaved(collection: "documents", id: "d1")))
        #expect(kinds.contains(.blobStored(docId: "d1", contentType: "text/plain", length: 16)))
        #expect(kinds.contains(.blobRead(docId: "d1", length: 16, cacheHit: false)))
        #expect(kinds.contains(.blobRead(docId: "d1", length: 16, cacheHit: true)))
        #expect(kinds.contains(.messageSaved(id: "m1")))
        #expect(kinds.contains(.documentDeleted(docId: "d1", chunksRemoved: 2)))
    }

    // MARK: 2.4 inspector

    @Test func theVectorQueryPlanNamesTheVectorIndex() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.writeChunks((0..<400).map { RepoFixture.chunk("d1", 1, $0) })
        let plan = try await f.repo.plan(sql: """
            SELECT meta().id AS id, APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine") AS score
            FROM manualbot.chunks ORDER BY APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine") LIMIT 15
            """)
        #expect(plan.contains(CouchbaseSchema.vectorIndex), "\(plan)")
        let ftsPlan = try await f.repo.plan(sql: """
            SELECT meta().id AS id FROM manualbot.chunks WHERE MATCH(chunks_fts, $match) LIMIT 15
            """)
        #expect(ftsPlan.contains(CouchbaseSchema.ftsIndex), "\(ftsPlan)")
    }

    @Test func aStoredChunkIsShownWithAShortenedVector() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 4)])
        let json = try #require(try await f.repo.storedDocument(collection: "chunks", id: "d1:1:4"))
        #expect(json.contains("\"text\" : \"chunk 1-4\""), "\(json)")
        #expect(json.contains("768 values]"), "\(json)")
        #expect(json.contains("\"embeddingModel\""), "\(json)")
        #expect(json.contains("\"generation\" : 1"), "\(json)")
        #expect(json.count < 600, "the vector must not be printed in full")
    }

    @Test func aStoredDocumentShowsItsBlobAsMetadataOnly() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let file = f.root.appendingPathComponent("manual.txt")
        try "Secret manual body".write(to: file, atomically: true, encoding: .utf8)
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .text))
        try await f.repo.attachOriginal(fileURL: file, contentType: "text/plain", to: "d1")
        let json = try #require(try await f.repo.storedDocument(collection: "documents", id: "d1"))
        #expect(json.contains("\"content_type\" : \"text/plain\""), "\(json)")
        #expect(json.contains("\"digest\""), "\(json)")
        #expect(json.contains("\"length\" : 18"), "\(json)")
        #expect(!json.contains("Secret manual body"))
    }

    @Test func aMissingDocumentIsNil() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0)])
        try await f.repo.deleteDocument(id: "d1")
        #expect(try await f.repo.storedDocument(collection: "chunks", id: "d1:1:0") == nil)
    }
}
