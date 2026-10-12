@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// The active generation's chunk and image counts, which a device that receives the record uses to know when the set is complete.
@Suite struct ActiveCountsTests {
    private func write(_ f: RepoFixture, doc: String, generation: Int, chunks: Int, images: Int) async throws {
        try await f.repo.writeChunks((0..<chunks).map { RepoFixture.chunk(doc, generation, $0) })
        if images > 0 {
            try await f.repo.writeImages((0..<images).map { CouchbaseImageTests.image(doc, generation, $0) })
        }
    }

    @Test func importRecordsTheCountsOfTheActiveSet() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Manual", type: .pdf))
        try await write(f, doc: "d1", generation: 1, chunks: 5, images: 2)
        try await f.repo.activate(generation: 1, for: "d1")

        let record = try #require(try await f.repo.document(id: "d1"))
        #expect(record.activeGeneration == 1)
        #expect(record.chunkCount == 5)
        #expect(record.activeImageCount == 2)
    }

    @Test func aDocumentWithoutImagesRecordsZero() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Notes", type: .text))
        try await write(f, doc: "d1", generation: 1, chunks: 3, images: 0)
        try await f.repo.activate(generation: 1, for: "d1")

        let record = try #require(try await f.repo.document(id: "d1"))
        #expect(record.chunkCount == 3)
        #expect(record.activeImageCount == 0)
    }

    @Test func reindexReplacesTheCountsWithThoseOfTheNewGeneration() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Manual", type: .pdf))
        try await write(f, doc: "d1", generation: 1, chunks: 5, images: 2)
        try await f.repo.activate(generation: 1, for: "d1")

        // The new set is written while generation 1 is still active: the record keeps describing generation 1.
        try await write(f, doc: "d1", generation: 2, chunks: 8, images: 1)
        let during = try #require(try await f.repo.document(id: "d1"))
        #expect(during.activeGeneration == 1)
        #expect(during.chunkCount == 5)
        #expect(during.activeImageCount == 2)

        try await f.repo.activate(generation: 2, for: "d1")
        let after = try #require(try await f.repo.document(id: "d1"))
        #expect(after.activeGeneration == 2)
        #expect(after.chunkCount == 8)
        #expect(after.activeImageCount == 1)
    }

    @Test func savingTheRecordKeepsTheCounts() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "d1", title: "Manual", type: .pdf))
        try await write(f, doc: "d1", generation: 1, chunks: 4, images: 0)
        try await f.repo.activate(generation: 1, for: "d1")

        var renamed = try #require(try await f.repo.document(id: "d1"))
        renamed.title = "Renamed"
        try await f.repo.upsert(renamed)

        let record = try #require(try await f.repo.document(id: "d1"))
        #expect(record.title == "Renamed")
        #expect(record.chunkCount == 4)
    }

    // MARK: Backfill

    @Test func openingBackfillsCountsForADocumentActivatedBeforeTheyWereRecorded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // A database written by a version that did not record the counts: an active generation, no counts.
        do {
            let first = try RepoFixture(root: root)
            try await first.repo.upsert(DocumentRecord(id: "d1", title: "Old", type: .pdf))
            try await write(first, doc: "d1", generation: 1, chunks: 6, images: 2)
            try await first.repo.upsert(DocumentRecord(id: "d1", title: "Old", type: .pdf, activeGeneration: 1))
            try await first.repo.close()
        }
        // Reopened: `activeGeneration` is set and no counts exist yet.
        let old = try Database(name: "manualbot", config: {
            var config = DatabaseConfiguration()
            config.directory = root.appendingPathComponent("db").path
            return config
        }())
        let documents = try #require(try old.collection(name: "documents", scope: CouchbaseSchema.scope))
        let stored = try #require(try documents.document(id: "d1"))
        #expect(!stored.contains(key: "chunkCount"))
        try old.close()

        let f = try RepoFixture(root: root); defer { Task { await f.cleanUp() } }
        let record = try #require(try await f.repo.document(id: "d1"))
        #expect(record.chunkCount == 6)
        #expect(record.activeImageCount == 2)
    }

    @Test func backfillCountsOnlyTheActiveGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try RepoFixture(root: root)
            try await write(first, doc: "d1", generation: 1, chunks: 3, images: 0)
            try await write(first, doc: "d1", generation: 2, chunks: 7, images: 0)
            try await first.repo.upsert(DocumentRecord(id: "d1", title: "Mid re-index", type: .pdf, activeGeneration: 1))
            try await first.repo.close()
        }
        let f = try RepoFixture(root: root); defer { Task { await f.cleanUp() } }
        #expect(try await f.repo.document(id: "d1")?.chunkCount == 3)
    }

    @Test func backfillLeavesRecordsThatAlreadyHaveCountsAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try RepoFixture(root: root)
            try await first.repo.upsert(DocumentRecord(id: "d1", title: "Manual", type: .pdf))
            try await write(first, doc: "d1", generation: 1, chunks: 4, images: 0)
            try await first.repo.activate(generation: 1, for: "d1")
            try await first.repo.close()
        }
        let f = try RepoFixture(root: root); defer { Task { await f.cleanUp() } }
        #expect(try await f.repo.document(id: "d1")?.chunkCount == 4)
    }

    @Test func aDocumentWithoutAnActiveGenerationGetsNoCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let first = try RepoFixture(root: root)
            try await first.repo.upsert(DocumentRecord(id: "d1", title: "Queued", type: .pdf))
            try await first.repo.close()
        }
        let f = try RepoFixture(root: root); defer { Task { await f.cleanUp() } }
        let record = try #require(try await f.repo.document(id: "d1"))
        #expect(record.chunkCount == nil)
        #expect(record.activeImageCount == nil)
    }
}
