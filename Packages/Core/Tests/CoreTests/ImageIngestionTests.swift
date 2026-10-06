import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Ports
import PortsTesting
import Synchronization
import Testing
@testable import Core

/// A picture of a given size and shade; the size doubles as a marker tests can recognize.
private func picture(width: Int = 200, height: Int = 200, shade: CGFloat = 0.5) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: shade, green: 1 - shade, blue: 0.3, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 1 - shade, green: shade, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    return context.makeImage()!
}

private func images(_ count: Int, page: Bool = true) -> [ExtractedImage] {
    (0..<count).map { i in
        ExtractedImage(image: picture(shade: CGFloat(i) / CGFloat(max(count, 1))), page: page ? i + 1 : nil)
    }
}

/// Behaves like `FakeImageFeaturer`, but stalls after N calls until cancelled (a run killed mid-analysis), and can refuse one picture size.
private final class GatedFeaturer: ImageFeaturing {
    let base = FakeImageFeaturer()
    var identity: EmbeddingModelIdentity { base.identity }
    private let stallAfter: Int?
    private let refuseWidth: Int?
    private let count = Mutex(0)

    init(stallAfterCalls: Int? = nil, refuseWidth: Int? = nil) {
        stallAfter = stallAfterCalls
        self.refuseWidth = refuseWidth
    }

    var calls: Int { count.withLock { $0 } }

    struct Refused: Error {}

    func features(of image: CGImage) async throws -> [Float] {
        let n = count.withLock { c -> Int in c += 1; return c }
        if let stallAfter, n > stallAfter { try await Task.sleep(for: .seconds(3600)) }
        if image.width == refuseWidth { throw Refused() }
        return try await base.features(of: image)
    }
}

private struct FailingRecognizer: TextRecognizing {
    struct Failed: Error {}
    func recognize(_ image: CGImage, correctLanguage: Bool) async throws -> [RecognizedLine] { throw Failed() }
}

private let smallChunks = Chunker(configuration: ChunkerConfiguration(targetTokens: 40, maxTokens: 70, overlapTokens: 10, minTailTokens: 15))

private func makeService(
    repo: InMemoryDocumentRepository, extractor: FakeExtractor, features: (any ImageFeaturing)? = FakeImageFeaturer(),
    recognizer: (any TextRecognizing)? = FakeTextRecognizer(), imageBatchSize: Int = 2, tracer: any Tracer = NoTracer()
) -> IngestionService {
    IngestionService(
        extractor: extractor, embedder: FakeEmbedder(), repository: repo, jobs: repo, chunker: smallChunks, batchSize: 4,
        supportedType: { url in ["txt": DocumentType.text, "pdf": .pdf, "jpg": .image][url.pathExtension.lowercased()] },
        tracer: tracer, imageFeatures: features, recognizer: recognizer, imageBatchSize: imageBatchSize)
}

private let manualText = ExtractedDocument(
    blocks: [Block(text: "Hold the reset button for ten seconds. The unit restarts.", page: 1)], pageCount: 5,
    images: images(5))

