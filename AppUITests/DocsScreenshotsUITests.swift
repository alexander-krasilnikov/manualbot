import XCTest

/// Takes the screenshots in `docs/images/` that need no real models: stub models, the Reset demo samples (the two Couchbase
/// PDFs), never the X-ray panel (it would show the stub badge) and no answers (the stub's are scripted). Skipped unless `DOCS_SCREENSHOTS=1`; `scripts/export-doc-screenshots.sh` runs it alone,
/// in light mode, and copies each attachment to `docs/images/<name>.png`.
final class DocsScreenshotsUITests: UITestCase {
    private let manual = "Couchbase Under the Hood"

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOCS_SCREENSHOTS"] == "1",
                          "set DOCS_SCREENSHOTS=1 (TEST_RUNNER_DOCS_SCREENSHOTS=1 from xcodebuild) to take the docs screenshots")
    }

    /// The two sample PDFs, both indexed, so no row shows progress.
    private func readyApp(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeedDemo"] + extra)
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 60)   // seeding indexes both PDFs first
        waitFor(app.buttons["doc-\(manual)"], timeout: 60)
        let ready = app.descendants(matching: .any).matching(identifier: "status-ready")
        let bothReady = NSPredicate(format: "count == 2")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: bothReady, object: ready)], timeout: 120), .completed)
        return app
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1)   // let transitions and thumbnails settle
        // In landscape the screen image comes with a rotation flag that a PNG drops; draw it upright first.
        let screen = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = screen.scale
        let upright = UIGraphicsImageRenderer(size: screen.size, format: format).image { _ in screen.draw(at: .zero) }
        let attachment = XCTAttachment(image: upright, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openContents(_ app: XCUIApplication) {
        let control = element(app, "contents-\(manual)")
        waitFor(control, timeout: 30)
        control.tap()
        waitFor(element(app, "contentsKind"))
    }

    private func openExplorer(_ app: XCUIApplication) {
        let button = element(app, "explorerButton")
        waitFor(button)
        button.tap()
        waitFor(element(app, "explorer"))
    }

    /// The catalog on its Couchbase category: the two bundled sample whitepapers already show "In library".
    func testManualCatalog() {
        let app = readyApp()
        // The library's narrow column keeps Import in the system's "More" menu, as a submenu.
        app.navigationBars["Library"].buttons["More"].tap()
        let importMenu = app.buttons["Import"]
        waitFor(importMenu)
        importMenu.tap()
        element(app, "importCatalog").tap()
        waitFor(app.navigationBars["Manual catalog"])
        let category = element(app, "catalogCategory-Couchbase")
        waitFor(category)
        category.tap()
        waitFor(element(app, "catalogRow-couchbase-capella-datasheet"))
        save(app, "manual-catalog")
    }

    func testLibrary() {
        let app = readyApp()
        app.buttons["doc-\(manual)"].tap()
        waitFor(element(app, "sourceTitle"))
        save(app, "library")
    }

    func testContentsChunk() {
        let app = readyApp()
        openContents(app)
        let row = element(app, "chunkRow-3")   // a paragraph of page 3, not the title chunk
        waitFor(row)
        row.tap()
        waitFor(element(app, "chunkPreview"))
        save(app, "contents-chunk")
    }

    func testContentsImage() {
        let app = readyApp()
        openContents(app)
        element(app, "contentsKind").buttons.element(boundBy: 1).tap()
        // The debugger figure on page 28: step through the image rows until the card names that page.
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'imageRow-'"))
        waitFor(rows.firstMatch)
        let page28 = element(app, "imagePreview").descendants(matching: .any).matching(NSPredicate(format: "label == '28'")).firstMatch
        for index in 0..<rows.count {
            let row = element(app, "imageRow-\(index)")
            if !row.isHittable { app.swipeUp() }
            row.tap()
            waitFor(element(app, "previewImage"))
            if page28.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(page28.exists, "no image card for page 28")
        save(app, "contents-image")
    }

    func testExplorerDocument() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerCollection-documents").tap()
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'explorerDoc-'")).firstMatch
        waitFor(first)
        first.tap()
        waitFor(element(app, "explorerSyncAttributes"))
        app.buttons["Sync attributes"].tap()
        waitFor(element(app, "explorerSyncAttributesJSON"))
        save(app, "explorer-document")
    }

    func testExplorerQuery() {
        let app = readyApp()
        openExplorer(app)
        element(app, "explorerQuery").tap()
        waitFor(element(app, "consoleEditor"))
        element(app, "consoleStarters").tap()
        app.buttons["Keyword search"].tap()
        element(app, "consoleRun").tap()
        waitFor(element(app, "consoleSummary"))
        save(app, "explorer-query")
    }

    func testModels() {
        let app = readyApp(["-uiTestSearch", "results"])
        element(app, "settingsButton").tap()
        waitFor(element(app, "settingsSheet"))
        element(app, "settingsModelsRow").tap()
        waitFor(element(app, "modelsPage"))
        save(app, "models")
    }

    func testSync() {
        let app = readyApp(["-uiTestSync", "upToDate"])
        element(app, "settingsButton").tap()
        waitFor(element(app, "settingsSheet"))
        element(app, "settingsSyncRow").tap()
        waitFor(element(app, "syncPage"))
        waitFor(element(app, "syncState"))
        save(app, "sync")
    }
}

