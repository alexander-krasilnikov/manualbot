@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

@Suite struct CouchbaseImageTests {
    static let featureTag = RepoFixture.imageIdentity.tag

    static func image(_ doc: String, _ generation: Int, _ n: Int, hot: Int? = nil, page: Int? = nil, heading: String? = nil,
                      caption: String? = nil, model: String? = nil) -> ImageWrite {
        ImageWrite(
            record: ImageRecord(
                docId: doc, generation: generation, n: n, page: page ?? n + 1, heading: heading, caption: caption,
                captionSource: caption == nil ? .none : .nearby, ocrText: "text \(n)", width: 640, height: 480,
                features: RepoFixture.vector(hot ?? n), featureModel: model ?? featureTag),
            displayCopy: Data("jpeg-\(generation)-\(n)".utf8))
    }

    private func ready(_ f: RepoFixture, _ id: String) async throws {
        try await f.repo.upsert(DocumentRecord(id: id, title: "Doc \(id)", type: .pdf))
    }

    private func filter(_ scope: Set<String>? = nil, model: String? = nil) -> SearchFilter {
        SearchFilter(documentIDs: scope, embeddingModel: model ?? Self.featureTag)
    }

    // MARK: 3.1 schema

    @Test func aDatabaseCreatedBeforeImagesExistedStillOpens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try CouchbaseBootstrap.enableVectorSearch()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("db"), withIntermediateDirectories: true)
        var config = DatabaseConfiguration()
        config.directory = root.appendingPathComponent("db").path
        let old = try Database(name: "manualbot", config: config)
        for name in ["documents", "chunks", "chats", "messages", "ingestJobs"] {
            _ = try old.createCollection(name: name, scope: CouchbaseSchema.scope)
        }
        let doc = MutableDocument(id: "d1")
        doc.setString("Old manual", forKey: "title")
        doc.setString("pdf", forKey: "type")
        doc.setDouble(1_700_000_000, forKey: "importedAt")
        try old.collection(name: "documents", scope: CouchbaseSchema.scope)!.save(document: doc)
        try old.close()

        let f = try RepoFixture(root: root); defer { Task { await f.cleanUp() } }
        #expect(try await f.repo.document(id: "d1")?.title == "Old manual")
        #expect(try await f.repo.activeImages(docId: "d1").isEmpty)
        try await f.repo.writeImages([Self.image("d1", 1, 0)])
        #expect(try await f.repo.images(docId: "d1", generation: 1).count == 1)
    }

    @Test func aFreshDatabaseDeclaresTheImageIndexes() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        // Written after the index exists, as the app does on its first launch.
        try await f.repo.writeImages((0..<30).map { Self.image("d1", 1, $0) })
        let vectorPlan = try await f.repo.explain(
            "SELECT meta().id FROM manualbot.images ORDER BY APPROX_VECTOR_DISTANCE(features, $vector, \"cosine\") LIMIT 5",
            vector: RepoFixture.vector(3))
        #expect(vectorPlan.contains(CouchbaseSchema.imageVectorIndex), "\(vectorPlan)")
        let valuePlan = try await f.repo.explain("SELECT meta().id FROM manualbot.images WHERE docId = \"d1\" AND generation = 1")
        #expect(valuePlan.contains(CouchbaseSchema.imageDocGenIndex), "\(valuePlan)")
    }

    // MARK: 3.2 storage

    @Test func imagesRoundTripWithTheirDisplayCopy() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let write = Self.image("d1", 1, 2, page: 14, heading: "Install", caption: "Figure 3: Filter housing")
        try await f.repo.writeImages([write])
        let read = try #require(try await f.repo.images(docId: "d1", generation: 1).first)
        #expect(read == write.record)
        #expect(read.id == "d1:1:img:2")
        #expect(try await f.repo.imageData(id: read.id) == write.displayCopy)
        #expect(try await f.repo.imageData(id: "d1:1:img:99") == nil)

        try await f.repo.writeImages([Self.image("d1", 1, 2, caption: "replaced")])
        #expect(try await f.repo.images(docId: "d1", generation: 1).map(\.caption) == ["replaced"])
    }

    @Test func passagesKeepTheirImageReference() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        var chunk = RepoFixture.chunk("d1", 1, 0)
        chunk.imageId = "d1:1:img:0"
        try await f.repo.writeChunks([chunk, RepoFixture.chunk("d1", 1, 1)])
        let read = try await f.repo.chunks(docId: "d1", generation: 1)
        #expect(read.map(\.imageId) == ["d1:1:img:0", nil])
    }

    @Test func reindexLeavesOnlyTheNewGenerationsImages() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await ready(f, "d1")
        try await f.repo.writeImages([Self.image("d1", 1, 0), Self.image("d1", 1, 1)])
        try await f.repo.writeChunks([RepoFixture.chunk("d1", 1, 0)])
        try await f.repo.activate(generation: 1, for: "d1")

        try await f.repo.writeImages([Self.image("d1", 2, 0)])
        #expect(try await f.repo.activeImages(docId: "d1").count == 2)   // old set until the switch
        try await f.repo.activate(generation: 2, for: "d1")
        #expect(try await f.repo.activeImages(docId: "d1").map(\.generation) == [2])
        #expect(try await f.repo.images(docId: "d1", generation: 1).isEmpty)
        #expect(try await f.repo.imageData(id: "d1:1:img:0") == nil)
    }

    @Test func deletingADocumentRemovesItsImages() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await ready(f, "d1"); try await ready(f, "d2")
        try await f.repo.writeImages([Self.image("d1", 1, 0), Self.image("d2", 1, 0)])
        try await f.repo.activate(generation: 1, for: "d1")
        try await f.repo.deleteDocument(id: "d1")
        #expect(try await f.repo.images(docId: "d1", generation: 1).isEmpty)
        #expect(try await f.repo.imageData(id: "d1:1:img:0") == nil)
        #expect(try await f.repo.images(docId: "d2", generation: 1).count == 1)
    }

    @Test func pageAndHeadingLookupsReturnTheActiveSet() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await ready(f, "d1")
        try await f.repo.writeImages([Self.image("d1", 1, 0, page: 3, heading: "A"), Self.image("d1", 1, 1, page: 4, heading: "B")])
        try await f.repo.writeChunks([
            Chunk(docId: "d1", generation: 1, ordinal: 0, page: 3, heading: "A", text: "on three", embedding: RepoFixture.vector(0), embeddingModel: RepoFixture.identity.tag),
            Chunk(docId: "d1", generation: 1, ordinal: 1, page: 4, heading: "B", text: "on four", embedding: RepoFixture.vector(1), embeddingModel: RepoFixture.identity.tag),
        ])
        #expect(try await f.repo.activeImages(docId: "d1", page: 3).isEmpty)       // not active yet
        try await f.repo.activate(generation: 1, for: "d1")
        #expect(try await f.repo.activeImages(docId: "d1", page: 3).map(\.n) == [0])
        #expect(try await f.repo.activeImages(docId: "d1", heading: "B").map(\.n) == [1])
        #expect(try await f.repo.activeChunks(docId: "d1", page: 4).map(\.text) == ["on four"])
        #expect(try await f.repo.activeChunks(docId: "d1", heading: "A").map(\.text) == ["on three"])
        #expect(try await f.repo.activeChunks(docId: "d1", page: 9).isEmpty)
    }

    @Test func aMessagePhotoSurvivesSavingTheMessageAgainAndGoesWithTheChat() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        let chat = try await f.repo.createChat()
        let message = MessageRecord(id: "m1", chatId: chat.id, role: .user, text: "q", createdAt: Date(timeIntervalSince1970: 1_700_000_000), hasAttachment: true,
                                    imageMatches: [ImageMatch(imageId: "d:1:img:0", docId: "d", docTitle: "T", page: 2, distance: 0.1)])
        try await f.repo.upsert(message: message, attachment: Data("photo".utf8))
        #expect(try await f.repo.attachment(messageId: "m1") == Data("photo".utf8))
        try await f.repo.upsert(message: message)
        #expect(try await f.repo.attachment(messageId: "m1") == Data("photo".utf8))
        #expect(try await f.repo.message(id: "m1") == message)
        #expect(try await f.repo.attachment(messageId: "nope") == nil)

        try await f.repo.deleteChat(id: chat.id)
        #expect(try await f.repo.attachment(messageId: "m1") == nil)
    }

    // MARK: 3.3 search

    private func seed(_ f: RepoFixture, filler: Int = 60) async throws {
        for id in ["A", "B"] {
            try await ready(f, id)
            try await f.repo.writeImages((0..<filler).map { Self.image(id, 1, $0, hot: id == "A" ? $0 : 200 + $0) })
            try await f.repo.activate(generation: 1, for: id)
        }
        try await ready(f, "C")                                                  // never activated
        try await f.repo.writeImages([Self.image("C", 1, 0, hot: 7)])
        try await f.repo.writeImages([Self.image("A", 2, 0, hot: 7)])             // half-written newer generation
        try await f.repo.writeImages([Self.image("B", 1, 500, hot: 7, model: "vision-featureprint@3/768")])  // other revision
    }

    @Test func nearestImageComesFirstAndOnlyVisibleRevisionMatchingImagesAreReturned() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        let hits = try await f.repo.imageSearch(RepoFixture.vector(7), limit: 5, filter: filter())
        #expect(hits.count == 5)
        #expect(hits[0].image.id == "A:1:img:7")
        #expect(hits[0].score < 0.001)
        #expect(hits.map(\.score) == hits.map(\.score).sorted())
        let ids = Set(hits.map(\.image.id))
        #expect(!ids.contains("C:1:img:0") && !ids.contains("A:2:img:0") && !ids.contains("B:1:img:500"))
    }

    @Test func searchReturnsOnlyImagesOfTheModelInUse() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        // After an OS update the current tag is the new revision: images written under the old one are not compared.
        let hits = try await f.repo.imageSearch(RepoFixture.vector(7), limit: 5, filter: filter(model: "vision-featureprint@3/768"))
        #expect(hits.map(\.image.id) == ["B:1:img:500"])
        #expect(try await f.repo.imageSearch(RepoFixture.vector(7), limit: 5, filter: filter(model: "vision-featureprint@9/768")).isEmpty)
    }

    @Test func scopeRestrictsImagesToPinnedDocuments() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        let hits = try await f.repo.imageSearch(RepoFixture.vector(7), limit: 8, filter: filter(["B"]))
        #expect(hits.count == 8)
        #expect(hits.allSatisfy { $0.image.docId == "B" })
        #expect(try await f.repo.imageSearch(RepoFixture.vector(7), limit: 3, filter: filter(["C"])).isEmpty)
    }

    @Test func anEmptyLibraryAndANonPositiveLimitReturnNothing() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        #expect(try await f.repo.imageSearch(RepoFixture.vector(1), limit: 5, filter: filter()).isEmpty)
        try await seed(f)
        #expect(try await f.repo.imageSearch(RepoFixture.vector(1), limit: 0, filter: filter()).isEmpty)
    }

    @Test func deletedDocumentsDisappearFromImageSearch() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await seed(f)
        try await f.repo.deleteDocument(id: "A")
        let hits = try await f.repo.imageSearch(RepoFixture.vector(7), limit: 10, filter: filter())
        #expect(hits.allSatisfy { $0.image.docId == "B" })
    }

    @Test func theImageQueryReportsItsFunnelWithMoreRowsReturnedThanVisible() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        try await seed(f)
        let before = tracer.queries.count
        _ = try await f.repo.imageSearch(RepoFixture.vector(7), limit: 5, filter: filter(["A"]))
        let query = try #require(tracer.queries.dropFirst(before).first { $0.trace.purpose == .image })
        #expect(query.trace.sql.contains("APPROX_VECTOR_DISTANCE(features"))
        #expect(query.trace.sql.contains("manualbot.images"))
        let attempt = try #require(query.trace.attempts.first)
        #expect(attempt.returned > attempt.visible)
        #expect(attempt.kept == 5)
    }

    @Test func aWindowThatYieldsTooFewVisibleImagesIsWidened() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        try await ready(f, "keep"); try await ready(f, "hide")
        // 40 invisible images nearer to the query than the 5 visible ones.
        try await f.repo.writeImages((0..<40).map { Self.image("hide", 1, $0, hot: 7) })
        try await f.repo.writeImages((0..<5).map { Self.image("keep", 1, $0, hot: 100 + $0) })
        try await f.repo.activate(generation: 1, for: "keep")
        let hits = try await f.repo.imageSearch(RepoFixture.vector(7), limit: 5, filter: filter())
        #expect(hits.count == 5 && hits.allSatisfy { $0.image.docId == "keep" })
        let windows = tracer.queries.filter { $0.trace.purpose == .image }.compactMap { $0.trace.attempts.first?.window }
        #expect(windows.count >= 2 && windows == windows.sorted())
    }

    // MARK: 3.4 inspection

    @Test func theImageQueryPlanNamesTheImageIndex() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.writeImages((0..<30).map { Self.image("d1", 1, $0) })
        let sql = """
            SELECT meta().id AS id, APPROX_VECTOR_DISTANCE(features, $vector, "cosine") AS score
            FROM manualbot.images ORDER BY APPROX_VECTOR_DISTANCE(features, $vector, "cosine") LIMIT 15
            """
        let plan = try await f.repo.plan(sql: sql)
        #expect(plan.contains(CouchbaseSchema.imageVectorIndex), "\(plan)")

        let lookup = try await f.repo.plan(sql: "SELECT meta().id FROM manualbot.images WHERE docId = $docId AND generation = $generation")
        #expect(lookup.contains(CouchbaseSchema.imageDocGenIndex), "\(lookup)")
    }

    @Test func aStoredImageIsShownWithItsBlobAndFeaturesShortened() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.writeImages([Self.image("d1", 1, 0, caption: "Figure 1")])
        let json = try #require(try await f.repo.storedDocument(collection: CouchbaseSchema.images, id: "d1:1:img:0"))
        #expect(json.contains("\"@type\" : \"blob\"") && json.contains("image/jpeg"))
        #expect(json.contains("768 values"))
        #expect(json.contains("Figure 1"))
        #expect(try await f.repo.storedDocument(collection: CouchbaseSchema.images, id: "gone") == nil)
    }
}
