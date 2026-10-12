import Adapters
import Core
import Foundation
import Ports
import PortsTesting
import SwiftUI
import Testing
@testable import ManualBot

private func chunk(
    _ ordinal: Int, doc: String = "d", page: Int? = nil, heading: String? = nil, text: String? = nil, imageId: String? = nil,
    generation: Int = 1, dimensions: Int = 2
) -> Chunk {
    Chunk(docId: doc, generation: generation, ordinal: ordinal, page: page, heading: heading,
          text: text ?? "Chunk \(ordinal) says something about the unit.", embedding: [Float](repeating: 0.1, count: dimensions),
          embeddingModel: "fake:1", imageId: imageId)
}

private func image(doc: String = "d", n: Int, page: Int? = nil, heading: String? = nil, generation: Int = 1, caption: String? = nil) -> ImageWrite {
    ImageWrite(
        record: ImageRecord(docId: doc, generation: generation, n: n, page: page, heading: heading, caption: caption,
                            captionSource: caption == nil ? .none : .nearby, ocrText: "X200", width: 10, height: 8,
                            features: [0.1], featureModel: "img:1"),
        displayCopy: Data([1, 2, 3]))
}

// MARK: - Overlap

@Suite struct ChunkOverlapTests {
    private static let sentences = (1...40).map { "Sentence number \($0) explains how the controller is wired to the panel." }

    @Test func findsTheSentencesTheChunkerRepeats() {
        let chunks = Chunker(configuration: .embeddingGemma2).chunk([Block(text: Self.sentences.joined(separator: " "), page: 1)])
        #expect(chunks.count > 2)
        for index in 1..<chunks.count {
            let previous = chunks[index - 1].text, current = chunks[index].text
            let leading = ChunkOverlap.leading(previous: previous, current: current)
            let trailing = ChunkOverlap.trailing(current: previous, next: current)
            #expect(leading > 0)
            #expect(trailing > 0)
            // Both sides mark the same words.
            #expect(String(current.prefix(leading)) == String(previous.suffix(trailing)))
            #expect(previous.hasSuffix(String(current.prefix(leading))))
        }
    }

    @Test func theFirstAndLastChunksShareNothingOutward() {
        let chunks = Chunker(configuration: .embeddingGemma2).chunk([Block(text: Self.sentences.joined(separator: " "), page: 1)])
        #expect(ChunkOverlap.leading(previous: "", current: chunks[0].text) == 0)
        #expect(ChunkOverlap.trailing(current: chunks[chunks.count - 1].text, next: "") == 0)
    }

    @Test func aCoincidentalShortRepeatIsNotAnOverlap() {
        #expect(ChunkOverlap.leading(previous: "Close the lid. Press start.", current: "Press start. Then wait for the beep.") == 0)
        #expect(ChunkOverlap.trailing(current: "Close the lid. Press start.", next: "Press start. Then wait for the beep.") == 0)
    }

    @Test func aChunkIsNeverReportedAsEntirelyRepeated() {
        let text = "Hold the power button for ten seconds."
        #expect(ChunkOverlap.leading(previous: text, current: text) < text.count)
    }

    @MainActor @Test func chunksOnDifferentPagesOrStandingForImagesShareNothing() async {
        let repo = InMemoryDocumentRepository()
        let shared = "Sentence one explains the wiring. Sentence two explains the panel."
        await repo.upsert(DocumentRecord(id: "d", title: "T", type: .pdf, activeGeneration: 1))
        await repo.writeChunks([
            chunk(0, page: 1, text: "Intro words here. " + shared), chunk(1, page: 2, text: shared + " More on page two."),
            chunk(2, page: 2, text: "More on page two. Still more words follow.", imageId: "d:1:img:0"),
        ])
        let model = DocumentContentsModel(docId: "d", title: "T", type: .pdf, documents: repo)
        await model.load()
        #expect(model.overlap(of: model.chunks[1]) == (0, 0))   // page break before it
        #expect(model.overlap(of: model.chunks[0]) == (0, 0))
        #expect(model.overlap(of: model.chunks[2]) == (0, 0))   // stands for an image
    }
}

// MARK: - Model

