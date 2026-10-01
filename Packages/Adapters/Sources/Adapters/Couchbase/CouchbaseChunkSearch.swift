@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports

/// Search over the passages of each ready document's active generation.
///
/// The index queries run with no `WHERE` clause on purpose. With one, Couchbase Lite must read every
/// candidate row to evaluate it (a vector query then scans all vectors; a full-text query parses every
/// match), which cost 160-330 ms at 20,000 passages against a few milliseconds without. Chunk IDs encode
/// `docId:generation:ordinal`, so visibility is checked from the ID alone; the query fetches extra
/// candidates and retries with a larger window if too few survive.
extension CouchbaseDocumentRepository: ChunkSearching {
    /// Candidates fetched before filtering, as a multiple of the requested limit.
    private static let firstWindow = 3
    private static let windowGrowth = 4
    private static let maxCandidates = 5_000

    public func vectorSearch(_ vector: [Float], limit: Int, filter: SearchFilter) throws -> [ScoredChunk] {
        guard limit > 0 else { return [] }
        let visible = try visibleGenerations(for: filter)
        guard !visible.isEmpty else { return [] }
        return try search(limit: limit, visible: visible, requireModel: filter.embeddingModel) { window, parameters in
            parameters.setValue(vector, forName: "vector")
            return """
                SELECT meta().id AS id, APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine") AS score
                FROM \(CouchbaseSchema.scope).chunks
                ORDER BY APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine")
                LIMIT \(window)
                """
        }
    }

    public func keywordSearch(terms: [String], limit: Int, filter: SearchFilter) throws -> [ScoredChunk] {
        let match = Self.matchExpression(for: terms)
        guard limit > 0, !match.isEmpty else { return [] }
        let visible = try visibleGenerations(for: filter)
        guard !visible.isEmpty else { return [] }
        return try search(limit: limit, visible: visible, requireModel: nil) { window, parameters in
            parameters.setString(match, forName: "match")
            return """
                SELECT meta().id AS id, RANK(\(CouchbaseSchema.ftsIndex)) AS score
                FROM \(CouchbaseSchema.scope).chunks
                WHERE MATCH(\(CouchbaseSchema.ftsIndex), $match)
                ORDER BY RANK(\(CouchbaseSchema.ftsIndex))
                LIMIT \(window)
                """
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
    private func visibleGenerations(for filter: SearchFilter) throws -> [String: Int] {
        try activeGenerations().filter { filter.documentIDs?.contains($0.key) ?? true }
    }

    /// Runs `makeSQL` with a growing candidate window until `limit` visible passages are found, or the
    /// index has nothing more to give.
    private func search(
        limit: Int, visible: [String: Int], requireModel: String?,
        makeSQL: (_ window: Int, _ parameters: Parameters) -> String
    ) throws -> [ScoredChunk] {
        var window = limit * Self.firstWindow
        while true {
            let parameters = Parameters()
            let query = try database.createQuery(makeSQL(window, parameters))
            query.parameters = parameters
            let rows = try query.execute().allResults()

            var found: [ScoredChunk] = []
            for row in rows {
                guard let id = row.string(forKey: "id"), let parts = Chunk.parseID(id),
                    visible[parts.docId] == parts.generation,
                    let doc = try collections.chunks.document(id: id)
                else { continue }
                let chunk = try Self.chunk(from: doc)
                if let requireModel, chunk.embeddingModel != requireModel { continue }
                found.append(ScoredChunk(chunk: chunk, score: row.double(forKey: "score")))
                if found.count == limit { return found }
            }
            let exhausted = rows.count < window          // the index returned everything it had
            if exhausted || window >= Self.maxCandidates { return found }
            window = min(window * Self.windowGrowth, Self.maxCandidates)
        }
    }
}