@Suite struct ImageIngestionTests {
    @Test func imagesAreStoredWithTheirAnalysisAndBecomeSearchableWithTheDocument() async throws {
        let repo = InMemoryDocumentRepository()
        let recognizer = FakeTextRecognizer(lines: ["MODEL X200-B", "230V"])
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["manual.pdf": .success(manualText)]), recognizer: recognizer)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/manual.pdf"))
        await service.run()

        #expect(try await repo.job(docId: id)?.state == .ready)
        let stored = try await repo.activeImages(docId: id)
        #expect(stored.map(\.n) == [0, 1, 2, 3, 4] && stored.map(\.page) == [1, 2, 3, 4, 5])
        let tag = FakeImageFeaturer().identity.tag
        #expect(stored.allSatisfy { $0.featureModel == tag && $0.features.count == FakeImageFeaturer().identity.dimensions })
        #expect(stored.allSatisfy { $0.ocrText == "MODEL X200-B 230V" && $0.width == 200 })
        let copy = try #require(try await repo.imageData(id: stored[0].id))
        #expect(copy.starts(with: [0xFF, 0xD8]))                      // JPEG

        let chunks = try await repo.activeChunks(docId: id)
        let imageChunks = chunks.filter { $0.imageId != nil }
        #expect(imageChunks.count == 5 && Set(imageChunks.compactMap(\.imageId)) == Set(stored.map(\.id)))
        #expect(imageChunks.allSatisfy { $0.text.contains("MODEL X200-B") && $0.embedding.count == FakeEmbedder().identity.dimensions })
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
        #expect(chunks.filter { $0.imageId == nil }.count == 1)
        #expect(recognizer.calls.allSatisfy { $0 == false })          // codes are never "corrected"
    }

    @Test func theImagePassageJoinsCaptionHeadingAndRecognizedText() async throws {
        let repo = InMemoryDocumentRepository()
        let doc = ExtractedDocument(
            blocks: [Block(text: "Install the pump carefully.", heading: "Installation")],
            images: [ExtractedImage(image: picture(), heading: "Installation", caption: "Figure 3: Filter housing", captionSource: .nearby)])
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(doc)]), recognizer: FakeTextRecognizer(lines: ["FH-220"]))
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        await service.run()
        let passage = try #require(try await repo.activeChunks(docId: id).first { $0.imageId != nil })
        #expect(passage.text == "Figure 3: Filter housing · Installation · FH-220")
        #expect(passage.heading == "Installation")
        let image = try #require(try await repo.activeImages(docId: id).first)
        #expect(image.caption == "Figure 3: Filter housing" && image.captionSource == .nearby)
    }

    @Test func aPhotoWithNoTextBecomesReadyWithOnePassageNamedAfterIt() async throws {
        let repo = InMemoryDocumentRepository()
        let doc = ExtractedDocument(blocks: [], images: [ExtractedImage(image: picture())])
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["pump front.jpg": .success(doc)]), recognizer: FakeTextRecognizer())
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/pump front.jpg"))
        await service.run()

        #expect(try await repo.job(docId: id)?.state == .ready)
        #expect(try await repo.document(id: id)?.type == .image)
        let chunks = try await repo.activeChunks(docId: id)
        #expect(chunks.map(\.text) == ["pump front"] && chunks.first?.imageId != nil)
        #expect(try await repo.activeImages(docId: id).count == 1)
    }

    @Test func aPhotoImportKeepsItsOriginalAsAnImage() async throws {
        let repo = InMemoryDocumentRepository()
        let doc = ExtractedDocument(blocks: [], images: [ExtractedImage(image: picture())])
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.jpg": .success(doc)]))
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.jpg"))
        #expect(try await repo.originalFileURL(docId: id)?.lastPathComponent == "a.jpg")
    }

    @Test func aDocumentWithNeitherTextNorImagesStillFails() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["blank.pdf": .success(ExtractedDocument(blocks: []))]))
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/blank.pdf"))
        await service.run()
        #expect(try await repo.job(docId: id)?.state == .failed)
        #expect(try await repo.job(docId: id)?.error == IngestionError.noText.errorDescription)
    }

    @Test func anImageThatCannotBeAnalyzedIsSkippedWithoutFailingTheDocument() async throws {
        let repo = InMemoryDocumentRepository()
        let doc = ExtractedDocument(
            blocks: [Block(text: "Some text about the pump.")],
            images: [ExtractedImage(image: picture(width: 200)), ExtractedImage(image: picture(width: 170)), ExtractedImage(image: picture(width: 220))])
        let service = makeService(
            repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(doc)]), features: GatedFeaturer(refuseWidth: 170))
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        await service.run()
        #expect(try await repo.job(docId: id)?.state == .ready)
        #expect(try await repo.activeImages(docId: id).map(\.n) == [0, 2])
        #expect(try await repo.activeChunks(docId: id).filter { $0.imageId != nil }.count == 2)
    }

    @Test func anImageWhoseTextCannotBeReadIsStillKept() async throws {
        let repo = InMemoryDocumentRepository()
        let doc = ExtractedDocument(blocks: [Block(text: "Some text.")], images: [ExtractedImage(image: picture(), caption: "Pump")])
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(doc)]), recognizer: FailingRecognizer())
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        await service.run()
        #expect(try await repo.job(docId: id)?.state == .ready)
        let image = try #require(try await repo.activeImages(docId: id).first)
        #expect(image.ocrText.isEmpty && image.caption == "Pump")
    }

    @Test func aPhotoImportedWhereImageAnalysisIsUnavailableFailsWithAClearReason() async throws {
        let repo = InMemoryDocumentRepository()
        let doc = ExtractedDocument(blocks: [], images: [ExtractedImage(image: picture())])
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.jpg": .success(doc)]), features: nil, recognizer: nil)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.jpg"))
        await service.run()
        #expect(try await repo.job(docId: id)?.state == .failed)
        #expect(try await repo.job(docId: id)?.error == "Photos cannot be analyzed on this device.")
    }

    @Test func withoutImageAnalysisConfiguredImagesAreIgnoredAndTextStillIndexes() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(manualText)]), features: nil, recognizer: nil)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        await service.run()
        #expect(try await repo.job(docId: id)?.state == .ready)
        #expect(try await repo.activeImages(docId: id).isEmpty)
        #expect(try await repo.activeChunks(docId: id).allSatisfy { $0.imageId == nil })
    }

    @Test func statusPassesThroughAnalyzingImagesBeforeEmbedding() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(manualText)]))
        let stream = await service.updates()
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        await service.run()
        var states: [IngestState] = []
        var imageProgress: [Double] = []
        for await job in stream where job.docId == id {
            if states.last != job.state { states.append(job.state) }
            if job.state == .analyzingImages { imageProgress.append(job.progress) }
            if job.state == .ready { break }
        }
        #expect(states == [.queued, .extracting, .analyzingImages, .embedding, .ready])
        #expect(imageProgress == imageProgress.sorted() && imageProgress.last == 1)
    }

    @Test func killedRunResumesWithExactlyOneSetOfImages() async throws {
        let repo = InMemoryDocumentRepository()
        let extractor = FakeExtractor(results: ["big.pdf": .success(manualText)])
        let stalling = GatedFeaturer(stallAfterCalls: 3)
        let first = makeService(repo: repo, extractor: extractor, features: stalling)
        let id = try await first.enqueue(fileURL: URL(fileURLWithPath: "/in/big.pdf"))

        let task = Task { await first.run() }
        while stalling.calls < 4 { try await Task.sleep(for: .milliseconds(5)) }       // the fourth image stalls
        task.cancel()
        await task.value

        let interrupted = try #require(try await repo.job(docId: id))
        #expect(interrupted.state != .ready && interrupted.state != .failed)
        #expect(interrupted.nextImage == 2)                                              // one batch of two was stored
        #expect(try await repo.images(docId: id, generation: 1).count == 2)
        #expect(try await repo.activeImages(docId: id).isEmpty)                          // nothing visible yet

        let healthy = GatedFeaturer()
        let second = makeService(repo: repo, extractor: extractor, features: healthy)
        await second.run()

        let stored = try await repo.activeImages(docId: id)
        #expect(stored.map(\.n) == [0, 1, 2, 3, 4] && Set(stored.map(\.id)).count == 5)
        #expect(healthy.calls == 3, "only the unfinished images are analyzed again")
        let passages = try await repo.activeChunks(docId: id).filter { $0.imageId != nil }
        #expect(passages.count == 5 && Set(passages.compactMap(\.imageId)).count == 5)
        #expect(try await repo.job(docId: id)?.state == .ready)
    }

    @Test func pausingHoldsBackImageAnalysisUntilResumed() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(manualText)]))
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        await service.setPaused(true)
        let run = Task { await service.run() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await repo.images(docId: id, generation: 1).isEmpty)
        #expect(try await repo.job(docId: id)?.state == .analyzingImages)

        await service.setPaused(false)
        await run.value
        #expect(try await repo.activeImages(docId: id).count == 5)
    }

    @Test func reindexReplacesTheImagesAfterTheNewSetIsReady() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(manualText)]))
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        await service.run()
        #expect(try await repo.activeImages(docId: id).map(\.generation) == Array(repeating: 1, count: 5))

        try await service.reindex(docId: id)
        await service.run()
        #expect(try await repo.activeImages(docId: id).map(\.generation) == Array(repeating: 2, count: 5))
        #expect(try await repo.images(docId: id, generation: 1).isEmpty)
        #expect(try await repo.job(docId: id)?.nextImage == 5)
    }

    @Test func deletingWhileImagesAreBeingAnalyzedLeavesNothingBehind() async throws {
        let repo = InMemoryDocumentRepository()
        let stalling = GatedFeaturer(stallAfterCalls: 2)
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(manualText)]), features: stalling)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        let run = Task { await service.run() }
        while stalling.calls < 3 { try await Task.sleep(for: .milliseconds(5)) }
        run.cancel()
        await run.value
        try await service.delete(docId: id)
        #expect(try await repo.images(docId: id, generation: 1).isEmpty)
        #expect(try await repo.document(id: id) == nil)
    }
}

