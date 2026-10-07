import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import Adapters

/// What the X-ray panel is told while a photo is imported, on the real database with fake models.
@Suite struct ImageTraceTests {
    let fx = Fixtures()
    private let features = FakeImageFeaturer()

    private func service(_ f: RepoFixture, tracer: any Tracer) -> IngestionService {
        IngestionService(
            extractor: FileDocumentExtractor(), embedder: FakeEmbedder(identity: RepoFixture.identity), repository: f.repo, jobs: f.repo,
            chunker: Chunker(), supportedType: FileDocumentExtractor.documentType(for:), tracer: tracer,
            imageFeatures: features, recognizer: FakeTextRecognizer(lines: ["MODEL X200-B"]))
    }

    private func label(_ kind: TraceKind) -> String? {
        switch kind {
        case .documentSaved(let collection, _): "saved:\(collection)"
        case .blobStored(_, let type, _): "blob:\(type)"
        case .jobState(_, let state, _, _): "job:\(state)"
        case .imageAnalyzed: "imageAnalyzed"
        case .imagesWritten: "imagesWritten"
        case .batchWritten(let collection, _, _): "batch:\(collection)"
        case .generationActivated: "activated"
        default: nil
        }
    }

    @Test func importingAPhotoReportsEachStepInOrder() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer, imageFeatures: features.identity); defer { Task { await f.cleanUp() } }
        let url = fx.imageFile(Fixtures.picture(width: 400, height: 300), type: .jpeg, name: "nameplate.jpg")
        let ingestion = service(f, tracer: tracer)
        let id = try await ingestion.enqueue(fileURL: url)
        await ingestion.run()

        let steps = tracer.kinds.compactMap(label)
        let expected = ["saved:documents", "blob:image/jpeg", "job:queued", "job:extracting", "job:analyzingImages", "imageAnalyzed",
                        "imagesWritten", "job:embedding", "batch:chunks", "saved:documents", "activated", "job:ready"]
        // Every step, in this order (job state reports may repeat while progress ticks).
        var cursor = steps.startIndex
        for step in expected {
            let found = steps[cursor...].firstIndex(of: step)
            #expect(found != nil, "missing or out of order: \(step) in \(steps)")
            cursor = found.map { steps.index(after: $0) } ?? cursor
        }

        let analyzed = try #require(tracer.kinds.first { if case .imageAnalyzed = $0 { true } else { false } })
        #expect(analyzed == .imageAnalyzed(docId: id, generation: 1, n: 0, ocrLength: 12, captionSource: "none", dimensions: features.identity.dimensions))
        let written = try #require(tracer.kinds.first { if case .imagesWritten = $0 { true } else { false } })
        guard case .imagesWritten(let collection, let count, let bytes, let dimensions) = written else { return }
        #expect(collection == "images" && count == 1 && bytes > 500 && dimensions == features.identity.dimensions)
        #expect(Set(tracer.events.compactMap(\.operation?.id)) == ["import-\(id)"])
    }

    @Test func reindexingReportsTheImagesRemovedInTheActivationStep() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer, imageFeatures: features.identity); defer { Task { await f.cleanUp() } }
        let url = fx.imageFile(Fixtures.picture(width: 400, height: 300), type: .jpeg, name: "nameplate.jpg")
        let ingestion = service(f, tracer: tracer)
        let id = try await ingestion.enqueue(fileURL: url)
        await ingestion.run()
        try await ingestion.reindex(docId: id)
        await ingestion.run()

        let activations = tracer.kinds.compactMap { kind -> (generation: Int, removed: Int, removedImages: Int)? in
            if case .generationActivated(_, let generation, let removed, let images) = kind { return (generation, removed, images) }
            return nil
        }
        #expect(activations.map(\.generation) == [1, 2])
        #expect(activations.map(\.removedImages) == [0, 1])
        #expect(activations.map(\.removed) == [0, 1])
    }

    @Test func deletingReportsTheImagesRemoved() async throws {
        let tracer = RecordingTracer()
        let f = try RepoFixture(tracer: tracer, imageFeatures: features.identity); defer { Task { await f.cleanUp() } }
        let url = fx.imageFile(Fixtures.picture(width: 400, height: 300), type: .jpeg, name: "nameplate.jpg")
        let ingestion = service(f, tracer: tracer)
        let id = try await ingestion.enqueue(fileURL: url)
        await ingestion.run()
        try await ingestion.delete(docId: id)
        #expect(tracer.kinds.contains(.documentDeleted(docId: id, chunksRemoved: 1, imagesRemoved: 1)))
    }

    @Test func aDisabledTracerSeesNothingOfAPhotoImport() async throws {
        let tracer = RecordingTracer(isEnabled: false)
        let f = try RepoFixture(tracer: tracer, imageFeatures: features.identity); defer { Task { await f.cleanUp() } }
        let url = fx.imageFile(Fixtures.picture(width: 400, height: 300), type: .jpeg, name: "nameplate.jpg")
        let ingestion = service(f, tracer: tracer)
        _ = try await ingestion.enqueue(fileURL: url)
        await ingestion.run()
        #expect(tracer.events.isEmpty)
    }
}
