import Foundation
import Ports
import Testing
@testable import Adapters

/// An actor on the database thread, standing in for the repository.
private actor OnDatabaseThread {
    nonisolated var unownedExecutor: UnownedSerialExecutor { DatabaseThread.shared.asUnownedSerialExecutor() }

    private(set) var order: [Int] = []
    private var threads: Set<ObjectIdentifier> = []

    func record(_ n: Int) {
        order.append(n)
        threads.insert(ObjectIdentifier(Thread.current))
    }

    /// Starts `count` tasks from inside the actor. None can run before this returns, so they queue in creation order.
    func enqueueInOrder(_ count: Int) -> [Task<Void, Never>] {
        (0..<count).map { n in Task { self.record(n) } }
    }

    var onDatabaseThread: Bool { DatabaseThread.shared.isCurrent }
    var threadCount: Int { threads.count }
}

private struct Boom: Error, Equatable {}

@Suite struct DatabaseThreadTests {
    @Test func jobsRunInOrderOnTheDatabaseThread() async {
        let actor = OnDatabaseThread()
        for task in await actor.enqueueInOrder(200) { await task.value }
        #expect(await actor.order == Array(0..<200))
        #expect(await actor.onDatabaseThread)
    }

    @Test func oneThreadServesJobsFromManyDetachedTasks() async {
        let actor = OnDatabaseThread()
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<1_000 { group.addTask { await actor.record(n) } }
        }
        #expect(await actor.order.count == 1_000)
        #expect(await actor.threadCount == 1)
    }

    @Test func runAndWaitReturnsTheValueFromTheDatabaseThread() throws {
        #expect(!DatabaseThread.shared.isCurrent)
        let ran = try DatabaseThread.shared.runAndWait { DatabaseThread.shared.isCurrent }
        #expect(ran)
    }

    @Test func runAndWaitRethrows() {
        #expect(throws: Boom()) { try DatabaseThread.shared.runAndWait { throw Boom() } }
    }

    // MARK: The repository

    @Test func theRepositoryWritesAndSearchesOnTheDatabaseThread() async throws {
        let tracer = ThreadCheckingTracer()
        let f = try RepoFixture(tracer: tracer); defer { Task { await f.cleanUp() } }
        try await f.repo.upsert(DocumentRecord(id: "A", title: "Doc A", type: .pdf))
        try await f.repo.writeChunks((0..<20).map { RepoFixture.chunk("A", 1, $0) })
        try await f.repo.writeImages((0..<5).map { CouchbaseImageTests.image("A", 1, $0) })
        try await f.repo.activate(generation: 1, for: "A")
        _ = try await f.repo.vectorSearch(RepoFixture.vector(3), limit: 5, filter: SearchFilter(embeddingModel: RepoFixture.identity.tag))
        _ = try await f.repo.imageSearch(
            RepoFixture.vector(3), limit: 5, filter: SearchFilter(embeddingModel: CouchbaseImageTests.featureTag))
        _ = try await f.repo.documentIDs(collection: CouchbaseSchema.chunks, after: nil, containing: nil, limit: 10)

        let kinds = tracer.kinds
        #expect(kinds.contains("batchWritten") && kinds.contains("imagesWritten"))
        #expect(kinds.filter { $0 == "query" }.count >= 3)
        #expect(tracer.offThread.isEmpty, "ran off the database thread: \(tracer.offThread)")
    }
}

/// Notes, for every event, whether it was emitted on the database thread.
private final class ThreadCheckingTracer: Tracer, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(kind: String, onThread: Bool)] = []

    var isEnabled: Bool { true }

    func record(_ event: TraceEvent) {
        let kind = String(describing: event.kind).prefix { $0 != "(" }
        let onThread = DatabaseThread.shared.isCurrent
        lock.withLock { seen.append((String(kind), onThread)) }
    }

    var kinds: [String] { lock.withLock { seen.map(\.kind) } }
    var offThread: [String] { lock.withLock { seen.filter { !$0.onThread }.map(\.kind) } }
}
