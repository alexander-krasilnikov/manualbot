import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// A repository over a throwaway database directory.
struct RepoFixture {
    static let identity = EmbeddingModelIdentity(id: "test-embedder", version: "1", dimensions: 768)
    /// The photo model of tests that do not name one: same size as the text stand-in, so `vector(_:)` serves both.
    static let imageIdentity = EmbeddingModelIdentity(id: "test-image", version: "1", dimensions: 768)
    let root: URL
    let repo: CouchbaseDocumentRepository

    init(
        root: URL? = nil, tracer: any Tracer = NoTracer(), embedding: EmbeddingModelIdentity = RepoFixture.identity,
        imageFeatures: EmbeddingModelIdentity = RepoFixture.imageIdentity
    ) throws {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        repo = try CouchbaseDocumentRepository(
            directory: self.root.appendingPathComponent("db"),
            originalsCache: self.root.appendingPathComponent("originals"),
            embedding: embedding, imageFeatures: imageFeatures, tracer: tracer)
    }

    func cleanUp() async {
        try? await repo.close()
        try? FileManager.default.removeItem(at: root)
    }

    static func vector(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0, count: identity.dimensions)
        v[hot % identity.dimensions] = 1
        return v
    }

    static func chunk(_ doc: String, _ generation: Int, _ ordinal: Int, text: String? = nil) -> Chunk {
        Chunk(docId: doc, generation: generation, ordinal: ordinal, page: ordinal + 1, heading: "H\(ordinal)",
              text: text ?? "chunk \(generation)-\(ordinal)", embedding: vector(ordinal),
              embeddingModel: identity.tag)
    }
}

@Suite struct CouchbaseRepositoryTests {
    // MARK: 2.2 schema and round trips

    @Test func documentRoundTrips() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let doc = DocumentRecord(id: "d1", title: "Manual A", type: .pdf, pageCount: 12,
                                 activeGeneration: 3, importedAt: Date(timeIntervalSince1970: 1_700_000_000), imageCount: 3)
        try await f.repo.upsert(doc)
        #expect(try await f.repo.document(id: "d1") == doc)
        #expect(try await f.repo.documents() == [doc])

