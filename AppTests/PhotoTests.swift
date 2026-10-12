import Adapters
import CoreGraphics
import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

private let photoScratch = FileManager.default.temporaryDirectory.appendingPathComponent("photo-tests-\(UUID().uuidString)")

private func write(_ data: Data, as name: String) throws -> URL {
    try FileManager.default.createDirectory(at: photoScratch, withIntermediateDirectories: true)
    let url = photoScratch.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

// MARK: - Library

@MainActor @Suite struct PhotoLibraryTests {
    private func make(extractor: any DocumentExtractor = FileDocumentExtractor()) -> (LibraryViewModel, InMemoryDocumentRepository) {
        let repo = InMemoryDocumentRepository()
        let ingestion = IngestionService(
            extractor: extractor, embedder: FakeEmbedder(), repository: repo, jobs: repo,
            supportedType: FileDocumentExtractor.documentType(for:),
            imageFeatures: FakeImageFeaturer(), recognizer: FakeTextRecognizer(lines: ["MODEL X200-B"]))
        return (LibraryViewModel(documents: repo, jobs: repo, ingestion: ingestion), repo)
    }

    @Test func importingAJPEGMakesAPhotoDocumentThatBecomesReadyWithAThumbnail() async throws {
        let (library, _) = make()
        let jpeg = try write(SampleDocuments.x200Nameplate, as: "Nameplate.jpg")
        let deck = try write(Data("x".utf8), as: "deck.pptx")
        await library.importFiles([jpeg, deck])

        #expect(library.rejections.count == 1 && library.rejections[0].contains("deck.pptx"))
        #expect(await eventually { await library.refresh(); return library.items.first?.status == .ready })
        let item = try #require(library.items.first)
        #expect(item.title == "Nameplate" && item.type == .image && item.imageCount == 1)
        let thumbnail = try #require(await library.thumbnail(for: item.id))
        #expect(thumbnail.starts(with: [0xFF, 0xD8]))
        #expect(await library.thumbnail(for: "nothing") == nil)
    }

    @Test func aDocumentThatContainsPhotosReportsHowManyItHas() async throws {
        let picture = try #require(PhotoData.image(from: SampleDocuments.x200Nameplate))
        let extractor = FakeExtractor(results: ["manual.pdf": .success(ExtractedDocument(
            blocks: [Block(text: "Text about the pump.", page: 1)], pageCount: 1,
            images: [ExtractedImage(image: picture, page: 1), ExtractedImage(image: picture, page: 1)]))])
        let (library, _) = make(extractor: extractor)
        await library.importFiles([try write(Data("%PDF".utf8), as: "manual.pdf")])
        #expect(await eventually { await library.refresh(); return library.items.first?.status == .ready })
        #expect(library.items.first?.imageCount == 2 && library.items.first?.type == .pdf)
    }

    @Test func statusShowsPhotoAnalysisWhileTheDocumentIsNotYetSearchable() {
        let fresh = DocumentRecord(id: "d", title: "T", type: .pdf)
        let indexed = DocumentRecord(id: "d", title: "T", type: .pdf, activeGeneration: 1)
        let job = IngestJobRecord(docId: "d", targetGeneration: 1, state: .analyzingImages, progress: 0.4)
        #expect(LibraryViewModel.status(of: fresh, job: job) == .analyzing(0.4))
        #expect(LibraryViewModel.status(of: indexed, job: job) == .updating(0.4), "searchable from the old index meanwhile")
        #expect(LibraryViewModel.Status.analyzing(0.4).isWorking && !LibraryViewModel.Status.analyzing(0.4).isReady)
    }

    @Test func theTypeLabelNamesPhotos() {
        #expect(LibraryRow.label(for: .image) == "Photo" && LibraryRow.label(for: .pdf) == "PDF")
    }

    @Test func thePickerOffersTheSupportedPhotoTypesAndNoOthers() {
        let types = SupportedTypes.picker.map(\.identifier)
        for expected in ["public.jpeg", "public.png", "public.heic", "public.heif"] { #expect(types.contains(expected), "\(expected)") }
        #expect(!types.contains("com.compuserve.gif"))
    }
}

// MARK: - Chat

/// Manual "Service" has a photo on page 3 beside a text chunk. Searches and image matches are scripted.
@MainActor private struct PhotoChatHarness {
    let repo = InMemoryDocumentRepository()
    let search = FakeChunkSearch()
    let imageSearch: FakeImageSearch
    let ingestion: IngestionService
    let model: ChatViewModel
    let photo: ImageRecord
    let generator: ScriptedGenerator

    init(imageDistance: Double? = 0.2, answer: [String] = ["Descale it every six months [1]."]) async throws {
        let features = FakeImageFeaturer()
        let embedder = FakeEmbedder()
        let record = ImageRecord(
            docId: "doc", generation: 1, n: 0, page: 3, heading: "Maintenance", caption: "Figure 1: Nameplate", captionSource: .nearby,
            width: 300, height: 200, features: [Float](repeating: 0, count: features.identity.dimensions), featureModel: features.identity.tag)
        photo = record
        ingestion = IngestionService(extractor: FakeExtractor(results: [:]), embedder: embedder, repository: repo, jobs: repo, supportedType: { _ in .text })
        model = ChatViewModel(chats: repo, documents: repo, ingestion: ingestion)
        let text = Chunk(docId: "doc", generation: 1, ordinal: 0, page: 3, heading: "Maintenance", text: "Descale the X200 every six months.",
                         embedding: [], embeddingModel: embedder.identity.tag)
        let own = Chunk(docId: "doc", generation: 1, ordinal: 1, page: 3, heading: "Maintenance", text: "Figure 1: Nameplate",
                        embedding: [], embeddingModel: embedder.identity.tag, imageId: record.id)
        try await repo.upsert(DocumentRecord(id: "doc", title: "Service", type: .pdf, activeGeneration: nil))
        try await repo.writeChunks([text, own])
        try await repo.writeImages([ImageWrite(record: record, displayCopy: try DisplayCopy.jpeg(from: PhotoData.image(from: SampleDocuments.x200Nameplate)!))])
        try await repo.activate(generation: 1, for: "doc")
        search.vectorHits = [ScoredChunk(chunk: text, score: 0.3)]
        imageSearch = FakeImageSearch(hits: imageDistance.map { [ScoredImage(image: record, score: $0)] } ?? [])
        generator = ScriptedGenerator { $0.maxTokens == 64 ? ["standalone"] : answer }
        let retriever = Retriever(
            embedder: embedder, search: search, repository: repo,
            photoSearch: PhotoSearch(features: features, search: imageSearch, recognizer: FakeTextRecognizer(lines: ["MODEL X200-B"])))
        model.attach(ChatService(chats: repo, retriever: retriever, generator: generator))
        model.updateDocuments([.init(id: "doc", title: "Service", type: .pdf, pageCount: 3, importedAt: Date(), status: .ready)])
    }
}

@MainActor @Suite struct PhotoChatViewModelTests {
    @Test func aPhotoAloneCanBeSentAndAnswersWithMatches() async throws {
        let h = try await PhotoChatHarness()
        #expect(!h.model.canSend)
        h.model.attach(photo: SampleDocuments.x200Nameplate)
        #expect(h.model.canSend && h.model.draft.isEmpty && h.model.attachedPhoto != nil)

        await h.model.send()
        #expect(h.model.attachedPhoto == nil, "the photo goes with the question and is not kept in the input")
        #expect(h.model.messages.map(\.role) == [.user, .assistant])
        let question = h.model.messages[0], reply = h.model.messages[1]
        #expect(question.hasAttachment && question.text.isEmpty)
        #expect(reply.matchesOnly && reply.imageMatches.map(\.imageId) == [h.photo.id])
        #expect(h.generator.callCount == 0)
        #expect(h.model.current?.title == "Photo question")
        let shown = try #require(await h.model.photos.attachment(question))
        #expect(shown.starts(with: [0xFF, 0xD8]))
    }

    @Test func aPhotoWithAQuestionIsAnsweredFromTheDocuments() async throws {
        let h = try await PhotoChatHarness()
        h.model.draft = "how do I descale it?"
        h.model.attach(photo: SampleDocuments.x200Nameplate)
        await h.model.send()
        let reply = try #require(h.model.messages.last)
        #expect(!reply.matchesOnly && !reply.notFound && reply.citations.first?.page == 3)
        #expect(reply.imageMatches.count == 1)
        #expect(h.generator.callCount == 1)
    }

    @Test func aFileThatIsNotAPhotoIsRefusedAndAPhotoCanBeTakenBack() async throws {
        let h = try await PhotoChatHarness()
        h.model.attach(photo: Data("not an image".utf8))
        #expect(h.model.attachedPhoto == nil && h.model.errorMessage != nil)
        h.model.attach(photo: SampleDocuments.x200Nameplate)
        #expect(h.model.errorMessage == nil && h.model.attachedPhoto != nil)
        h.model.removePhoto()
        #expect(h.model.attachedPhoto == nil && !h.model.canSend)
    }

    @Test func aMessageWithoutAPhotoHasNoAttachment() async throws {
        let h = try await PhotoChatHarness()
        h.model.draft = "how do I descale it?"
        await h.model.send()
        #expect(h.model.messages.first?.hasAttachment == false)
        #expect(await h.model.photos.attachment(h.model.messages[0]) == nil)
    }

    @Test func thePhotosOnACitedPageAreFoundByPageHeadingAndChunk() async throws {
        let h = try await PhotoChatHarness()
        func citation(page: Int? = nil, heading: String? = nil, imageId: String? = nil) -> Citation {
            Citation(n: 1, chunkId: "c", docId: "doc", docTitle: "Service", page: page, heading: heading, snippet: "", imageId: imageId)
        }
        #expect(await h.model.photos.cited(citation(page: 3)).map(\.id) == [h.photo.id])
        #expect(await h.model.photos.cited(citation(heading: "Maintenance")).map(\.id) == [h.photo.id])
        #expect(await h.model.photos.cited(citation(page: 9, imageId: h.photo.id)).map(\.id) == [h.photo.id], "a cited photo chunk shows its photo")
        #expect(await h.model.photos.cited(citation(page: 9)).isEmpty)
        #expect(await h.model.photos.cited(citation(heading: "")).isEmpty)
    }

    @Test func aMatchedPhotoOfADeletedDocumentIsMarkedAndHasNoPicture() async throws {
        let h = try await PhotoChatHarness()
        let match = ImageMatch(imageId: h.photo.id, docId: "doc", docTitle: "Service", page: 3, distance: 0.2)
        let present = await h.model.photos.matched(match)
        #expect(present.data != nil && !present.documentDeleted)

        await h.repo.deleteDocument(id: "doc")
        let gone = await h.model.photos.matched(match)
        #expect(gone == MatchThumbnail(data: nil, documentDeleted: true))
    }

    @Test func theRealAppHasNoStubPhotoAndPhotosAreOfferedUnlessTheDeviceCannotAnalyzeThem() async throws {
        let h = try await PhotoChatHarness()
        #expect(h.model.stubPhoto == nil && h.model.photosAvailable)
    }
}

// MARK: - Source viewer

@MainActor @Suite struct PhotoSourceTests {
    @Test func anImportedPhotoOpensInTheImageViewer() async throws {
        let repo = InMemoryDocumentRepository()
        let url = try write(SampleDocuments.x200Nameplate, as: "plate.jpg")
        try await repo.upsert(DocumentRecord(id: "p", title: "Nameplate", type: .image, activeGeneration: 1))
        try await repo.attachOriginal(fileURL: url, contentType: "image/jpeg", to: "p")
        let model = SourceViewerModel(documents: repo, extractor: FileDocumentExtractor())

        await model.open(Citation(n: 1, chunkId: "p:1:0", docId: "p", docTitle: "Nameplate", snippet: "MODEL X200-B", imageId: "p:1:img:0"))
        #expect(model.content == .image(url: url, title: "Nameplate"))
        await model.openDocument("p")
        #expect(model.content == .image(url: url, title: "Nameplate"))
    }

    @Test func aPhotoInAWordDocumentShowsTheHeadingItSitsUnder() async throws {
        let repo = InMemoryDocumentRepository()
        let url = try write(Data("docx".utf8), as: "guide.docx")
        try await repo.upsert(DocumentRecord(id: "w", title: "Guide", type: .docx, activeGeneration: 1))
        try await repo.attachOriginal(fileURL: url, contentType: "application/docx", to: "w")
        let extractor = FakeExtractor(results: ["guide.docx": .success(ExtractedDocument(blocks: [
            Block(text: "Overview", kind: .heading, heading: "Overview"), Block(text: "Intro text.", heading: "Overview"),
            Block(text: "Installation", kind: .heading, heading: "Installation"), Block(text: "Mount the pump.", heading: "Installation"),
        ]))])
        let model = SourceViewerModel(documents: repo, extractor: extractor)

        await model.open(Citation(n: 1, chunkId: "w:1:5", docId: "w", docTitle: "Guide", heading: "Installation", snippet: "", imageId: "w:1:img:0"))
        guard case .text(_, _, let highlighted) = model.content else { Issue.record("expected text"); return }
        #expect(highlighted == [2])

        // A plain citation with no chunk text marks nothing.
        await model.open(Citation(n: 1, chunkId: "w:1:5", docId: "w", docTitle: "Guide", heading: "Installation", snippet: ""))
        guard case .text(_, _, let none) = model.content else { Issue.record("expected text"); return }
        #expect(none.isEmpty)
    }

    @Test func aPhotoFoundInAPdfOpensThePageItIsOn() async throws {
        let repo = InMemoryDocumentRepository()
        let pdf = try write(SampleDocuments.makeServiceManual(), as: "service.pdf")
        try await repo.upsert(DocumentRecord(id: "s", title: "Service", type: .pdf, pageCount: 3, activeGeneration: 1))
        try await repo.attachOriginal(fileURL: pdf, contentType: "application/pdf", to: "s")
        let model = SourceViewerModel(documents: repo, extractor: FileDocumentExtractor())
        await model.open(Citation(n: 0, chunkId: "", docId: "s", docTitle: "Service", page: 2, snippet: "", imageId: "s:1:img:0"))
        #expect(model.content == .pdf(url: pdf, page: 2, chunk: "", title: "Service"))
    }
}

// MARK: - X-ray text

@MainActor @Suite struct PhotoXrayTextTests {
    @Test func imageEventsHaveTitlesAndDetails() {
        let analyzed = TraceKind.imageAnalyzed(docId: "d", generation: 1, n: 0, ocrLength: 31, captionSource: "alt", dimensions: 768)
        #expect(XrayText.title(for: analyzed) == "Read photo 1")
        #expect(XrayText.detail(for: analyzed) == "31 characters of text found · caption: the author's description · 768-dimension vector")
        let written = TraceKind.imagesWritten(collection: "images", count: 2, blobBytes: 40_000, dimensions: 768)
        #expect(XrayText.title(for: written) == "Wrote 2 photos in one transaction")
        #expect(XrayText.detail(for: written)?.contains("images · ") == true && XrayText.detail(for: written)?.contains("768-dimension") == true)
        let photo = TraceKind.photoAnalyzed(recognizedLength: 40, identifiers: ["X200-B", "4471-22"], dimensions: 768)
        #expect(XrayText.title(for: photo) == "Read the photo you sent")
        #expect(XrayText.detail(for: photo) == "40 characters of text · identifiers: X200-B, 4471-22 · 768-dimension vector")
        #expect(analyzed.tag == .imageAnalyzed && written.tag == .imagesWritten && photo.tag == .photoAnalyzed)
    }

    @Test func activationAndDeletionCountPhotosOnlyWhenThereAreSome() {
        #expect(XrayText.detail(for: .generationActivated(docId: "d", generation: 2, removed: 3, removedImages: 2))
            == "removed 3 chunks and 2 photos from the older set in the same transaction")
        #expect(XrayText.detail(for: .generationActivated(docId: "d", generation: 2, removed: 3)) == "removed 3 chunks from the older set in the same transaction")
        #expect(XrayText.detail(for: .generationActivated(docId: "d", generation: 1, removed: 0)) == "nothing to remove")
        #expect(XrayText.detail(for: .documentDeleted(docId: "d", chunksRemoved: 1, imagesRemoved: 1)) == "1 chunk and 1 photo removed in the same transaction")
        #expect(XrayText.detail(for: .documentDeleted(docId: "d", chunksRemoved: 2)) == "2 chunks removed in the same transaction")
    }

    @Test func theRelevanceTextExplainsAPassOnAnImage() {
        let text = XrayText.relevance(best: 0.9, threshold: 0.76, outcome: .passedOnImage(0.2), bestImage: 0.2, imageThreshold: 0.25)
        #expect(text == "best distance 0.900 > threshold 0.76, but the photo matches a library photo at distance 0.200 ≤ 0.25")
        let photoOnly = XrayText.relevance(best: nil, threshold: 0.76, outcome: .passedOnImage(0.2), bestImage: 0.2, imageThreshold: 0.25)
        #expect(photoOnly == "the photo matches a library photo at distance 0.200 ≤ 0.25")
        let missed = XrayText.relevance(best: 0.9, threshold: 0.76, outcome: .failed, bestImage: 0.4, imageThreshold: 0.25)
        #expect(missed == "best distance 0.900 > threshold 0.76; closest photo 0.400 > threshold 0.25")
        #expect(XrayText.relevance(best: 0.2, threshold: 0.76, outcome: .passedOnDistance) == "best distance 0.200 ≤ threshold 0.76")
    }

    @Test func theImageSearchIsTitledAndNamesItsIndex() {
        let query = TraceKind.query(QueryTrace(sql: "", purpose: .image, returnedRows: 5))
        #expect(XrayText.title(for: query) == "Image search" && query.tag == .imageQuery)
    }

    @Test func theWordsToPhotosSearchIsTitledCaptionedAndTraced() {
        let query = TraceKind.query(QueryTrace(sql: "", purpose: .imageByWords, returnedRows: 3))
        #expect(XrayText.title(for: query) == "Words → photos search" && query.tag == .imageByWordsQuery)
        #expect(XrayText.symbol(for: .imageByWordsQuery) != XrayText.symbol(for: .imageQuery) || !XrayText.symbol(for: .imageByWordsQuery).isEmpty)
        let hit = TraceKind.wordsMatchedPhotos(matches: 2, bestDistance: 0.18, threshold: 0.25)
        #expect(hit.tag == .wordsMatchedPhotos)
        #expect(XrayText.title(for: hit) == "2 photos match the words")
        #expect(XrayText.detail(for: hit) == "closest photo 0.180 ≤ threshold 0.25; the chunks beside it were added to the search")
        let one = TraceKind.wordsMatchedPhotos(matches: 1, bestDistance: 0.1, threshold: 0.25)
        #expect(XrayText.title(for: one) == "1 photo matches the words")
        let miss = TraceKind.wordsMatchedPhotos(matches: 0, bestDistance: 0.6, threshold: 0.25)
        #expect(XrayText.title(for: miss) == "No photo matches the words")
        #expect(XrayText.detail(for: miss) == "closest photo 0.600 > threshold 0.25, so no photo is shown")
        #expect(XrayText.detail(for: .wordsMatchedPhotos(matches: 0, bestDistance: nil, threshold: 0.25)) == "the library has no photos to compare with")
    }

    @Test func theImageCaptionsPresentASecondVectorIndexInTheSameDatabase() {
        let all = [XrayEventTag.imageQuery, .imageByWordsQuery, .imagesWritten].map { XrayText.caption(for: $0).lowercased() }.joined(separator: " ")
        #expect(all.contains("same embedded database") && all.contains("one atomic transaction"))
    }
}

// MARK: - The demo's photos

@MainActor @Suite struct SamplePhotoMatchTests {
    private func distance(_ a: [Float], _ b: [Float]) -> Double { Double(1 - zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }) }

    private func figure(cropped: Bool) async throws -> CGImage {
        let manual = try write(SampleDocuments.makeServiceManual(cropFigure: cropped), as: "service-manual-\(cropped).pdf")
        return try #require(try await FileDocumentExtractor().extract(from: manual) { _ in }.images.first).image
    }

    /// What the UI tests show depends on this: the sample nameplate must be found in the service manual (whose figure,
    /// in stub mode, is the plate as photographed) and the other unit's plate must come second. The stand-in image
    /// features of stub mode have distances on their own scale, and cannot see through a crop.
    @Test func theSampleNameplateIsNearestTheManualFigureUnderTheStubFeatures() async throws {
        let features = FakeImageFeaturer()
        func vector(_ data: Data) async throws -> [Float] { try await features.features(of: try #require(PhotoData.image(from: data))) }
        let query = try await vector(SampleDocuments.x200Nameplate)
        let toFigure = distance(query, try await features.features(of: try await figure(cropped: false)))
        let toOther = distance(query, try await vector(SampleDocuments.nameplatePhoto(model: "X100-A", serial: "2208-91", style: .label)))
        print("SAMPLEPHOTO stub features: to the manual's figure \(toFigure), to the X100 label \(toOther), threshold \(StubServiceFactory.imageMaxDistance)")

        #expect(toFigure <= StubServiceFactory.imageMaxDistance, "the demo photo would not find the manual's figure")
        #expect(toFigure < toOther, "the right plate must rank first")
    }

    /// The same claim with the real embedding model, when `EMBEDDER_MODEL_PATH` points at it (in the simulator:
    /// `TEST_RUNNER_EMBEDDER_MODEL_PATH`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"] != nil))
    func theSampleNameplateIsNearestTheManualFigureUnderTheRealModel() async throws {
        let printer = LiteRTEmbedder(profile: .embeddingGemma2, modelPath: ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"] ?? "")
        func vector(_ data: Data) async throws -> [Float] { try await printer.features(of: try #require(PhotoData.image(from: data))) }
        let query = try await vector(SampleDocuments.x200Nameplate)
        let toFigure = distance(query, try await printer.features(of: try await figure(cropped: true)))
        let toOther = distance(query, try await vector(SampleDocuments.nameplatePhoto(model: "X100-A", serial: "2208-91", style: .label)))
        print("SAMPLEPHOTO real model: to the manual's figure \(toFigure), to the X100 label \(toOther)")
        #expect(toFigure <= RetrievalConfiguration().imageMaxDistance && toFigure < toOther)
    }

    /// Every picture the two demo PDFs store, with its document and page.
    private func demoPictures() async throws -> [(name: String, page: Int?, image: CGImage)] {
        let urls = try SampleDocuments.write(into: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        var pictures: [(name: String, page: Int?, image: CGImage)] = []
        for url in urls {
            for image in try await FileDocumentExtractor().extract(from: url) { _ in }.images {
                pictures.append((url.deletingPathExtension().lastPathComponent, image.page, image.image))
            }
        }
        return pictures
    }

    /// Reset demo's sample photo must find the debugger figure on page 28 of the whitepaper, and nothing else first.
    /// (`TEST_RUNNER_EMBEDDER_MODEL_PATH` in the simulator.)
    private func expectSamplePhotoFindsPage28(_ features: (CGImage) async throws -> [Float], limit: Double, label: String) async throws {
        let query = try await features(try #require(SampleDocuments.samplePhoto.flatMap { PhotoData.image(from: $0) }))
        var ranked: [(name: String, page: Int?, distance: Double)] = []
        for picture in try await demoPictures() {
            ranked.append((picture.name, picture.page, distance(query, try await features(picture.image))))
        }
        ranked.sort { $0.distance < $1.distance }
        print("SAMPLEPHOTO \(label): " + ranked.prefix(4).map { "\($0.name) p\($0.page ?? 0) \($0.distance)" }.joined(separator: "; "))
        let best = try #require(ranked.first)
        #expect(best.name == "Couchbase Under the Hood" && best.page == 28, "nearest: \(best)")
        #expect(best.distance <= limit, "the demo photo would not find the figure")
    }

    // No stub-features variant: the stand-in's 8 x 8 colour cells see the photo, decoded as the app decodes photos, with
    // darker edges than the figure stored from the PDF, and the mostly white figure has little else to tell it by. The
    // claim only holds, and only matters, for the real model.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"] != nil))
    func theDemoSamplePhotoFindsTheDebuggerFigureUnderTheRealModel() async throws {
        let printer = LiteRTEmbedder(profile: .embeddingGemma2, modelPath: ProcessInfo.processInfo.environment["EMBEDDER_MODEL_PATH"] ?? "")
        try await expectSamplePhotoFindsPage28({ try await printer.features(of: $0) }, limit: RetrievalConfiguration().imageMaxDistance, label: "real model")
    }
}
