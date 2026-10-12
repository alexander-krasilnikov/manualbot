import XCTest

final class ExplorerUITests: UITestCase {
    private func readyApp() -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports five documents first
        waitFor(app.buttons["doc-X200 Manual"])
        return app
    }

    private func openExplorer(_ app: XCUIApplication) {
        let button = element(app, "explorerButton")
        waitFor(button)
        button.tap()
        waitFor(element(app, "explorer"))
    }

    private func closeExplorer(_ app: XCUIApplication) {
        element(app, "explorerDone").tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: element(app, "explorer"))], timeout: 10), .completed)
    }

    private func showXray(_ app: XCUIApplication) {
        let picker = element(app, "detailTabPicker")
        waitFor(picker)
        picker.buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))
    }

    private func xrayGroupCount(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'xrayGroup-'")).count
    }

    // MARK: 5.1 entry and exit

    func testOpeningAndClosingKeepsTheChatAndTheOpenSource() {
        let app = readyApp()
        ask(app, "How do I reset the X200?")
        waitFor(element(app, "assistantMessage"), timeout: 15)
        element(app, "citation-1").tap()
        waitFor(element(app, "highlightedChunk"))

        openExplorer(app)
        closeExplorer(app)

        waitFor(element(app, "assistantMessage"))
        waitFor(element(app, "highlightedChunk"))
        XCTAssertEqual(element(app, "sourceTitle").label, "X200 Manual")
    }

    // MARK: 4.1 4.2 browsing

    func testEveryCollectionAndIndexIsListed() {
        let app = readyApp()
        openExplorer(app)
        for name in ["documents", "chunks", "images", "chats", "messages", "ingestJobs", "localMeta"] {
            waitFor(element(app, "explorerCollection-\(name)"))
        }
        waitFor(element(app, "explorerIndexes"))
        XCTAssertTrue(element(app, "explorerCollection-documents").label.contains("5"), element(app, "explorerCollection-documents").label)
    }

    func testAChunkReferenceOpensItsDocumentAndBackReturnsToTheChunk() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerCollection-chunks").tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerDoc-'")).firstMatch
        waitFor(first)
        first.tap()
        let stored = element(app, "xrayStoredDocument")
        waitFor(stored)
        XCTAssertTrue(stored.label.contains("embeddingModel"), stored.label)

        let reference = element(app, "explorerRef-docId")
        waitFor(reference)
        reference.tap()
        waitFor(element(app, "explorerChildren"))

        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'chunks/'")).firstMatch
        waitFor(back)
        back.tap()
        waitFor(element(app, "explorerRef-docId"))
        XCTAssertTrue(element(app, "xrayStoredDocument").label.contains("embeddingModel"))
    }

    func testAVectorCanBeShownInFull() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerCollection-chunks").tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerDoc-'")).firstMatch
        waitFor(first)
        first.tap()
        let button = element(app, "explorerShowFull-embedding")
        waitFor(button)
        XCTAssertTrue(element(app, "xrayStoredDocument").label.contains("768 values]"))
        button.tap()
        waitFor(app.buttons["Show shortened"])
    }

    func testSyncAttributesLoadOnExpansionAboveTheBodyAndCanBeHidden() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerCollection-documents").tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerDoc-'" )).firstMatch
        waitFor(first)
        first.tap()

        let section = element(app, "explorerSyncAttributes")
        waitFor(section)
        let attributes = element(app, "explorerSyncAttributesJSON")
        XCTAssertFalse(attributes.exists)
        app.buttons["Sync attributes"].tap()
        waitFor(attributes)
        XCTAssertTrue(attributes.label.contains("revisionID"), attributes.label)
        XCTAssertTrue(attributes.label.contains("sequence"), attributes.label)
        XCTAssertLessThan(section.frame.minY, element(app, "explorerJSON").frame.minY)

        let copy = element(app, "explorerCopySyncAttributes")
        waitFor(copy)
        copy.tap()
        app.buttons["Sync attributes"].tap()
        XCTAssertFalse(attributes.exists)
        XCTAssertTrue(element(app, "xrayStoredDocument").exists)
    }

    func testSyncAttributesStayScopedAcrossReplicatedAndLocalOnlyDocumentsWithSyncDisabled() {
        let app = readyApp()
        openExplorer(app)

        element(app, "explorerCollection-documents").tap()
        let replicated = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerDoc-'" )).firstMatch
        waitFor(replicated)
        replicated.tap()
        app.buttons["Sync attributes"].tap()
        let attributes = element(app, "explorerSyncAttributesJSON")
        waitFor(attributes)
        XCTAssertTrue(attributes.label.contains("\"collection\": \"documents\""), attributes.label)

        app.buttons["Sync attributes"].tap()
        XCTAssertFalse(attributes.exists)
        element(app, "explorerCollection-localMeta").tap()
        let localOnly = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerDoc-'" )).firstMatch
        waitFor(localOnly)
        localOnly.tap()
        waitFor(element(app, "xrayStoredDocument"))
        XCTAssertFalse(attributes.exists)

        app.buttons["Sync attributes"].tap()
        waitFor(attributes)
        XCTAssertTrue(attributes.label.contains("\"collection\": \"localMeta\""), attributes.label)
        XCTAssertTrue(element(app, "xrayStoredDocument").exists)
    }

    func testAnImageBlobCanBePreviewed() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerCollection-images").tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerDoc-'")).firstMatch
        waitFor(first)
        first.tap()
        let preview = element(app, "explorerPreview-image")
        waitFor(preview)
        preview.tap()
        waitFor(element(app, "explorerImagePreview"))
    }

    func testTheVectorIndexShowsItsSettings() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerIndexes").tap()
        let index = element(app, "explorerIndex-chunks_vec")
        waitFor(index)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerIndex-'")).count, 6)
        index.tap()
        waitFor(element(app, "explorerIndexDetail"))
        XCTAssertTrue(element(app, "explorerFact-Distance metric").label.contains("cosine"))
        XCTAssertTrue(element(app, "explorerFact-Centroids").label.contains("64"))
        XCTAssertTrue(element(app, "explorerFact-Encoding").label.contains("SQ8"))
        XCTAssertTrue(element(app, "explorerFact-Dimensions").label.contains("768"))
    }

    // MARK: 4.3 console

    func testTheKeywordStarterReturnsRowsAndItsPlanNamesTheFullTextIndex() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerQuery").tap()
        waitFor(element(app, "consoleEditor"))
        element(app, "consoleStarters").tap()
        app.buttons["Keyword search"].tap()
        element(app, "consoleRun").tap()
        waitFor(element(app, "consoleSummary"))
        XCTAssertFalse(element(app, "consoleSummary").label.hasPrefix("0 rows"), element(app, "consoleSummary").label)

        element(app, "consolePlan").tap()
        let plan = element(app, "consolePlanText")
        waitFor(plan)
        XCTAssertTrue(plan.label.contains("chunks_fts"), plan.label)
    }

    func testAQueryWithAParameterSaysSo() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerQuery").tap()
        let editor = element(app, "consoleEditor")
        waitFor(editor)
        editor.tap()
        editor.typeText("SELECT meta().id FROM manualbot.chunks WHERE docId = $docId")
        element(app, "consoleRun").tap()
        let error = element(app, "consoleError")
        waitFor(error)
        XCTAssertTrue(error.label.contains("not supported"), error.label)
    }

    // MARK: 5.2 5.3 X-ray link and read-only

    func testClosingTheExplorerOpenedFromXrayReturnsToTheSameLog() {
        let app = readyApp()
        ask(app, "How do I reset the X200?")
        waitFor(element(app, "assistantMessage"), timeout: 15)
        showXray(app)
        let fusion = element(app, "xrayEvent-fusion")
        waitFor(fusion)
        fusion.tap()
        waitFor(element(app, "xrayFusionTable"))
        let link = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'xrayDocLink-'")).firstMatch
        waitFor(link)
        link.tap()
        waitFor(element(app, "xrayStoredDocument"))

        closeExplorer(app)
        waitFor(element(app, "xrayPanel"))
        waitFor(element(app, "xrayFusionTable"))
    }

    func testBrowsingAndQueryingAddsNothingToTheXrayLog() {
        let app = readyApp()
        showXray(app)
        waitFor(element(app, "xrayGroup-Import “X200 Manual”"))
        let before = xrayGroupCount(app)

        openExplorer(app)
        element(app, "explorerCollection-chunks").tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerDoc-'")).firstMatch
        waitFor(first)
        first.tap()
        waitFor(element(app, "xrayStoredDocument"))
        element(app, "explorerQuery").tap()
        element(app, "consoleStarters").tap()
        app.buttons["Ingest jobs by state"].tap()
        element(app, "consoleRun").tap()
        waitFor(element(app, "consoleSummary"))
        closeExplorer(app)

        waitFor(element(app, "xrayPanel"))
        XCTAssertEqual(xrayGroupCount(app), before)
    }
}