        let bare = DocumentRecord(id: "d2", title: "Notes", type: .text, importedAt: Date(timeIntervalSince1970: 1_700_000_100))
        try await f.repo.upsert(bare)
        let read = try #require(try await f.repo.document(id: "d2"))
        #expect(read.pageCount == nil && read.activeGeneration == nil && read.imageCount == nil)
    }

    @Test func chunkRoundTripsWithVector() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .pdf))
        let chunk = RepoFixture.chunk("d1", 1, 4)
        try await f.repo.writeChunks([chunk])
        let read = try #require(try await f.repo.chunks(docId: "d1", generation: 1).first)
        #expect(read == chunk)
        #expect(read.id == "d1:1:4")
        #expect(read.embedding.count == 768)
    }

    @Test func rewritingAChunkOverwritesInsteadOfDuplicating() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0, text: "old")])
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0, text: "new")])
        let all = try await f.repo.chunks(docId: "d1", generation: 1)
        #expect(all.map(\.text) == ["new"])
    }

    @Test func chatMessageAndJobRoundTrip() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let chat = ChatRecord(id: "c1", title: "Reset help", pinnedDocIds: ["d1", "d2"],
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                              updatedAt: Date(timeIntervalSince1970: 1_700_000_050))
        try await f.repo.upsert(chat: chat)
        #expect(try await f.repo.chat(id: "c1") == chat)

        let citation = Citation(n: 1, chunkId: "d1:1:0", docId: "d1", docTitle: "Manual A", page: 42,
                                heading: "Reset", snippet: "Hold the button for 10 s")
        let message = MessageRecord(id: "m1", chatId: "c1", role: .assistant, text: "Hold it [1]",
                                    standaloneQuery: "how to reset X200", citations: [citation], stopped: true,
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_060))
        try await f.repo.upsert(message: message)
        #expect(try await f.repo.message(id: "m1") == message)

        let job = IngestJobRecord(docId: "d1", targetGeneration: 2, state: .embedding, progress: 0.4,
                                  nextOrdinal: 17, error: nil, enqueuedAt: Date(timeIntervalSince1970: 1_700_000_070))
        try await f.repo.upsert(job: job)
        #expect(try await f.repo.job(docId: "d1") == job)
        #expect(try await f.repo.chat(id: "missing") == nil)
    }

    @Test func dataSurvivesReopeningTheDatabase() async throws {
        let f = try RepoFixture()
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Persisted", type: .docx))
        try await f.repo.close()
        let reopened = try RepoFixture(root: f.root)
        #expect(try await reopened.repo.document(id: "d1")?.title == "Persisted")
        await reopened.cleanUp()
    }

    // MARK: 2.3 indexes

    @Test func queriesUseTheDeclaredIndexes() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        // Enough vectors to train the 64-centroid index.
        try await f.repo.writeChunks((0..<400).map { RepoFixture.chunk("d1", 1, $0) })

        let vectorPlan = try await f.repo.explain(
            "SELECT meta().id FROM manualbot.chunks ORDER BY APPROX_VECTOR_DISTANCE(embedding, $vector, \"cosine\") LIMIT 5",
            vector: RepoFixture.vector(3))
        #expect(vectorPlan.contains(CouchbaseSchema.vectorIndex), "\(vectorPlan)")

        let ftsPlan = try await f.repo.explain(
            "SELECT meta().id FROM manualbot.chunks AS c WHERE MATCH(chunks_fts, $text)", text: "chunk")
        #expect(ftsPlan.contains(CouchbaseSchema.ftsIndex), "\(ftsPlan)")

        let valuePlan = try await f.repo.explain(
            "SELECT meta().id FROM manualbot.chunks WHERE docId = \"d1\" AND generation = 1")
        #expect(valuePlan.contains("chunks_doc_gen"), "\(valuePlan)")

        let messagePlan = try await f.repo.explain(
            "SELECT meta().id FROM manualbot.messages WHERE chatId = \"c1\" ORDER BY createdAt")
        #expect(messagePlan.contains("messages_chat"), "\(messagePlan)")
    }

    // MARK: 2.4 generations

    @Test func halfWrittenNewGenerationIsInvisible() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .pdf))
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0), RepoFixture.chunk("d1", 1, 1)])
        try await f.repo.activate(generation: 1, for: "d1")

        // Generation 2 is only partly written and not yet activated.
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 2, 0)])
        let visible = try await f.repo.activeChunks(docId: "d1")
        #expect(visible.map(\.generation) == [1, 1])
        #expect(visible.map(\.ordinal) == [0, 1])
    }

    @Test func activatingSwitchesAndPurgesOldGeneration() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .pdf))
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0), RepoFixture.chunk("d1", 1, 1)])
        try await f.repo.activate(generation: 1, for: "d1")
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 2, 0), RepoFixture.chunk("d1", 2, 1), RepoFixture.chunk("d1", 2, 2)])
        try await f.repo.activate(generation: 2, for: "d1")

        #expect(try await f.repo.activeChunks(docId: "d1").map(\.generation) == [2, 2, 2])
        #expect(try await f.repo.chunks(docId: "d1", generation: 1).isEmpty)
        #expect(try await f.repo.document(id: "d1")?.activeGeneration == 2)
    }

    @Test func documentWithoutActiveGenerationHasNoVisibleChunks() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .pdf))
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0)])
        #expect(try await f.repo.activeChunks(docId: "d1").isEmpty)
    }

    @Test func activatingAnUnknownDocumentFails() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        await #expect(throws: CouchbaseStoreError.documentNotFound("nope")) {
            try await f.repo.activate(generation: 1, for: "nope")
        }
    }

    // MARK: 2.5 originals and deletion

    @Test func originalFileRoundTripsThroughTheBlob() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "T", type: .text))
        let source = f.root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try payload.write(to: source)
        try await f.repo.attachOriginal(fileURL: source, contentType: "text/plain", to: "d1")
        try FileManager.default.removeItem(at: source)  // the user's copy is gone

        let copy = try #require(try await f.repo.originalFileURL(docId: "d1"))
        #expect(copy.lastPathComponent == "source.txt")
        #expect(try Data(contentsOf: copy) == payload)
    }

    @Test func deletingADocumentRemovesEverythingButKeepsCitationSnapshots() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Manual A", type: .pdf))
        try await f.repo.upsert(DocumentRecord(id: "d2", title: "Other", type: .pdf))
        let source = f.root.appendingPathComponent("a.pdf")
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: source)
        try await f.repo.attachOriginal(fileURL: source, contentType: "application/pdf", to: "d1")
        _ = try await f.repo.originalFileURL(docId: "d1")
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0), RepoFixture.chunk("d1", 2, 0), RepoFixture.chunk("d2", 1, 0)])
        try await f.repo.activate(generation: 1, for: "d1")

        let citation = Citation(n: 1, chunkId: "d1:1:0", docId: "d1", docTitle: "Manual A", page: 1, snippet: "kept")
        let message = MessageRecord(id: "m1", chatId: "c1", role: .assistant, text: "a [1]", citations: [citation],
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_060))
        try await f.repo.upsert(message: message)

        try await f.repo.deleteDocument(id: "d1")

        #expect(try await f.repo.document(id: "d1") == nil)
        #expect(try await f.repo.count("SELECT meta().id FROM manualbot.chunks WHERE docId = $docId", docId: "d1") == 0)
        #expect(try await f.repo.originalFileURL(docId: "d1") == nil)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("originals/d1").path))
        #expect(try await f.repo.message(id: "m1") == message)
        // Other documents are untouched.
        #expect(try await f.repo.count("SELECT meta().id FROM manualbot.chunks WHERE docId = $docId", docId: "d2") == 1)
    }
}
