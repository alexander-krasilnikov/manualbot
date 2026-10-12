@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports

/// Search over the chunks of each ready document's active generation.
///
/// The index queries run with no `WHERE` clause on purpose. With one, Couchbase Lite must read every
/// candidate row to evaluate it (a vector query then scans all vectors; a full-text query parses every
/// match), which cost 160-330 ms at 20,000 chunks against a few milliseconds without. Chunk IDs encode
/// `docId:generation:ordinal`, so visibility is checked from the ID alone; the query fetches extra
/// candidates and retries with a larger window if too few survive.
extension CouchbaseDocumentRepository: ChunkSearching {
    /// Candidates fetched before filtering, as a multiple of the requested limit.
    static let firstWindow = 3
    static let windowGrowth = 4
    static let maxCandidates = 5_000

    public func vectorSearch(_ vector: [Float], limit: Int, filter: SearchFilter) throws -> [ScoredChunk] {
        guard limit > 0 else { return [] }
        let visible = try visibleGenerations(for: filter)
        guard !visible.isEmpty else { return [] }
        return try searchChunks(limit: limit, visible: visible, requireModel: filter.embeddingModel, purpose: .vector) { window, parameters in
            parameters.setValue(vector, forName: "vector")
            let sql = """
                SELECT meta().id AS id, APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine") AS score
                FROM \(CouchbaseSchema.scope).chunks
                ORDER BY APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine")
                LIMIT \(window)
                """
            return (sql, tracer.isEnabled ? ["vector": TraceFormat.shorten(vector)] : [:])
        }
    }

    public func keywordSearch(terms: [String], limit: Int, filter: SearchFilter) throws -> [ScoredChunk] {
        let match = Self.matchExpression(for: terms)
        guard limit > 0, !match.isEmpty else { return [] }
        let visible = try visibleGenerations(for: filter)
        guard !visible.isEmpty else { return [] }
        return try searchChunks(limit: limit, visible: visible, requireModel: nil, purpose: .keyword) { window, parameters in
            parameters.setString(match, forName: "match")
            let sql = """
                SELECT meta().id AS id, RANK(\(CouchbaseSchema.ftsIndex)) AS score
                FROM \(CouchbaseSchema.scope).chunks
                WHERE MATCH(\(CouchbaseSchema.ftsIndex), $match)
                ORDER BY RANK(\(CouchbaseSchema.ftsIndex))
                LIMIT \(window)
                """
            return (sql, ["match": match])
        }
    }

    // MARK: Helpers

    /// Each term becomes a quoted phrase, so punctuation in codes (`E-042`) is never read as query syntax.
    static func matchExpression(for terms: [String]) -> String {
        terms
            .map { $0.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
    }

    /// `docId → active generation` for the documents a search may return from.
    func visibleGenerations(for filter: SearchFilter) throws -> [String: Int] {
        try activeGenerations().filter { filter.documentIDs?.contains($0.key) ?? true }
    }

    private func searchChunks(
        limit: Int, visible: [String: Int], requireModel: String?, purpose: QueryPurpose,
        makeSQL: (_ window: Int, _ parameters: Parameters) -> (sql: String, shown: [String: String])
    ) throws -> [ScoredChunk] {
        try search(
            in: collections.chunks, limit: limit, visible: visible, requireModel: requireModel, purpose: purpose,
            parseID: { Chunk.parseID($0).map { ($0.docId, $0.generation) } },
            load: { try Self.chunk(from: $0) }, model: \.embeddingModel, makeSQL: makeSQL
        ).map { ScoredChunk(chunk: $0.value, score: $0.score) }
    }

    /// Runs `makeSQL` with a growing candidate window until `limit` visible results are found, or the
    /// index has nothing more to give. Each run is reported as one query event with its row funnel.
    /// `requireModel` drops results whose recorded model tag differs.
    func search<T>(
        in collection: Collection, limit: Int, visible: [String: Int], requireModel: String?, purpose: QueryPurpose,
        parseID: (String) -> (docId: String, generation: Int)?, load: (Document) throws -> T, model: (T) -> String,
        makeSQL: (_ window: Int, _ parameters: Parameters) -> (sql: String, shown: [String: String])
    ) throws -> [(value: T, score: Double)] {
        var window = limit * Self.firstWindow
        while true {
            let parameters = Parameters()
            let (sql, shown) = makeSQL(window, parameters)
            let query = try database.createQuery(sql)
            query.parameters = parameters
            let (rows, seconds) = try timed { try query.execute().allResults() }

            var found: [(value: T, score: Double)] = []
            var notVisible = 0
            var wrongModel = 0
            for row in rows {
                guard let id = row.string(forKey: "id"), let parts = parseID(id),
                    visible[parts.docId] == parts.generation,
                    let doc = try collection.document(id: id)
                else { notVisible += 1; continue }
                let value = try load(doc)
                if let requireModel, model(value) != requireModel { wrongModel += 1; continue }
                found.append((value, row.double(forKey: "score")))
                if found.count == limit { break }
            }
            tracer.emit(duration: seconds, .query(QueryTrace(
                sql: sql, parameters: shown, purpose: purpose, returnedRows: rows.count,
                attempts: [FunnelAttempt(
                    window: window, returned: rows.count, notVisible: notVisible, wrongModel: wrongModel,
                    kept: found.count)])))
            if found.count == limit { return found }
            let exhausted = rows.count < window          // the index returned everything it had
            if exhausted || window >= Self.maxCandidates { return found }
            window = min(window * Self.windowGrowth, Self.maxCandidates)
        }
    }
}