@Suite struct ImageIngestionTraceTests {
    @Test func aPhotoImportReportsItsStepsInOrderUnderOneOperation() async throws {
        let repo = InMemoryDocumentRepository()
        let tracer = RecordingTracer()
        let doc = ExtractedDocument(blocks: [], images: [ExtractedImage(image: picture(), caption: "Pump", captionSource: .alt)])
        let service = makeService(
            repo: repo, extractor: FakeExtractor(results: ["pump.jpg": .success(doc)]),
            recognizer: FakeTextRecognizer(lines: ["MODEL X200-B"]), tracer: tracer)
        let id = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/pump.jpg"))
        await service.run()

        let steps = tracer.kinds.compactMap { kind -> String? in
            switch kind {
            case .jobState(_, let state, _, _): "job:\(state)"
            case .imageAnalyzed: "analyzed"
            default: nil
            }
        }
        #expect(steps == ["job:queued", "job:extracting", "job:analyzingImages", "analyzed", "job:analyzingImages", "job:embedding", "job:ready"]
            || steps == ["job:queued", "job:extracting", "job:analyzingImages", "analyzed", "job:embedding", "job:ready"])
        let analyzed = try #require(tracer.kinds.first { if case .imageAnalyzed = $0 { true } else { false } })
        #expect(analyzed == .imageAnalyzed(
            docId: id, generation: 1, n: 0, ocrLength: "MODEL X200-B".count, captionSource: "alt", dimensions: FakeImageFeaturer().identity.dimensions))
        let operations = Set(tracer.events.compactMap(\.operation?.id))
        #expect(operations == ["import-\(id)"])
    }

    @Test func aDisabledTracerSeesNoImageEvents() async throws {
        let repo = InMemoryDocumentRepository()
        let tracer = RecordingTracer(isEnabled: false)
        let doc = ExtractedDocument(blocks: [], images: [ExtractedImage(image: picture())])
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.jpg": .success(doc)]), tracer: tracer)
        _ = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.jpg"))
        await service.run()
        #expect(tracer.events.isEmpty)
    }
}

