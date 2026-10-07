import Foundation
import Ports
import PortsTesting
import Testing
@testable import ManualBot

@MainActor private func model(chunks: Int = 3) -> (ExplorerModel, FakeTraceInspector) {
    var chunkDocs: [String: String] = [:]
    for n in 0..<chunks { chunkDocs["chunk-\(String(format: "%03d", n))"] = "{ \"docId\" : \"d1\" }" }
    let fake = FakeTraceInspector(
        documents: [
            "documents": ["d1": "{ \"title\" : \"Manual\" }"], "chunks": chunkDocs, "ingestJobs": [:], "localMeta": ["x": "{}"],
        ],
        localOnly: ["ingestJobs", "localMeta"])
    let model = ExplorerModel()
    model.inspector = fake
    return (model, fake)
}

// MARK: - 3.1 browsing

@MainActor @Suite struct ExplorerModelTests {
    @Test func openingReadsTheCountsAndListsTheFirstCollection() async {
        let (model, _) = model()
        await model.open()
        #expect(model.syncReady.map(\.name) == ["chunks", "documents"])
        #expect(model.localOnly.map(\.name) == ["ingestJobs", "localMeta"])
        #expect(model.collections.first { $0.name == "chunks" }?.count == 3)
        #expect(model.selection == .collection("chunks"))
        #expect(model.ids.count == 3)
        #expect(model.firstDocumentID == "d1")
    }

    @Test func countsDoNotChangeUntilRefreshed() async {
        let (model, fake) = model()
        await model.open()
        fake.add(collection: "documents", id: "d2", json: "{}")
        #expect(model.collections.first { $0.name == "documents" }?.count == 1)
        await model.refresh()
        #expect(model.collections.first { $0.name == "documents" }?.count == 2)
    }

    @Test func loadMoreAppendsTheNextPageInOrder() async {
        let (model, _) = model(chunks: 120)
        await model.open(ExplorerTarget(collection: "chunks"))
        #expect(model.ids.count == 50)
        #expect(model.hasMore)
        await model.loadMore()
        await model.loadMore()
        #expect(model.ids.count == 120)
        #expect(!model.hasMore)
        #expect(model.ids == model.ids.sorted())
        #expect(Set(model.ids).count == 120)
    }

    @Test func changingTheFilterRestartsPaging() async {
        let (model, _) = model(chunks: 120)
        await model.open(ExplorerTarget(collection: "chunks"))
        await model.loadMore()
        #expect(model.ids.count == 100)
        await model.setFilter("chunk-11")
        #expect(model.ids.count == 10)
        #expect(!model.hasMore)
        await model.setFilter("")
        #expect(model.ids.count == 50)
    }

    @Test func anEmptyCollectionHasNoIDs() async {
        let (model, _) = model()
        await model.open(ExplorerTarget(collection: "ingestJobs"))
        #expect(model.ids.isEmpty)
        #expect(!model.hasMore)
    }

    @Test func switchingCollectionClearsTheFilterAndTheDetail() async {
        let (model, _) = model()
        await model.open(ExplorerTarget(collection: "chunks", documentID: "chunk-000"))
        await model.setFilter("000")
        model.follow(collection: "documents", id: "d1")
        await model.select(.collection("documents"))
        #expect(model.filter.isEmpty)
        #expect(model.path.isEmpty)
        #expect(model.ids == ["d1"])
    }

    @Test func aMissingDocumentIsReportedAsGone() async {
        let (model, fake) = model()
        await model.open()
        #expect(await model.document(collection: "chunks", id: "chunk-000") == .found("{ \"docId\" : \"d1\" }"))
        fake.remove(collection: "chunks", id: "chunk-000")
        #expect(await model.document(collection: "chunks", id: "chunk-000") == .gone)
    }

    @Test func fieldsThatHoldAnotherDocumentsIDAreReferences() {
        #expect(ExplorerModel.collection(referencedBy: "docId") == "documents")
        #expect(ExplorerModel.collection(referencedBy: "chatId") == "chats")
        #expect(ExplorerModel.collection(referencedBy: "imageId") == "images")
        #expect(ExplorerModel.collection(referencedBy: "text") == nil)
    }

    // MARK: 3.3 targets

    @Test func openingAPassageSelectsItsCollectionAndShowsIt() async {
        let (model, _) = model()
        await model.open(ExplorerTarget(collection: "chunks", documentID: "chunk-001"))
        #expect(model.selection == .collection("chunks"))
        #expect(model.path == [.document(collection: "chunks", id: "chunk-001")])
    }

