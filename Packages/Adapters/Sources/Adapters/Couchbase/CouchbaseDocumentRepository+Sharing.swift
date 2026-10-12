@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports

/// What sync asks of the library: which documents are whole on this device, which cannot be shared, and the counts a
/// document records so that another device knows when its set has fully arrived.
///
/// A document that arrives from another device is searchable only once this device holds every chunk and image its active
/// set has. The record says how many that is (`chunkCount`, `activeImageCount`, written in the transaction that activates
/// the generation), and the three caches below keep checking it cheap: a search must not count rows for every document.
extension CouchbaseDocumentRepository {
    /// An active generation with the number of chunks and images the document record says it has. `revision` is the
    /// record's revision, so a record that is deleted and created again under the same ID is checked again.
    struct ActiveSet: Equatable {
        let generation: Int
        let chunks: Int?
        let images: Int?
        let revision: String?
    }

    /// What `refreshArrivals` reported as whole. Without the revision: a rename must not announce the document again.
    struct AnnouncedSet: Equatable {
        let generation: Int
        let chunks: Int
        let images: Int
    }

    /// Every document that has an active generation, as its record says, complete or not.
    func activeSets() throws -> [String: ActiveSet] {
        var result: [String: ActiveSet] = [:]
        let rows = try run(
            "SELECT meta().id AS id, meta().revisionID AS revision, activeGeneration AS generation, chunkCount AS chunks, "
                + "activeImageCount AS images FROM \(CouchbaseSchema.scope).documents WHERE activeGeneration IS NOT MISSING")
        for row in rows {
            guard let id = row.string(forKey: "id") else { continue }
            result[id] = ActiveSet(
                generation: row.int(forKey: "generation"),
                chunks: row.contains(key: "chunks") ? row.int(forKey: "chunks") : nil,
                images: row.contains(key: "images") ? row.int(forKey: "images") : nil,
                revision: row.string(forKey: "revision"))
        }
        return result
    }

    /// Whether this device holds the whole of `set`. A record written before the counts existed cannot be checked and
    /// counts as complete: that is how it behaved before sync.
    ///
    /// Both answers are remembered. A whole set stays whole until its record changes. An incomplete one is not counted
    /// again until `refreshArrivals` names the document, which the replicator does for everything it receives: counting
    /// two queries per arriving document on every search would cost the search its latency during a first sync.
    func isComplete(_ docId: String, _ set: ActiveSet) throws -> Bool {
        guard let chunks = set.chunks, let images = set.images else { return true }
        if completeSets[docId] == set { return true }
        if incompleteSets[docId] == set { return false }
        let haveChunks = try Self.count(CouchbaseSchema.chunks, in: database, docId: docId, generation: set.generation)
        let haveImages = try Self.count(CouchbaseSchema.images, in: database, docId: docId, generation: set.generation)
        guard haveChunks >= chunks, haveImages >= images else {
            incompleteSets[docId] = set
            return false
        }
        completeSets[docId] = set
        incompleteSets[docId] = nil
        return true
    }

    /// Drops what is remembered about documents that no longer have an active set.
    private func forget(except sets: [String: ActiveSet]) {
        completeSets = completeSets.filter { sets[$0.key] != nil }
        incompleteSets = incompleteSets.filter { sets[$0.key] != nil }
        announcedSets = announcedSets.filter { sets[$0.key] != nil }
    }

    /// `docId → active generation` for every document that has completed ingestion and whose set is whole on this device.
    /// Search and re-indexing look at these only: a set that is still arriving is neither searchable nor outdated.
    func activeGenerations() throws -> [String: Int] {
        let sets = try activeSets()
        forget(except: sets)
        var result: [String: Int] = [:]
        for (id, set) in sets {
            if try isComplete(id, set) { result[id] = set.generation }
        }
        return result
    }

    public func arrivingDocumentIDs() throws -> Set<String> {
        let sets = try activeSets()
        forget(except: sets)
        var arriving: Set<String> = []
        for (id, set) in sets {
            if try !isComplete(id, set) { arriving.insert(id) }
        }
        return arriving
    }

    public func refreshArrivals(of docIDs: Set<String>?) throws -> [String] {
        // First forget that these were incomplete, so that a failure below leaves them to be counted again, never stuck.
        if let docIDs {
            for id in docIDs { incompleteSets[id] = nil }
        } else {
            incompleteSets = [:]
        }
        let sets = try activeSets()
        forget(except: sets)
        var became: [String] = []
        for (id, set) in sets {
            guard docIDs?.contains(id) ?? true, let chunks = set.chunks, let images = set.images else { continue }
            let announced = AnnouncedSet(generation: set.generation, chunks: chunks, images: images)
            guard announcedSets[id] != announced else { continue }
            if try isComplete(id, set) {
                announcedSets[id] = announced
                became.append(id)
            }
        }
        return became.sorted()
    }

    // MARK: Counts

    /// Chunks or images of one generation held in this database. Not traced: it is bookkeeping, not a user operation.
    static func count(_ collection: String, in database: Database, docId: String, generation: Int) throws -> Int {
        let query = try database.createQuery(
            "SELECT COUNT(*) AS n FROM \(CouchbaseSchema.scope).\(collection) WHERE docId = $docId AND generation = $generation")
        query.parameters = Parameters().setString(docId, forName: "docId").setInt(generation, forName: "generation")
        return try query.execute().allResults().first?.int(forKey: "n") ?? 0
    }

    /// A document that was activated before the counts were recorded gets them from what this device holds, so a record
    /// that reaches the server always carries them. A document being re-indexed is not affected: its active generation
    /// is complete locally, and the counts describe that generation.
    static func backfillActiveCounts(in database: Database, documents: Collection) throws {
        let query = try database.createQuery(
            "SELECT meta().id AS id, activeGeneration AS generation FROM \(CouchbaseSchema.scope).documents "
                + "WHERE activeGeneration IS NOT MISSING AND chunkCount IS MISSING")
        for row in try query.execute().allResults() {
            guard let id = row.string(forKey: "id"), let doc = try documents.document(id: id)?.toMutable() else { continue }
            let generation = row.int(forKey: "generation")
            doc.setInt(try count(CouchbaseSchema.chunks, in: database, docId: id, generation: generation), forKey: "chunkCount")
            doc.setInt(try count(CouchbaseSchema.images, in: database, docId: id, generation: generation), forKey: "activeImageCount")
            try documents.save(document: doc)
        }
    }

    // MARK: Originals too large to share

    /// Documents whose stored original is larger than `limit` bytes. They stay on this device: sync does not send them.
    func documentsTooLargeToShare(over limit: Int64) throws -> [UnsharedDocument] {
        let query = try database.createQuery(
            "SELECT meta().id AS id, title, file.length AS bytes FROM \(CouchbaseSchema.scope).documents WHERE file.length > $maxBytes")
        query.parameters = Parameters().setInt64(limit, forName: "maxBytes")
        return try query.execute().allResults().compactMap { row in
            guard let id = row.string(forKey: "id") else { return nil }
            return UnsharedDocument(id: id, title: row.string(forKey: "title") ?? id, bytes: row.int64(forKey: "bytes"))
        }.sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }
}