@Suite struct DisplayCopyTests {
    @Test func aLargePictureIsShrunkToTheLongEdgeAndEncodedAsJPEGWithoutMetadata() throws {
        let data = try DisplayCopy.jpeg(from: picture(width: 4000, height: 3000), maxSide: 1600)
        #expect(data.starts(with: [0xFF, 0xD8]))
        let decoded = try #require(PhotoData.image(from: data))
        #expect(decoded.width == 1600 && decoded.height == 1200)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        // ImageIO adds a bare Exif block with the pixel size; nothing about where, when or with what it was taken.
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil && exif[kCGImagePropertyExifLensModel] == nil)
        #expect(tiff[kCGImagePropertyTIFFMake] == nil && tiff[kCGImagePropertyTIFFModel] == nil && tiff[kCGImagePropertyTIFFDateTime] == nil)
    }

    @Test func aSmallPictureKeepsItsSize() throws {
        let decoded = try #require(PhotoData.image(from: try DisplayCopy.jpeg(from: picture(width: 300, height: 200))))
        #expect(decoded.width == 300 && decoded.height == 200)
    }

    @Test func photoDataAppliesTheOrientationAndLimitsTheSize() throws {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, picture(width: 400, height: 200), [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let upright = try #require(PhotoData.image(from: data as Data))
        #expect(upright.width == 200 && upright.height == 400)
        let small = try #require(PhotoData.image(from: data as Data, maxPixelSize: 100))
        #expect(max(small.width, small.height) == 100)
        #expect(PhotoData.image(from: Data("nope".utf8)) == nil)
    }

    @Test func theLibraryRecordsHowManyPhotosADocumentHas() async throws {
        let repo = InMemoryDocumentRepository()
        let service = makeService(repo: repo, extractor: FakeExtractor(results: ["a.pdf": .success(manualText), "b.pdf": .success(ExtractedDocument(blocks: [Block(text: "Only text here.")]))]))
        let withPhotos = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/a.pdf"))
        let without = try await service.enqueue(fileURL: URL(fileURLWithPath: "/in/b.pdf"))
        await service.run()
        #expect(try await repo.document(id: withPhotos)?.imageCount == 5)
        #expect(try await repo.document(id: without)?.imageCount == nil)
    }
}