    @Test func goingBackFromAReferenceShowsThePassageAgain() async {
        let (model, _) = model()
        await model.open(ExplorerTarget(collection: "chunks", documentID: "chunk-001"))
        model.follow(collection: "documents", id: "d1")
        #expect(model.path.count == 2)
        model.path.removeLast()
        #expect(model.path == [.document(collection: "chunks", id: "chunk-001")])
    }
}

// MARK: - 3.2 console

@MainActor @Suite struct ExplorerConsoleTests {
    private func rows(_ count: Int) -> QueryRows {
        QueryRows(columns: ["id"], rows: (0..<count).map { "{ \"id\" : \"\($0)\" }" }, truncated: false, duration: .milliseconds(3))
    }

    @Test func aQueryWithAParameterIsRefusedWithoutRunning() async {
        let (model, fake) = model()
        model.console.sql = "SELECT * FROM manualbot.chunks WHERE docId = $docId"
        await model.console.run()
        guard case .failed(let message) = model.console.state else { Issue.record("expected a failure"); return }
        #expect(message.contains("not supported"))
        #expect(message.contains("$docId"))
        #expect(fake.queryCalls == 0)
    }

    @Test func dollarSignsInsideQuotesAreNotParameters() {
        #expect(ExplorerConsole.parameter(in: #"SELECT * FROM c WHERE MATCH(i, "cost $5 and $vector")"#) == nil)
        #expect(ExplorerConsole.parameter(in: "SELECT 'it''s $x' AS a") == nil)
        #expect(ExplorerConsole.parameter(in: "SELECT `$odd` FROM c") == nil)
        #expect(ExplorerConsole.parameter(in: "SELECT 1 FROM c WHERE a = $name") == "name")
        #expect(ExplorerConsole.parameter(in: "SELECT 1 WHERE a = $1") == "1")
        #expect(ExplorerConsole.parameter(in: "SELECT 'a' || $x") == "x")
    }

    @Test func aQueryShowsItsRows() async {
        let (model, fake) = model()
        fake.setQuery(result: rows(2))
        model.console.sql = "SELECT meta().id AS id FROM manualbot.chunks"
        await model.console.run()
        #expect(model.console.state == .finished(rows(2)))
    }

    @Test func aDatabaseErrorIsShownInline() async {
        let (model, fake) = model()
        struct Boom: LocalizedError { var errorDescription: String? { "N1QL syntax error near character 3" } }
        fake.setQueryError(Boom())
        model.console.sql = "SELEKT"
        await model.console.run()
        #expect(model.console.state == .failed("N1QL syntax error near character 3"))
    }

    @Test func cancellingAQueryGivesTheEditorBackAndDropsItsResult() async throws {
        let (model, fake) = model()
        fake.setQuery(result: rows(5), delay: .milliseconds(150))
        model.console.sql = "SELECT meta().id AS id FROM manualbot.chunks"
        let running = Task { await model.console.run() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.console.state == .running)
        model.console.cancel()
        #expect(model.console.state == .idle)
        #expect(model.console.databaseStillBusy)
        await running.value
        #expect(model.console.state == .idle)
        #expect(!model.console.databaseStillBusy)

        // The editor works again.
        fake.setQuery(result: rows(1))
        await model.console.run()
        #expect(model.console.state == .finished(rows(1)))
    }

    @Test func aStarterFillsTheEditorWithTheFirstDocumentsID() async {
        let (model, _) = model()
        await model.open()
        let starters = model.starters
        #expect(starters.map(\.title) == ["Keyword search", "Passages of one document", "Ingest jobs by state"])
        #expect(starters[0].sql.contains("MATCH(chunks_fts"))
        #expect(starters[1].sql.contains("\"d1\""))
        model.console.use(starters[2])
        #expect(model.console.sql.contains("ingestJobs"))
        #expect(ExplorerConsole.parameter(in: starters.map(\.sql).joined(separator: "\n")) == nil)
    }

    @Test func thePlanIsRequestedOnDemand() async {
        let (model, _) = model()
        model.console.sql = "SELECT meta().id FROM manualbot.chunks"
        await model.showPlan()
        #expect(model.path == [.plan])
        #expect(model.console.plan == .ready("plan for: SELECT meta().id FROM manualbot.chunks"))
    }
}
