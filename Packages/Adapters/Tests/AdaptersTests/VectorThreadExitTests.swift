@preconcurrency import CouchbaseLiteSwift
import Foundation
import Ports
import Testing
@testable import Adapters

/// The vector search extension's OpenMP runtime aborts the process when a thread that ran a vector query exits
/// (`__kmp_internal_end_thread` → `__kmp_free`). The app's crash reports show it on retired GCD worker threads.
@Suite(.serialized) struct VectorThreadExitTests {
    static let dims = 256
    static let vectors = 5_000
    static let searchesPerRound = 64
    static let rounds = 3

    static func randomUnit(_ seed: inout UInt64) -> [Float] {
        var v = (0..<dims).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
        }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        for i in v.indices { v[i] /= n }
        return v
    }

    /// Reproduces the crash on purpose: queries straight on threads that then exit, with an index the size of the app's.
    /// Expected to abort the test process, so it only runs with `RUN_CRASH_REPRO=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_CRASH_REPRO"] == "1"))
    func directQueryOnExitingThreadsAborts() throws {
        try CouchbaseBootstrap.enableVectorSearch()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cbl-thread-exit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = DatabaseConfiguration()
        config.directory = dir.path
        let db = try Database(name: "repro", config: config)
        defer { try? db.close() }
        let chunks = try db.createCollection(name: "chunks", scope: "manualbot")

        // As in the app: the index exists first, and is trained by the first query once it holds enough vectors.
        var index = VectorIndexConfiguration(
            expression: "embedding", dimensions: UInt32(Self.dims), centroids: CouchbaseSchema.centroids)
        index.metric = .cosine
        index.encoding = .scalarQuantizer(type: .SQ8)
        try chunks.createIndex(withName: "chunks_vec", config: index)
        var seed: UInt64 = 7
        var vectors: [[Float]] = []
        try db.inBatch {
            for i in 0..<Self.vectors {
                let v = Self.randomUnit(&seed)
                vectors.append(v)
                let doc = MutableDocument(id: "d:1:\(i)")
                doc.setValue(v, forKey: "embedding")
                try chunks.save(document: doc)
            }
        }

        let sql = """
            SELECT meta().id AS id FROM manualbot.chunks
            ORDER BY APPROX_VECTOR_DISTANCE(embedding, $vector, "cosine") LIMIT 1
            """
        let found = Counter()
        for round in 0..<Self.rounds {
            let done = DispatchGroup()
            // Half on threads that exit at once, half on GCD worker threads, which the system retires once idle.
            for i in 0..<Self.searchesPerRound {
                done.enter()
                let vector = vectors[(round * Self.searchesPerRound + i) * 7]
                let search: @Sendable () -> Void = {
                    defer { done.leave() }
                    guard let query = try? db.createQuery(sql) else { return }
                    query.parameters = Parameters().setValue(vector, forName: "vector")
                    if (try? query.execute().allResults().first) != nil { found.add() }
                }
                if i.isMultiple(of: 2) { Thread(block: search).start() } else { DispatchQueue.global().async(execute: search) }
            }
            done.wait()
            // The threads have returned; give them time to exit and run their OpenMP cleanup.
            Thread.sleep(forTimeInterval: 15)
        }
        #expect(found.value == Self.searchesPerRound * Self.rounds)
    }

    /// The same searches through the repository, from threads and tasks that end at once: they all run on the database
    /// thread, so no thread that ran vector work ever exits.
    @Test func repositorySearchesFromShortLivedThreadsAndTasks() async throws {
        let f = try RepoFixture(); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "A", title: "Doc A", type: .pdf))
        try await f.repo.writeChunks((0..<300).map { RepoFixture.chunk("A", 1, $0) })
        try await f.repo.activate(generation: 1, for: "A")
        let repo = f.repo
        let filter = SearchFilter(embeddingModel: RepoFixture.identity.tag)
        let nearest: @Sendable (Int) async -> String? = { hot in
            try? await repo.vectorSearch(RepoFixture.vector(hot), limit: 1, filter: filter).first?.chunk.id
        }

        let found = Counter()
        let threadsDone = DispatchGroup()
        for i in 0..<32 {
            threadsDone.enter()
            Thread {
                let finished = DispatchSemaphore(value: 0)
                Task {
                    if await nearest(i) == "A:1:\(i)" { found.add() }
                    finished.signal()
                }
                finished.wait()
                threadsDone.leave()
            }.start()
        }
        await withTaskGroup(of: Void.self) { group in
            for i in 32..<64 {
                group.addTask { if await nearest(i) == "A:1:\(i)" { found.add() } }
            }
        }
        await withCheckedContinuation { continuation in
            threadsDone.notify(queue: .global()) { continuation.resume() }
        }
        #expect(found.value == 64)

        // Long enough for the threads above to exit and idle workers to be retired.
        try await Task.sleep(for: .seconds(10))
        #expect(await nearest(100) == "A:1:100")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
