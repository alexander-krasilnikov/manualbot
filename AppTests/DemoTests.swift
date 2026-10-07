import Adapters
import Core
import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

private func operation(_ n: Int) -> TraceOperation {
    TraceOperation(id: "op-\(n)", kind: .ask, title: "Question \(n)")
}

private func event(_ op: TraceOperation?, dimensions: Int = 1) -> TraceEvent {
    TraceEvent(operation: op, kind: .queryEmbedded(dimensions: dimensions))
}

// MARK: - 4.1 tracer and log

@Suite struct DemoTracerTests {
    @Test func aTracerThatIsOffDeliversNothing() async {
        let tracer = DemoTracer()
        tracer.emit(.queryEmbedded(dimensions: 1))      // off by default
        tracer.isEnabled = true
        tracer.emit(.queryEmbedded(dimensions: 2))
        tracer.isEnabled = false
        tracer.emit(.queryEmbedded(dimensions: 3))
        tracer.isEnabled = true
        tracer.emit(.queryEmbedded(dimensions: 4))

        var received: [Int] = []
        for await event in tracer.events {
            if case .queryEmbedded(let dimensions) = event.kind { received.append(dimensions) }
            if received.count == 2 { break }
        }
        #expect(received == [2, 4])
    }
}

@Suite struct TraceLogTests {
    @Test func theFiftyFirstGroupEvictsTheOldest() {
        var log = TraceLog()
        for n in 0...TraceLog.maxGroups { log.append(event(operation(n))) }
        #expect(log.groups.count == TraceLog.maxGroups)
        #expect(log.groups.first?.id == "op-1")
        #expect(log.groups.last?.id == "op-\(TraceLog.maxGroups)")
    }

    @Test func backgroundActivityIsOneGroupThatDoesNotCountTowardTheLimit() {
        var log = TraceLog()
        log.append(event(nil))
        for n in 0..<TraceLog.maxGroups { log.append(event(operation(n))) }
        log.append(event(nil))
        #expect(log.groups.count == TraceLog.maxGroups + 1)
        let background = log.groups.first { $0.isBackground }
        #expect(background?.events.count == 2)
        #expect(log.latestID == "op-\(TraceLog.maxGroups - 1)", "background events never become the latest group")
    }

    @Test func laterEventsOfAnOperationJoinItsGroupAndMakeItTheLatest() {
        var log = TraceLog()
        log.append(event(operation(1)))
        log.append(event(operation(2)))
        log.append(event(operation(1), dimensions: 2))
        #expect(log.groups.map(\.id) == ["op-1", "op-2"])
        #expect(log.groups[0].events.count == 2)
        #expect(log.latestID == "op-1")
    }

    @Test func aGroupReportsItsTitleAndSpan() {
        var log = TraceLog()
        let start = Date(timeIntervalSince1970: 1_000)
        log.append(TraceEvent(timestamp: start.addingTimeInterval(1), duration: 0.5, operation: operation(1), kind: .queryEmbedded(dimensions: 1)))
        log.append(TraceEvent(timestamp: start.addingTimeInterval(3), duration: 0.25, operation: operation(1), kind: .queryEmbedded(dimensions: 1)))
        let group = log.groups[0]
        #expect(group.title == "Question 1")
        #expect(group.startedAt == start.addingTimeInterval(0.5))
        #expect(group.endedAt == start.addingTimeInterval(3))
        #expect(group.duration == 2.5)
    }

    @Test func clearEmptiesTheLog() {
        var log = TraceLog()
        log.append(event(operation(1)))
        log.clear()
        #expect(log.groups.isEmpty && log.latestID == nil)
    }
}

// MARK: - 4.2 the session

@MainActor @Suite struct DemoSessionTests {
    @Test func tracingIsOnFromTheStart() {
        #expect(DemoSession().tracer.isEnabled)
    }
}

// MARK: - 4.4 opening a source

@MainActor @Suite struct SourceTraceTests {
    @Test func openingACitationReadsTheBlobInsideAnOpenSourceOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("manual.txt")
        try "Hold the power button for ten seconds.".write(to: file, atomically: true, encoding: .utf8)