@MainActor @Suite struct DocumentContentsModelTests {
    @Test func pdfChunksGroupByPageAndAnImageChunkEndsItsPageSection() async {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "Manual", type: .pdf, activeGeneration: 1))
        await repo.writeChunks([
            chunk(0, page: 1), chunk(1, page: 1), chunk(2, page: 2), chunk(3, page: 2),
            chunk(4, page: 1, imageId: "d:1:img:0"),
        ])
        await repo.writeImages([image(n: 0, page: 1, caption: "Fig 1")])
        let model = DocumentContentsModel(docId: "d", title: "Manual", type: .pdf, documents: repo)
        await model.load()

        #expect(model.phase == .loaded)
        #expect(model.chunkSections.map(\.title) == ["Page 1", "Page 2"])
        #expect(model.chunkSections[0].entries.map(\.ordinal) == [0, 1, 4])
        #expect(model.chunkSections[0].entries.last?.imageId == "d:1:img:0")
        #expect(model.chunkSections[1].entries.map(\.ordinal) == [2, 3])
        #expect(model.orderedChunks.map(\.ordinal) == [0, 1, 4, 2, 3])
        #expect(model.imageSections.map(\.title) == ["Page 1"])
        #expect(model.images.count == 1 && model.chunks.count == 5)
    }

    @Test func otherDocumentsGroupByHeadingInOrderOfFirstAppearance() async {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "Notes", type: .docx, activeGeneration: 1))
        await repo.writeChunks([
            chunk(0, heading: "Setup"), chunk(1, heading: "Setup"), chunk(2, heading: "Wiring"), chunk(3, heading: "Setup"),
            chunk(4),
        ])
        let model = DocumentContentsModel(docId: "d", title: "Notes", type: .docx, documents: repo)
        await model.load()

        #expect(model.chunkSections.map(\.title) == ["Setup", "Wiring", "Notes"])   // no heading: the document's title
        #expect(model.chunkSections[0].entries.map(\.ordinal) == [0, 1, 3])
    }

    @Test func loadKeepsOnlyTheActiveGenerationAndNoVectors() async {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "T", type: .text, activeGeneration: 2))
        await repo.writeChunks([chunk(0, generation: 1), chunk(0, generation: 2, dimensions: 5), chunk(1, generation: 2, dimensions: 5)])
        await repo.writeImages([image(n: 0, generation: 1), image(n: 0, generation: 2)])
        let model = DocumentContentsModel(docId: "d", title: "T", type: .text, documents: repo)
        await model.load()

        #expect(model.chunks.map(\.id) == ["d:2:0", "d:2:1"])
        #expect(model.chunks.allSatisfy { $0.dimension == 5 && $0.embeddingModel == "fake:1" })
        #expect(model.images.map(\.id) == ["d:2:img:0"])
    }

    @Test func stepFollowsTheListAndStopsAtTheEnds() async {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "T", type: .pdf, activeGeneration: 1))
        await repo.writeChunks([chunk(0, page: 1), chunk(1, page: 1, imageId: "d:1:img:0"), chunk(2, page: 2)])
        let model = DocumentContentsModel(docId: "d", title: "T", type: .pdf, documents: repo)
        await model.load()
        var selected: [String] = []
        model.onSelect = { selected.append($0.selectedChunk?.id ?? "") }

        model.select(.chunk("d:1:0"))
        #expect(!model.hasChunk(offset: -1) && model.hasChunk(offset: 1))
        model.step(by: -1)   // nothing before the first
        model.step(by: 1)
        model.step(by: 1)
        model.step(by: 1)    // nothing after the last
        #expect(selected == ["d:1:0", "d:1:1", "d:1:2"])
        #expect(model.hasChunk(offset: -1) && !model.hasChunk(offset: 1))
    }

    @Test func showChunkSwitchesToTheChunkListAndSelectsTheImagesChunk() async throws {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "T", type: .pdf, activeGeneration: 1))
        await repo.writeChunks([chunk(0, page: 1), chunk(1, page: 1, imageId: "d:1:img:0")])
        await repo.writeImages([image(n: 0, page: 1)])
        let model = DocumentContentsModel(docId: "d", title: "T", type: .pdf, documents: repo)
        await model.load()
        model.kind = .images
        model.select(.image("d:1:img:0"))
        model.showChunk(of: try #require(model.selectedImage))

        #expect(model.kind == .chunks)
        #expect(model.selection == .chunk("d:1:1"))
    }

    @Test func aReloadAfterAReindexKeepsTheSelectionButItResolvesToNothing() async {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "T", type: .text, activeGeneration: 1))
        await repo.writeChunks([chunk(0), chunk(1)])
        let model = DocumentContentsModel(docId: "d", title: "T", type: .text, documents: repo)
        await model.load()
        model.select(.chunk("d:1:1"))
        var refreshed = 0
        model.onRefresh = { _ in refreshed += 1 }

        await repo.writeChunks([chunk(0, generation: 2), chunk(1, generation: 2), chunk(2, generation: 2)])
        try? await repo.activate(generation: 2, for: "d")
        await model.load()

        #expect(model.chunks.map(\.id) == ["d:2:0", "d:2:1", "d:2:2"])
        #expect(model.selection == .chunk("d:1:1"))
        #expect(model.selectedChunk == nil)
        #expect(refreshed == 1)
    }
}

// MARK: - Previews

