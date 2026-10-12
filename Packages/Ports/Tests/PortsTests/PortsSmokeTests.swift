import Ports
import PortsTesting
import Testing

@Suite struct PortsSmokeTests {
    @Test func fakeEmbedderIsDeterministicAndNormalized() async throws {
        let embedder = FakeEmbedder()
        let a = try await embedder.embed(["reset the unit"], kind: .query)
        let b = try await embedder.embed(["reset the unit"], kind: .query)
        #expect(a == b)
        #expect(a[0].count == embedder.identity.dimensions)
        let norm = a[0].reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 1e-5)
    }

    @Test func fakeEmbedderPutsSharedWordsCloser() async throws {
        let embedder = FakeEmbedder()
        let v = try await embedder.embed(
            ["hold the reset button", "press reset button", "replace the air filter"], kind: .query)
        func dot(_ x: [Float], _ y: [Float]) -> Float { zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(dot(v[0], v[1]) > dot(v[0], v[2]))
    }

    @Test func scriptedGeneratorStreamsFragmentsAndRecordsRequest() async throws {
        let generator = ScriptedGenerator(fragments: ["Hold ", "the button ", "[1]"])
        var out = ""
        for try await piece in generator.generate(GenerationRequest(system: "s", prompt: "p")) { out += piece }
        #expect(out == "Hold the button [1]")
        #expect(generator.callCount == 1)
        #expect(generator.requests.first?.prompt == "p")
    }

    @Test func scriptedGeneratorObservesCancellation() async throws {
        let generator = ScriptedGenerator(fragments: Array(repeating: "x", count: 10_000))
        let consumer = Task {
            var n = 0
            for try await _ in generator.generate(GenerationRequest(system: "", prompt: "")) {
                n += 1
                if n == 3 { break }
            }
            return n
        }
        #expect(try await consumer.value == 3)
        #expect(generator.cancellationCount == 1)
    }

    @Test func inMemoryRepositoryRoundTripsAndSwitchesGenerations() async throws {
        let repo = InMemoryDocumentRepository()
        let embedder = FakeEmbedder()
        try await repo.upsert(DocumentRecord(id: "d", title: "Doc", type: .pdf))
        func chunk(_ gen: Int, _ ord: Int) -> Chunk {
            Chunk(docId: "d", generation: gen, ordinal: ord, text: "t\(gen)\(ord)",
                  embedding: [Float](repeating: 0, count: 32), embeddingModel: embedder.identity.tag)
        }
        try await repo.writeChunks([chunk(1, 0), chunk(1, 1)])
        try await repo.activate(generation: 1, for: "d")
        try await repo.writeChunks([chunk(2, 0)])
        #expect(try await repo.activeChunks(docId: "d").count == 2)
        try await repo.activate(generation: 2, for: "d")
        #expect(try await repo.activeChunks(docId: "d").map(\.text) == ["t20"])
        #expect(try await repo.chunks(docId: "d", generation: 1).isEmpty)
        try await repo.deleteDocument(id: "d")
        #expect(try await repo.document(id: "d") == nil)
        #expect(try await repo.activeChunks(docId: "d").isEmpty)
    }
}
