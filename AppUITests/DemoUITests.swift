import XCTest

final class DetailColumnUITests: UITestCase {
    private func readyApp() -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports five documents first
        waitFor(app.buttons["doc-X200 Manual"])
        return app
    }

    private func showXray(_ app: XCUIApplication) {
        let picker = element(app, "detailTabPicker")
        waitFor(picker)
        picker.buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))
    }

    func testAFreshLaunchShowsTheXraySwitchAndTheDatabaseButton() {
        let app = readyApp()
        waitFor(element(app, "detailTabPicker"))
        waitFor(element(app, "explorerButton"))
        showXray(app)
        waitFor(element(app, "xrayGroup-Import “X200 Manual”"))
    }

    func testACitationTapWhileXrayIsShowingSwitchesToTheSource() {
        let app = readyApp()
        ask(app, "How do I reset the X200?")
        waitFor(element(app, "assistantMessage"), timeout: 15)
        let citation = element(app, "citation-1")
        waitFor(citation)

        showXray(app)
        XCTAssertFalse(element(app, "sourceTitle").exists, "the source is hidden while X-ray shows")
        citation.tap()

        waitFor(element(app, "highlightedChunk"))
        XCTAssertEqual(element(app, "sourceTitle").label, "X200 Manual")
    }

    func testTheOpenSourceIsStillThereAfterLookingAtXray() {
        let app = readyApp()
        app.buttons["doc-X200 Manual"].tap()
        waitFor(element(app, "sourceTitle"))
        showXray(app)
        element(app, "detailTabPicker").buttons["Source"].tap()
        waitFor(element(app, "sourceTitle"))
        XCTAssertEqual(element(app, "sourceTitle").label, "X200 Manual")
    }
}

final class XrayPanelUITests: UITestCase {
    private let question = "How do I reset the X200?"