@MainActor @Suite struct ContentsPreviewTests {
    private func make() async -> (DocumentContentsModel, SourceViewerModel) {
        let repo = InMemoryDocumentRepository()
        await repo.upsert(DocumentRecord(id: "d", title: "Manual", type: .pdf, activeGeneration: 1))
        let sentences = (1...40).map { "Sentence number \($0) explains how the controller is wired to the panel." }
        let drafts = Chunker(configuration: .embeddingGemma2).chunk([Block(text: sentences.joined(separator: " "), page: 1)])
        await repo.writeChunks(drafts.map { chunk($0.ordinal, page: 1, text: $0.text) } + [
            chunk(drafts.count, page: 1, text: "Figure 3 wiring diagram. X200", imageId: "d:1:img:0")])
        await repo.writeImages([image(n: 0, page: 1, caption: "Figure 3 wiring diagram")])
        let model = DocumentContentsModel(docId: "d", title: "Manual", type: .pdf, documents: repo)
        await model.load()
        let source = SourceViewerModel(documents: repo, extractor: FileDocumentExtractor())
        return (model, source)
    }

    @Test func aChunkPreviewCarriesItsPositionOverlapAndNeighbours() async throws {
        let (model, source) = await make()
        model.select(.chunk("d:1:1"))
        await source.preview(model)

        guard case .chunkPreview(let preview) = source.content else { Issue.record("not a chunk preview"); return }
        #expect(preview.entry.ordinal == 1)
        #expect(preview.total == model.chunks.count)
        #expect(preview.leadingOverlap > 0 && preview.trailingOverlap > 0)
        #expect(preview.hasPrevious && preview.hasNext)
        #expect(preview.entry.dimension == 2 && preview.entry.embeddingModel == "fake:1")
        #expect(preview.citation.chunkId == "d:1:1" && preview.citation.page == 1 && preview.citation.snippet == preview.entry.text)
        #expect(source.previewedDocument == "d")
    }

    @Test func theFirstChunkHasNoPreviousAndTheImagesChunkIsNotMarkedAsOverlap() async throws {
        let (model, source) = await make()
        model.select(.chunk("d:1:0"))
        await source.preview(model)
        guard case .chunkPreview(let first) = source.content else { Issue.record("not a chunk preview"); return }
        #expect(!first.hasPrevious && first.leadingOverlap == 0)

        model.select(.chunk("d:1:\(model.chunks.count - 1)"))
        await source.preview(model)
        guard case .chunkPreview(let last) = source.content else { Issue.record("not a chunk preview"); return }
        #expect(last.entry.imageId != nil && last.leadingOverlap == 0 && last.trailingOverlap == 0 && !last.hasNext)
    }

    @Test func anImagePreviewHasTheStoredPictureAndItsChunk() async {
        let (model, source) = await make()
        model.select(.image("d:1:img:0"))
        await source.preview(model)

        guard case .imagePreview(let preview) = source.content else { Issue.record("not an image preview"); return }
        #expect(preview.data == Data([1, 2, 3]))
        #expect(preview.entry.caption == "Figure 3 wiring diagram")
        #expect(preview.hasChunk)
        #expect(preview.citation.imageId == "d:1:img:0" && preview.citation.page == 1)
    }

    @Test func aSelectionThatIsNoLongerInTheIndexIsReportedAsGone() async {
        let (model, source) = await make()
        model.select(.chunk("d:0:9"))
        await source.preview(model)
        #expect(source.content == .unavailable(title: "Manual", reason: "This chunk is no longer in the document's index."))

        model.select(.image("d:0:img:9"))
        await source.preview(model)
        #expect(source.content == .unavailable(title: "Manual", reason: "This image is no longer in the document's index."))
    }

    @Test func aDeletedDocumentIsSaidSoInThePreview() async {
        let (model, source) = await make()
        model.select(.chunk("d:1:1"))
        await source.preview(model)
        source.showDeleted(title: "Manual")
        #expect(source.content == .unavailable(title: "Manual", reason: "The document was deleted."))
        #expect(source.previewedDocument == nil)
    }
}

// MARK: - Tracing (real database)

@MainActor @Suite struct ContentsTraceTests {
    @Test func loadingIsOneBrowseOperationAndPreviewsAndSteppingAreQuiet() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contents-trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tracer = RecordingTracer()
        let identity = EmbeddingModelIdentity(id: "t", version: "1", dimensions: 8)
        let repository = try CouchbaseDocumentRepository(
            directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("cache"),
            embedding: identity, tracer: tracer)
        defer { Task { try? await repository.close() } }
        try await repository.upsert(DocumentRecord(id: "d", title: "Manual", type: .text, activeGeneration: 1))
        try await repository.writeChunks((0..<3).map {
            Chunk(docId: "d", generation: 1, ordinal: $0, text: "Chunk \($0) of the manual.", embedding: [Float](repeating: 0.1, count: 8),
                  embeddingModel: identity.tag)
        })
        let counts = try await repository.activeChunks(docId: "d").count