        let tracer = RecordingTracer()
        let identity = EmbeddingModelIdentity(id: "t", version: "1", dimensions: 8)
        let repository = try CouchbaseDocumentRepository(
            directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("cache"),
            embedding: identity, tracer: tracer)
        defer { Task { try? await repository.close() } }
        try await repository.upsert(DocumentRecord(id: "d1", title: "X200 Manual", type: .text, activeGeneration: 1))
        try await repository.attachOriginal(fileURL: file, contentType: "text/plain", to: "d1")
        let before = tracer.events.count

        let source = SourceViewerModel(documents: repository, extractor: FileDocumentExtractor(), tracer: tracer)
        await source.open(Citation(n: 1, chunkId: "d1:1:0", docId: "d1", docTitle: "X200 Manual", page: 4, snippet: "Hold the power button"))

        let events = Array(tracer.events.dropFirst(before))
        let read = try #require(events.first { if case .blobRead = $0.kind { true } else { false } })
        #expect(read.operation?.kind == .openSource)
        #expect(read.operation?.title == "Open “X200 Manual”, page 4")
        #expect(Set(events.compactMap { $0.operation?.id }).count == 1)
    }

    @Test func aDisabledTracerSeesNothingAndTheSourceStillOpens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("source-off-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("manual.txt")
        try "Hold the power button for ten seconds.".write(to: file, atomically: true, encoding: .utf8)
        let tracer = RecordingTracer(isEnabled: false)
        let repository = try CouchbaseDocumentRepository(
            directory: root.appendingPathComponent("db"), originalsCache: root.appendingPathComponent("cache"),
            embedding: EmbeddingModelIdentity(id: "t", version: "1", dimensions: 8), tracer: tracer)
        defer { Task { try? await repository.close() } }
        try await repository.upsert(DocumentRecord(id: "d1", title: "X200 Manual", type: .text, activeGeneration: 1))
        try await repository.attachOriginal(fileURL: file, contentType: "text/plain", to: "d1")

        let source = SourceViewerModel(documents: repository, extractor: FileDocumentExtractor(), tracer: tracer)
        await source.open(Citation(n: 1, chunkId: "d1:1:0", docId: "d1", docTitle: "X200 Manual", page: 4, snippet: "Hold the power button"))

        #expect(tracer.events.isEmpty)
        if case .text = source.content {} else { Issue.record("the source did not open: \(source.content)") }
    }
}

// MARK: - 5.x panel model and text