    private func askedApp() -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports five documents first
        waitFor(app.buttons["doc-X200 Manual"])
        ask(app, question)
        waitFor(element(app, "assistantMessage"), timeout: 15)
        showXray(app)
        return app
    }

    private func showXray(_ app: XCUIApplication) {
        let picker = element(app, "detailTabPicker")
        waitFor(picker)
        picker.buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))
    }

    private func open(_ app: XCUIApplication, _ event: String) {
        let row = element(app, "xrayEvent-\(event)")
        waitFor(row)
        row.tap()
    }

    func testAskingAddsAnExpandedGroupAndEarlierGroupsStayClosed() {
        let app = askedApp()
        waitFor(element(app, "xrayGroup-\(question)"))
        waitFor(element(app, "xrayEvent-vectorQuery"))
        waitFor(element(app, "xrayEvent-keywordQuery"))
        waitFor(element(app, "xrayEvent-fusion"))
        waitFor(element(app, "xrayEvent-relevance"))
        waitFor(element(app, "xrayEvent-generation"))
        // The imports that seeded the library are listed, but closed.
        waitFor(element(app, "xrayGroup-Import “X200 Manual”"))
        XCTAssertFalse(element(app, "xrayEvent-jobState").exists)
        XCTAssertFalse(element(app, "xrayEvent-batchWritten").exists)
    }

    func testTheVectorSearchShowsItsIndexItsFunnelAndTheRawPlan() {
        let app = askedApp()
        // The index is named without opening the event.
        let label = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'uses chunks_vec'")).firstMatch
        waitFor(label)

        open(app, "vectorQuery")
        let sql = element(app, "xraySQL")
        waitFor(sql)
        XCTAssertTrue(sql.label.contains("APPROX_VECTOR_DISTANCE"), sql.label)
        XCTAssertTrue(element(app, "xrayFunnel").label.contains("index returned"), element(app, "xrayFunnel").label)
        waitFor(element(app, "xrayFunnelUsed"))

        element(app, "xrayPlanButton").tap()
        let plan = element(app, "xrayPlanText")
        waitFor(plan)
        XCTAssertTrue(plan.label.contains("chunks_vec"), plan.label)
    }

    func testAChunkIdOpensTheStoredDocumentWithAShortenedVector() {
        let app = askedApp()
        open(app, "fusion")
        waitFor(element(app, "xrayFusionTable"))
        let link = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'xrayDocLink-'")).firstMatch
        waitFor(link)
        link.tap()
        let stored = element(app, "xrayStoredDocument")
        waitFor(stored)
        XCTAssertTrue(stored.label.contains("embeddingModel"), stored.label)
        XCTAssertTrue(stored.label.contains("768 values]"), stored.label)
    }

    func testTheIdOfADeletedDocumentSaysItNoLongerExists() {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports five documents first
        waitFor(app.buttons["doc-X200 Manual"])

        app.buttons["doc-X200 Manual"].press(forDuration: 1)
        app.buttons["Delete"].tap()
        app.buttons["Delete"].firstMatch.tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.buttons["doc-X200 Manual"])], timeout: 10), .completed)

        showXray(app)
        waitFor(element(app, "xrayGroup-Delete “X200 Manual”"))
        open(app, "documentDeleted")
        let link = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'xrayDocLink-'")).firstMatch
        waitFor(link)
        link.tap()
        waitFor(element(app, "xrayDocumentGone"))
    }

    func testCaptionsAppearOnlyWhenSwitchedOn() {
        let app = askedApp()
        waitFor(element(app, "xrayEvent-vectorQuery"))
        XCTAssertFalse(element(app, "xrayCaption-vectorQuery").exists)
        let toggle = element(app, "xrayCaptionsToggle")
        waitFor(toggle)
        toggle.tap()
        let caption = element(app, "xrayCaption-vectorQuery")
        waitFor(caption)
        XCTAssertTrue(caption.label.contains("unfiltered"), caption.label)
    }

    func testPresenterAidsAreShown() {
        let app = askedApp()
        waitFor(element(app, "xrayNetworkStatus"))
        waitFor(element(app, "xrayStubBadge"))
        let larger = element(app, "xrayTextLarger")
        let smaller = element(app, "xrayTextSmaller")
        waitFor(larger)
        let header = element(app, "xrayGroup-\(question)")
        waitFor(header)
        // Both buttons work from the start, and each really changes the size of the text.
        XCTAssertTrue(smaller.isEnabled && larger.isEnabled)
        let normal = header.frame.height
        smaller.tap()
        smaller.tap()
        smaller.tap()
        let small = header.frame.height
        XCTAssertLessThan(small, normal, "smaller text must shrink the panel text")
        larger.tap()
        larger.tap()
        larger.tap()
        larger.tap()
        larger.tap()
        larger.tap()
        XCTAssertGreaterThan(header.frame.height, normal, "larger text must grow the panel text")
        let slow = element(app, "xraySlowToggle")
        waitFor(slow)
        slow.tap()
        slow.tap()
    }

    func testClearEmptiesThePanel() {
        let app = askedApp()
        waitFor(element(app, "xrayGroup-\(question)"))
        app.buttons["xrayClearButton"].tap()
        waitFor(element(app, "xrayEmpty"))
    }
}