/// Takes the screenshots in `docs/images/` that need the real models: answers, photo matches and X-ray distances. Skipped
/// unless `DOCS_SCREENSHOTS_REAL=1`; `scripts/export-doc-screenshots.sh --real` runs it. It launches the app as a user
/// would, downloads the models if they are not installed yet (about 3 GB), resets the demo and walks the talk track.
/// Run it on a simulator whose library may be deleted. Answers on the simulator's CPU take a minute or more each.
final class DocsRealScreenshotsUITests: XCTestCase {
    private let longWait: TimeInterval = 60 * 60

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOCS_SCREENSHOTS_REAL"] == "1",
                          "set DOCS_SCREENSHOTS_REAL=1 (TEST_RUNNER_DOCS_SCREENSHOTS_REAL=1 from xcodebuild) to take them")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) did not appear", file: file, line: line)
    }

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed, "\(element) never became enabled")
    }

    private func save(_ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        let screen = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = screen.scale
        let upright = UIGraphicsImageRenderer(size: screen.size, format: format).image { _ in screen.draw(at: .zero) }
        let attachment = XCTAttachment(image: upright, quality: .original)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The text of the last reply, for checking the talk track's claims in the test log.
    private func logReply(_ app: XCUIApplication, _ question: String) {
        let replies = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["assistantMessage", "notFoundMessage", "matchesMessage"]))
        let last = replies.element(boundBy: max(replies.count - 1, 0))
        print("DOCSREPLY [\(question)] \(last.label)")
    }

    private func showXray(_ app: XCUIApplication) {
        element(app, "detailTabPicker").buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))
    }

    private func showSource(_ app: XCUIApplication) {
        element(app, "detailTabPicker").buttons["Source"].tap()
    }

    /// A new chat and an empty X-ray log, so a shot shows one question's steps.
    private func freshQuestion(_ app: XCUIApplication) {
        showXray(app)
        element(app, "xrayClearButton").tap()
        element(app, "newChatButton").tap()
    }

    /// Asks and waits for the reply, whatever kind it is; returns whether it was an answer (not "couldn't find").
    @discardableResult
    private func ask(_ app: XCUIApplication, _ question: String) -> Bool {
        let answers = app.descendants(matching: .any).matching(identifier: "assistantMessage")
        let replies = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["assistantMessage", "notFoundMessage", "matchesMessage"]))
        let answersBefore = answers.count, repliesBefore = replies.count
        let input = element(app, "chatInput")
        waitEnabled(input, timeout: 60)
        input.tap()
        input.typeText(question)
        element(app, "sendButton").tap()
        let more = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count > %d", repliesBefore), object: replies)
        XCTAssertEqual(XCTWaiter().wait(for: [more], timeout: 15 * 60), .completed, "no reply to \(question)")
        waitEnabled(element(app, "newChatButton"), timeout: 15 * 60)   // the answer has finished
        logReply(app, question)
        return answers.count > answersBefore
    }

    private func expand(_ app: XCUIApplication, _ events: [String]) {
        for event in events {
            let row = element(app, "xrayEvent-\(event)")
            waitFor(row)
            row.tap()
        }
    }

    func testRealModelScreenshots() {
        let app = XCUIApplication()
        app.launchArguments = ["-sync.enabled", "NO"]   // never sync from a screenshot run, whatever the defaults say
        app.launch()

        // First launch: download the models (embedder first, then the language model).
        let download = app.buttons["startDownload"]
        if download.waitForExistence(timeout: 10) { download.tap() }
        waitFor(app.navigationBars["Library"], timeout: longWait)
        // The library shows once the embedder is in; the language model is ready when its banner is gone. (The chat input
        // stays disabled until there is a document, so it cannot be the signal here.)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(app, "languageModelBanner"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: longWait), .completed, "the language model never became ready")

        // 1. Reset demo and index the two whitepapers.
        showXray(app)
        element(app, "xrayClearButton").tap()
        let reset = element(app, "xrayResetButton")
        waitEnabled(reset, timeout: 60)
        reset.tap()
        let confirm = app.buttons["Delete everything and import the samples"].firstMatch
        waitFor(confirm)
        confirm.tap()
        let ready = app.descendants(matching: .any).matching(identifier: "status-ready")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: ready)],
                                        timeout: longWait), .completed, "the two samples were not indexed")
        waitEnabled(element(app, "chatInput"), timeout: 5 * 60)
        expand(app, ["batchWritten"])
        save("talk-1-import")

        // 2. Ask, and the hero.
        freshQuestion(app)
        ask(app, "What is a vBucket?")
        showXray(app)
        save("hero")
        expand(app, ["vectorQuery"])
        save("talk-2-ask")

        // 3. An exact token.
        freshQuestion(app)
        ask(app, "What is port 11207 used for?")
        showXray(app)
        expand(app, ["keywordQuery", "fusion"])
        save("talk-3-exact-codes")

        // 4. A follow-up, then a question the documents do not cover.
        freshQuestion(app)
        XCTAssertTrue(ask(app, "What is XDCR?"))
        // A follow-up the whitepaper answers (tried with the real models: "How does it resolve conflicts?" and "Is it
        // push-based?" were rewritten correctly or not, but neither was answered).
        XCTAssertTrue(ask(app, "Can it replicate only some collections?"), "the follow-up was not answered")
        print("DOCSREPLY standalone query: \(element(app, "standaloneQuery").label)")
        element(app, "xrayClearButton").tap()
        XCTAssertFalse(ask(app, "What's the weather in Prague?"))
        showXray(app)
        expand(app, ["relevance"])
        save("talk-4-follow-up")

        // 5. The sample photo alone.
        freshQuestion(app)
        element(app, "samplePhotoButton").tap()
        waitFor(element(app, "attachedPhoto"))
        element(app, "sendButton").tap()
        waitFor(element(app, "matchesMessage"), timeout: 15 * 60)
        logReply(app, "sample photo")
        let match = element(app, "imageMatch-1")
        // The matches grid is lazy and the chat scrolls to its end, so the first match may not be loaded yet: scroll up.
        for _ in 0..<6 where !match.waitForExistence(timeout: 2) {
            let chat = app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.35))
            chat.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.75)))
        }
        waitFor(match)
        print("DOCSREPLY first photo match: \(match.label)")
        showXray(app)
        expand(app, ["photoAnalyzed", "imageQuery"])
        save("talk-5-photo")
        match.tap()   // opens page 28 in the source column (and adds its own X-ray group)
        showSource(app)
        save("photo-answer")
    }
}