@MainActor private func eventually(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

private final class CountingInspector: TraceInspector, @unchecked Sendable {
    private let lock = NSLock()
    private var plans = 0
    var planCalls: Int { lock.withLock { plans } }
    func plan(sql: String) async throws -> String { lock.withLock { plans += 1 }; return "SEARCH chunks USING INDEX chunks_vec" }
    func storedDocument(collection: String, id: String, fullVectors: Bool) async throws -> String? {
        id == "gone" ? nil : "{ \"id\" : \"\(id)\" }"
    }
    func collectionSummaries() async throws -> [CollectionSummary] { [] }
    func documentIDs(collection: String, after: String?, containing: String?, limit: Int) async throws -> [String] { [] }
    func blob(collection: String, id: String, key: String) async throws -> BlobContent? { nil }
    func children(documentID: String) async throws -> DocumentChildren { DocumentChildren() }
    func indexes() async throws -> [IndexSummary] { [] }
    func query(sql: String, limit: Int) async throws -> QueryRows {
        QueryRows(columns: [], rows: [], truncated: false, duration: .zero)
    }
}

@MainActor @Suite struct XrayModelTests {
    @Test func everyKindOfEventHasACaptionTitleAndSymbol() {
        for tag in XrayEventTag.allCases {
            #expect(!XrayText.caption(for: tag).isEmpty, "\(tag)")
            #expect(!XrayText.symbol(for: tag).isEmpty, "\(tag)")
        }
    }

    @Test func theVectorCaptionPresentsUnfilteredSearchAsADesignChoice() {
        let caption = XrayText.caption(for: .vectorQuery)
        #expect(caption.contains("unfiltered"))
        #expect(caption.contains("passage ID"))
        #expect(caption.contains("re-index"))
    }

    @Test func everyCaptionIsOneSentence() {
        for tag in XrayEventTag.allCases {
            let caption = XrayText.caption(for: tag)
            #expect(caption.hasSuffix("."), "\(tag) must end with a full stop")
            #expect(!caption.dropLast().contains(". "), "\(tag) has more than one sentence: \(caption)")
            #expect(!caption.contains("sync") || tag == .jobState, "\(tag): the app does not sync")
        }
    }

    @Test func theFunnelAddsUpAndSaysWhenTheSearchStoppedEarly() {
        let attempt = FunnelAttempt(window: 15, returned: 15, notVisible: 3, wrongModel: 1, kept: 4)
        #expect(attempt.visible == 5)
        #expect(attempt.notExamined == 7)
        let line = XrayText.funnel(attempt, number: 1, of: 1)
        #expect(line.contains("index returned 15"))
        #expect(line.contains("5 visible, 3 hidden"))
        #expect(line.contains("4 usable"))
        #expect(line.contains("1 embedded by another model"))
        #expect(line.contains("7 not examined"))
        #expect(!line.contains("Attempt"))
        #expect(XrayText.funnel(attempt, number: 2, of: 3).hasPrefix("Attempt 2 of 3: "))
        let complete = FunnelAttempt(window: 15, returned: 4, notVisible: 1, wrongModel: 0, kept: 3)
        #expect(!XrayText.funnel(complete, number: 1, of: 1).contains("not examined"))
    }

    @Test func captionsCoverTheBenefitsTheDemoMakes() {
        let all = XrayEventTag.allCases.map { XrayText.caption(for: $0).lowercased() }.joined(separator: " ")
        for phrase in ["same embedded database", "inside the database", "one transaction", "never replicated", "no network"] {
            #expect(all.contains(phrase), "no caption mentions “\(phrase)”")
        }
    }

    @Test func queryEventsMapToTheirPurpose() {
        func tag(_ purpose: QueryPurpose) -> XrayEventTag { TraceKind.query(QueryTrace(sql: "", purpose: purpose, returnedRows: 0)).tag }
        #expect(tag(.vector) == .vectorQuery && tag(.keyword) == .keywordQuery && tag(.other) == .otherQuery && tag(.image) == .imageQuery
            && tag(.imageByWords) == .imageByWordsQuery)
    }

    @Test func indexLabelsNameTheIndexOrSayThereIsNone() {
        #expect(XrayModel.indexLabel(inPlan: "SCAN chunks USING INDEX chunks_vec") == "uses chunks_vec · vector index")
        #expect(XrayModel.indexLabel(inPlan: "MATCH chunks_fts") == "uses chunks_fts · full-text index")
        #expect(XrayModel.indexLabel(inPlan: "SCAN images USING INDEX images_vec") == "uses images_vec · vector index")
        #expect(XrayModel.indexLabel(inPlan: "SEARCH images USING INDEX images_doc_gen") == "uses images_doc_gen · value index")
        #expect(XrayModel.indexLabel(inPlan: "SCAN documents") == "no index · reads the whole collection")
    }

    @Test func durationsReadNaturally() {
        #expect(XrayFormat.duration(0.0000004) == "0 µs")
        #expect(XrayFormat.duration(0.0031) == "3.1 ms")
        #expect(XrayFormat.duration(0.42) == "420 ms")
        #expect(XrayFormat.duration(1.23) == "1.2 s")
    }

    @Test func theLatestGroupIsOpenAndEarlierOnesAreClosedUntilTheyAreOpenedByHand() async {
        let tracer = DemoTracer()
        tracer.isEnabled = true
        let model = XrayModel(tracer: tracer)
        let task = Task { await model.run() }
        defer { task.cancel() }
        tracer.record(event(operation(1)))
        tracer.record(event(operation(2)))
        #expect(await eventually { model.log.groups.count == 2 })

        let (first, second) = (model.log.groups[0], model.log.groups[1])
        #expect(!model.isExpanded(first) && model.isExpanded(second))
        #expect(model.visibleGroups.map(\.id) == ["op-2", "op-1"], "newest first")

        model.setExpanded(first, true)
        model.setExpanded(second, false)
        #expect(model.isExpanded(first) && !model.isExpanded(second))
    }

    @Test func backgroundGroupsAreHiddenUntilAsked() async {
        let tracer = DemoTracer()
        tracer.isEnabled = true
        let model = XrayModel(tracer: tracer)
        let task = Task { await model.run() }
        defer { task.cancel() }
        tracer.record(event(nil))
        tracer.record(event(operation(1)))
        #expect(await eventually { model.log.groups.count == 2 })
        #expect(model.visibleGroups.map(\.id) == ["op-1"])
        model.showBackground = true
        #expect(model.visibleGroups.count == 2)
        model.clear()
        #expect(model.visibleGroups.isEmpty)
    }

    @Test func aPlanIsRequestedOncePerQuery() async {
        let inspector = CountingInspector()
        let model = XrayModel(tracer: DemoTracer())
        model.inspector = inspector
        await model.loadPlan(for: "SELECT 1")
        await model.loadPlan(for: "SELECT 1")
        await model.loadPlan(for: "SELECT 2")
        #expect(inspector.planCalls == 2)
        #expect(model.plans["SELECT 1"] == .ready("SEARCH chunks USING INDEX chunks_vec"))
    }

    @Test func aDocumentLinkOpensTheExplorerAtThatDocument() {
        let session = DemoSession()
        session.xray.openInExplorer?("chunks", "chunk-1")
        #expect(session.explorer.presented?.collection == "chunks")
        #expect(session.explorer.presented?.documentID == "chunk-1")
    }
}