final class ResetDemoUITests: UITestCase {
    private func demoApp() -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports five documents first
        waitFor(app.buttons["doc-X200 Manual"])
        return app
    }

    private func documents(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'doc-'"))
    }

    private func openReset(_ app: XCUIApplication) {
        let picker = element(app, "detailTabPicker")
        waitFor(picker)
        picker.buttons["X-ray"].tap()
        let reset = element(app, "xrayResetButton")
        waitFor(reset)
        waitEnabled(reset)
        reset.tap()
    }

    func testConfirmingLeavesOnlyTheSampleDocumentsAndNoChats() {
        let app = demoApp()
        XCTAssertEqual(documents(app).count, 5, "the seeded library")
        ask(app, "How do I reset the X200?")
        waitFor(element(app, "assistantMessage"), timeout: 15)

        openReset(app)
        let confirm = app.buttons["Delete everything and import the samples"].firstMatch
        waitFor(confirm)
        confirm.tap()

        waitFor(app.buttons["doc-Couchbase Under the Hood"], timeout: 30)
        let ready = app.descendants(matching: .any).matching(identifier: "status-ready")
        let settled = NSPredicate { _, _ in self.documents(app).count == 2 && ready.count == 2 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 120), .completed,
                       "expected exactly the two sample PDFs, both ready; found \(documents(app).count)")
        XCTAssertTrue(app.buttons["doc-Capella Architecture Overview"].exists)
        XCTAssertFalse(element(app, "assistantMessage").exists, "the old chat must be gone")
        waitFor(element(app, "xrayGroup-Reset demo"))
    }

    func testCancellingChangesNothing() {
        let app = demoApp()
        ask(app, "How do I reset the X200?")
        waitFor(element(app, "assistantMessage"), timeout: 15)

        openReset(app)
        let confirm = app.buttons["Delete everything and import the samples"].firstMatch
        waitFor(confirm)
        // On iPad the dialog is a popover; tapping outside it cancels.
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap() }
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: confirm)], timeout: 5), .completed)

        XCTAssertEqual(documents(app).count, 5)
        XCTAssertFalse(app.buttons["doc-Couchbase Under the Hood"].exists)
        XCTAssertTrue(element(app, "assistantMessage").exists)
        XCTAssertFalse(element(app, "xrayGroup-Reset demo").exists)
    }
}

final class PhotoDemoUITests: UITestCase {
    private func demoApp() -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports five documents first
        waitFor(app.buttons["doc-X200 Manual"])
        return app
    }

    private func showXray(_ app: XCUIApplication) {
        let picker = element(app, "detailTabPicker")
        waitFor(picker)
        picker.buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))
    }

    func testAPhotoQuestionShowsTheImageSearchAndThreeListFusionInXray() {
        let app = demoApp()
        waitFor(app.buttons["doc-X200 Service Manual"])
        element(app, "attachPhotoButton").tap()
        waitFor(element(app, "attachedPhoto"))
        let send = element(app, "sendButton")
        waitEnabled(send)
        send.tap()
        waitFor(element(app, "matchesMessage"), timeout: 30)

        showXray(app)
        waitFor(element(app, "xrayEvent-photoAnalyzed"))
        waitFor(element(app, "xrayEvent-imageQuery"))
        waitFor(element(app, "xrayEvent-fusion"))
        element(app, "xrayEvent-imageQuery").tap()
        let sql = element(app, "xraySQL")
        waitFor(sql)
        XCTAssertTrue(sql.label.contains("APPROX_VECTOR_DISTANCE(features"), sql.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'uses images_vec'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "xrayGroup-Photo question").exists)
    }

    func testAfterAResetTheSamplePhotoCanBeSentAlone() {
        let app = launch(extra: ["-uiTestSeed", "-uiTestPhoto", "sample"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports five documents first
        waitFor(app.buttons["doc-X200 Manual"])
        let picker = element(app, "detailTabPicker")
        waitFor(picker)
        picker.buttons["X-ray"].tap()
        let reset = element(app, "xrayResetButton")
        waitFor(reset)
        waitEnabled(reset)
        reset.tap()
        let confirm = app.buttons["Delete everything and import the samples"].firstMatch
        waitFor(confirm)
        confirm.tap()

        let whitepaper = app.buttons["doc-Couchbase Under the Hood"]
        waitFor(whitepaper, timeout: 60)
        let ready = app.descendants(matching: .any).matching(identifier: "status-ready")
        let bothReady = NSPredicate(format: "count == 2")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: bothReady, object: ready)], timeout: 120), .completed)

        // The sample photo is the debugger screenshot as photographed. That it finds page 28 is checked with the real model
        // (`SamplePhotoMatchTests`); the stub's colour-cell features cannot tell, so this checks the photo question runs.
        element(app, "attachPhotoButton").tap()
        waitFor(element(app, "attachedPhoto"))
        let send = element(app, "sendButton")
        waitEnabled(send)
        send.tap()
        waitFor(element(app, "matchesMessage"), timeout: 60)
    }
}