        let before = tracer.events.count
        let model = DocumentContentsModel(docId: "d", title: "Manual", type: .text, documents: repository, tracer: tracer)
        await model.load()
        let loaded = Array(tracer.events.dropFirst(before))
        #expect(model.chunks.count == counts)
        #expect(!loaded.isEmpty)
        #expect(loaded.allSatisfy { $0.operation?.kind == .browseContents })
        #expect(Set(loaded.compactMap { $0.operation?.id }).count == 1)
        #expect(loaded.first?.operation?.title == "Contents of “Manual”")

        let source = SourceViewerModel(documents: repository, extractor: FileDocumentExtractor(), tracer: tracer)
        let afterLoad = tracer.events.count
        model.onSelect = { model in Task { await source.preview(model) } }
        model.select(.chunk("d:1:0"))
        await source.preview(model)
        model.step(by: 1)
        model.step(by: 1)
        await source.preview(model)
        #expect(tracer.events.count == afterLoad)
        // Browsing wrote nothing.
        #expect(try await repository.activeChunks(docId: "d").count == counts)
    }
}

// MARK: - Open in Database

@MainActor @Suite struct DatabaseRecordTests {
    @Test func eachPreviewNamesItsStoredRecord() async throws {
        let repo = InMemoryDocumentRepository()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("manual.txt")
        try "Hold the power button for ten seconds.".write(to: file, atomically: true, encoding: .utf8)
        await repo.upsert(DocumentRecord(id: "d", title: "Manual", type: .text, activeGeneration: 1))
        try await repo.attachOriginal(fileURL: file, contentType: "text/plain", to: "d")
        await repo.writeChunks([chunk(0), chunk(1, imageId: "d:1:img:0")])
        await repo.writeImages([image(n: 0)])
        let source = SourceViewerModel(documents: repo, extractor: FileDocumentExtractor())
        #expect(source.databaseRecord == nil)

        await source.openDocument("d")
        #expect(source.databaseRecord == .init(collection: "documents", id: "d"))

        let contents = DocumentContentsModel(docId: "d", title: "Manual", type: .text, documents: repo)
        await contents.load()
        contents.select(.chunk("d:1:0"))
        await source.preview(contents)
        #expect(source.databaseRecord == .init(collection: "chunks", id: "d:1:0"))
        contents.select(.image("d:1:img:0"))
        await source.preview(contents)
        #expect(source.databaseRecord == .init(collection: "images", id: "d:1:img:0"))

        await source.open(Citation(n: 1, chunkId: "gone:1:0", docId: "gone", docTitle: "Gone", snippet: "x"))
        #expect(source.databaseRecord == nil)
    }
}

// MARK: - JSON view

@Suite struct JSONHighlighterTests {
    private let object: [String: Any] = [
        "page": 2, "ratio": 0.5, "text": "Hold \"reset\"", "ok": true, "none": NSNull(),
        "nested": ["b": [1, 2]], "list": ["x", ["y": 1]],
    ]

    private func color(of token: String, in text: AttributedString) -> Color? {
        text.runs.first { String(text[$0.range].characters) == token }?.swiftUI.foregroundColor
    }

    @Test func theTextIsIndentedJSONWithTheSameContent() throws {
        let text = String(JSONHighlighter.highlight(object).characters)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
        #expect(parsed == object as NSDictionary)
        #expect(text.contains("\n  \"list\": [\n    \"x\",\n    {\n      \"y\": 1\n    }\n  ]"), "\(text)")
        #expect(text.contains("\"b\": [1, 2]"), "number arrays stay on one line: \(text)")
    }

    @Test func keysStringsNumbersAndLiteralsHaveTheirOwnColors() {
        let text = JSONHighlighter.highlight(object)
        #expect(color(of: "\"page\"", in: text) == JSONHighlighter.keyColor)
        #expect(color(of: "2", in: text) == JSONHighlighter.numberColor)
        #expect(color(of: "0.5", in: text) == JSONHighlighter.numberColor)
        #expect(color(of: "\"Hold \\\"reset\\\"\"", in: text) == JSONHighlighter.stringColor)
        #expect(color(of: "true", in: text) == JSONHighlighter.literalColor)
        #expect(color(of: "null", in: text) == JSONHighlighter.literalColor)
        let distinct: [Color] = [JSONHighlighter.keyColor, JSONHighlighter.stringColor, JSONHighlighter.numberColor, JSONHighlighter.literalColor]
        #expect(Set(distinct.map { "\($0)" }).count == 4)
    }
}