// MARK: - 5.5 presenter aids

@MainActor @Suite struct PresenterAidsTests {
    private func running(_ model: XrayModel) -> Task<Void, Never> { Task { await model.run() } }

    @Test func slowRevealShowsQueuedEventsOneAtATimeInOrder() async {
        let tracer = DemoTracer()
        tracer.isEnabled = true
        let model = XrayModel(tracer: tracer, revealInterval: .milliseconds(150))
        model.slowReveal = true
        let task = running(model)
        defer { task.cancel() }

        for n in 1...4 { tracer.record(event(operation(1), dimensions: n)) }
        #expect(await eventually { !model.log.groups.isEmpty })
        // Not everything appears at once ...
        let firstSeen = model.log.groups[0].events.count
        #expect(firstSeen < 4, "shown=\(firstSeen) pending=\(model.pendingCount)")
        // ... but it all does appear, in the order it happened.
        #expect(await eventually(.seconds(4)) { model.log.groups.first?.events.count == 4 })
        let dimensions = model.log.groups[0].events.compactMap { event -> Int? in
            if case .queryEmbedded(let d) = event.kind { d } else { nil }
        }
        #expect(dimensions == [1, 2, 3, 4])
        #expect(model.pendingCount == 0)
    }

    @Test func eventsThatTrickleInAreStillSpacedByTheInterval() async {
        let tracer = DemoTracer()
        tracer.isEnabled = true
        let interval = Duration.milliseconds(150)
        let model = XrayModel(tracer: tracer, revealInterval: interval)
        model.slowReveal = true
        let task = running(model)
        defer { task.cancel() }

        // Arrivals a few milliseconds apart, as when each step of a question finishes right after the last.
        for n in 1...3 {
            tracer.record(event(operation(1), dimensions: n))
            try? await Task.sleep(for: .milliseconds(5))
        }
        let start = ContinuousClock.now
        #expect(await eventually(.seconds(4)) { model.log.groups.first?.events.count == 3 })
        #expect(start.duration(to: .now) >= .milliseconds(150), "the last two events must each wait for the interval")
    }

    @Test func turningSlowRevealOffShowsWhatIsWaitingAtOnce() async {
        let tracer = DemoTracer()
        tracer.isEnabled = true
        let model = XrayModel(tracer: tracer, revealInterval: .seconds(60))
        model.slowReveal = true
        let task = running(model)
        defer { task.cancel() }
        for n in 1...3 { tracer.record(event(operation(1), dimensions: n)) }
        #expect(await eventually { model.pendingCount >= 2 })

        model.slowReveal = false
        #expect(model.pendingCount == 0)
        #expect(model.log.groups.first?.events.count == 3)
    }

