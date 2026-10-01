import CouchbaseLiteSwift
import Foundation
import Testing
@testable import Adapters

@Suite struct VectorSearchSpikeTests {
    static let dims = 768

    static func randomUnit(_ seed: inout UInt64) -> [Float] {
        var v = (0..<dims).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
        }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        for i in v.indices { v[i] /= n }
        return v
    }

    @Test func vectorIndexAnswersApproxDistanceQuery() throws {
        try CouchbaseBootstrap.enableVectorSearch()

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cbl-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var dbConfig = DatabaseConfiguration()
        dbConfig.directory = dir.path
        let db = try Database(name: "spike", config: dbConfig)
        defer { try? db.close() }
        let chunks = try db.createCollection(name: "chunks", scope: "manualbot")

        var seed: UInt64 = 42
        var vectors: [[Float]] = []
        try db.inBatch {
            for i in 0..<300 {
                let v = Self.randomUnit(&seed)
                vectors.append(v)
                let doc = MutableDocument(id: "d:1:\(i)")
                doc.setValue(v, forKey: "embedding")
                doc.setString("passage \(i)", forKey: "text")
                try chunks.save(document: doc)
            }
        }

        var cfg = VectorIndexConfiguration(expression: "embedding", dimensions: UInt32(Self.dims), centroids: 8)
        cfg.metric = .cosine
        cfg.encoding = .scalarQuantizer(type: .SQ8)
        try chunks.createIndex(withName: "chunks_vec", config: cfg)

        let sql = """
            SELECT meta().id AS id, APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine") AS dist
            FROM manualbot.chunks
            ORDER BY APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine")
            LIMIT 5
            """
        let query = try db.createQuery(sql)
        query.parameters = Parameters().setValue(vectors[123], forName: "vector")

        let plan = try query.explain()
        #expect(plan.contains("chunks_vec"), "query plan should use the vector index: \(plan)")

        let rows = try query.execute().allResults()
        #expect(rows.count == 5)
        #expect(rows.first?.string(forKey: "id") == "d:1:123")
        #expect((rows.first?.double(forKey: "dist") ?? 1) < 0.05)
    }
}