    @Test func withoutSlowRevealEventsAppearImmediately() async {
        let tracer = DemoTracer()
        tracer.isEnabled = true
        let model = XrayModel(tracer: tracer)
        let task = running(model)
        defer { task.cancel() }
        for n in 1...3 { tracer.record(event(operation(1), dimensions: n)) }
        #expect(await eventually { model.log.groups.first?.events.count == 3 })
        #expect(model.pendingCount == 0)
    }

    @Test func textSizeStartsInTheMiddleSoItCanShrinkAsWellAsGrow() {
        let model = XrayModel(tracer: DemoTracer())
        #expect(model.textSize == XrayModel.defaultTextSize)
        #expect(model.canShrinkText && model.canGrowText, "both buttons must work from the start")
        model.shrinkText()
        #expect(model.textSize == .medium)
        model.growText()
        model.growText()
        #expect(model.textSize == .xLarge)
    }

    @Test func textSizeStopsAtItsLimits() {
        let model = XrayModel(tracer: DemoTracer())
        for _ in 0..<30 { model.growText() }
        #expect(model.textSize == XrayModel.textSizes.last && !model.canGrowText && model.canShrinkText)
        for _ in 0..<30 { model.shrinkText() }
        #expect(model.textSize == XrayModel.textSizes.first && !model.canShrinkText && model.canGrowText)
    }

    @Test func theNetworkIndicatorFollowsTheMonitor() {
        let network = NetworkMonitor()
        network.set(online: false)
        #expect(!network.isOnline)
        network.set(online: true)
        #expect(network.isOnline)
    }
}

// MARK: - 6.1 sample documents

@MainActor @Suite struct SampleDocumentsTests {
    @Test func theSamplesAreWrittenUnderTheirDisplayNamesIncludingPdfsAndAPhoto() throws {
        let urls = try SampleDocuments.write(into: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        #expect(urls.map(\.lastPathComponent) == [
            "X200 Manual.md", "Bike Repair.md", "Warranty.txt", "Filter Guide.pdf", "X200 Service Manual.pdf", "Nameplate X100.jpg",
        ])
        for url in urls { #expect(try Data(contentsOf: url).count > 100, "\(url.lastPathComponent) is empty") }
        #expect(try Data(contentsOf: urls[3]).prefix(4) == Data("%PDF".utf8))
        #expect(try Data(contentsOf: urls[4]).prefix(4) == Data("%PDF".utf8))
        #expect(try Data(contentsOf: urls[5]).prefix(2) == Data([0xFF, 0xD8]))
        #expect(try String(contentsOf: urls[0], encoding: .utf8).contains("E-042"))
    }

    @Test func everySampleCanBeIndexedByTheRealExtractors() async throws {
        let urls = try SampleDocuments.write(into: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        let extractor = FileDocumentExtractor()
        for url in urls {
            let document = try await extractor.extract(from: url) { _ in }
            if FileDocumentExtractor.documentType(for: url) == .image {
                #expect(document.images.count == 1, "\(url.lastPathComponent) is not a photo")
            } else {
                #expect(!document.blocks.isEmpty, "\(url.lastPathComponent) has no text")
            }
        }
    }

    @Test func theServiceManualHasTheNameplateAsACaptionedFigureOnPageTwo() async throws {
        let urls = try SampleDocuments.write(into: FileManager.default.temporaryDirectory)
        defer { try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent()) }
        let manual = try await FileDocumentExtractor().extract(from: urls[4]) { _ in }
        #expect(manual.pageCount == 3)
        let figure = try #require(manual.images.first)
        #expect(manual.images.count == 1 && figure.page == 2)
        #expect(figure.caption == "Figure 1: Nameplate of the X200-B, rear panel" && figure.captionSource == .nearby)
    }

    @Test func theSampleNameplateIsReadBackByTextRecognition() async throws {
        let image = try #require(PhotoData.image(from: SampleDocuments.x200Nameplate))
        let text = try await VisionTextRecognizer().recognize(image, correctLanguage: false).map(\.text).joined(separator: " ")
        #expect(text.contains("X200-B") && text.contains("4471-22"), "recognized: \(text)")
    }
}
