import XCTest

final class ContentsUITests: UITestCase {
    private let manual = "X200 Service Manual"

    private func readyApp() -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports six documents first
        waitFor(app.buttons["doc-\(manual)"], timeout: 30)
        // Contents only exist for documents that are ready.
        let ready = app.descendants(matching: .any).matching(identifier: "status-ready")
        let allReady = NSPredicate(format: "count >= 5")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: allReady, object: ready)], timeout: 60), .completed)
        return app
    }

    private func openContents(_ app: XCUIApplication, of title: String? = nil) {
        let control = element(app, "contents-\(title ?? manual)")
        waitFor(control, timeout: 30)
        control.tap()
        waitFor(element(app, "contentsKind"))
    }

    private func showImages(_ app: XCUIApplication) {
        element(app, "contentsKind").buttons.element(boundBy: 1).tap()
    }

    private func label(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func selectChunk(_ app: XCUIApplication, _ ordinal: Int) {
        let row = element(app, "chunkRow-\(ordinal)")
        waitFor(row)
        row.tap()
        waitFor(element(app, "chunkPreview"))
    }

    // MARK: 2.1 the control

    func testTheControlIsOnReadyDocumentsOnlyAndBackReturnsToTheLibrary() {
        let app = readyApp()
        waitFor(element(app, "contents-\(manual)"))
        XCTAssertFalse(element(app, "contents-Nameplate X100").exists, "a photo document has nothing to drill into")

        openContents(app)
        waitFor(app.navigationBars[manual])
        app.navigationBars[manual].buttons["Library"].tap()
        waitFor(app.buttons["doc-\(manual)"])
    }

    func testTappingTheRowStillOpensTheDocumentAndLeavesTheLibraryShowing() {
        let app = readyApp()
        app.buttons["doc-X200 Manual"].tap()
        waitFor(element(app, "sourceTitle"))
        XCTAssertEqual(element(app, "sourceTitle").label, "X200 Manual")
        XCTAssertTrue(app.buttons["doc-\(manual)"].exists)
        XCTAssertFalse(element(app, "contentsKind").exists)
    }

    // MARK: 2.4 the lists

    func testAPdfsChunksAreListedUnderPageHeadersWithAPhotoMarkOnTheImagesChunk() {
        let app = readyApp()
        openContents(app)
        waitFor(label(app, "Page 1"))
        XCTAssertTrue(label(app, "Page 2").exists)
        XCTAssertTrue(label(app, "Page 3").exists)
        waitFor(element(app, "chunkRow-0"))
        XCTAssertTrue(label(app, "Stands for a photo").exists, "the chunk of the figure carries the photo mark")
    }

    func testAnImageListShowsThePicturesAndATextDocumentSaysItHasNone() {
        let app = readyApp()
        openContents(app)
        showImages(app)
        waitFor(element(app, "imageRow-0"))
        XCTAssertFalse(element(app, "contentsEmpty").exists)

        app.navigationBars[manual].buttons["Library"].tap()
        openContents(app, of: "Warranty")
        showImages(app)
        waitFor(element(app, "contentsEmpty"))
    }

    // MARK: 3.2 the chunk card

    func testSelectingAChunkShowsItsCardAndNextStepsInListOrder() {
        let app = readyApp()
        openContents(app)
        selectChunk(app, 0)

        XCTAssertTrue(element(app, "chunkPosition").label.hasPrefix("Chunk 1 of "), element(app, "chunkPosition").label)
        XCTAssertFalse(element(app, "previousChunk").isEnabled)
        let text = element(app, "chunkText").label
        XCTAssertTrue(text.contains("X200 Service Manual"), text)

        element(app, "nextChunk").tap()
        let second = NSPredicate(format: "label BEGINSWITH 'Chunk 2 of '")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: second, object: element(app, "chunkPosition"))], timeout: 10), .completed,
                       element(app, "chunkPosition").label)
        XCTAssertTrue(element(app, "previousChunk").isEnabled)
    }

    func testSelectingAChunkWhileXrayIsShowingSwitchesToSource() {
        let app = readyApp()
        let picker = element(app, "detailTabPicker")
        waitFor(picker)
        picker.buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))

        openContents(app)
        selectChunk(app, 0)
        XCTAssertTrue(element(app, "chunkPreview").isHittable)
    }

    // MARK: 3.3 the image card

    func testAnImageCardShowsThePictureAndItsChunkLinkSelectsTheBadgedChunk() {
        let app = readyApp()
        openContents(app)
        showImages(app)
        let row = element(app, "imageRow-0")
        waitFor(row)
        row.tap()
        waitFor(element(app, "imagePreview"))
        waitFor(element(app, "previewImage"))
        XCTAssertTrue(label(app, "Size").exists)
        let caption = element(app, "imagePreview").descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Figure 1'")).firstMatch
        XCTAssertTrue(caption.exists, "the card shows the caption printed under the figure")

        element(app, "showChunk").tap()
        waitFor(element(app, "chunkPreview"))
        XCTAssertTrue(element(app, "chunkPosition").exists)
        XCTAssertTrue(element(app, "chunkPreview").descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo'")).firstMatch.exists,
                      "the card of the image's chunk is marked as a photo")
    }

    // MARK: 3.4 show in document

    func testShowInDocumentOpensThePdfAtTheChunksPage() {
        let app = readyApp()
        openContents(app)
        selectChunk(app, 1)   // the second page's text
        element(app, "showInDocument").tap()
        waitFor(element(app, "sourcePage"))
        XCTAssertTrue(element(app, "sourcePage").label.hasPrefix("Page 2"), element(app, "sourcePage").label)
        XCTAssertEqual(element(app, "sourceTitle").label, manual)
    }

    // MARK: 4.2 4.3

    func testResettingTheDemoWhileContentsAreOpenReturnsToTheLibrary() {
        let app = readyApp()
        openContents(app)
        selectChunk(app, 0)

        let picker = element(app, "detailTabPicker")
        picker.buttons["X-ray"].tap()
        let reset = element(app, "xrayResetButton")
        waitFor(reset)
        waitEnabled(reset)
        reset.tap()
        let confirm = app.buttons["Delete everything and import the samples"].firstMatch
        waitFor(confirm)
        confirm.tap()

        waitFor(app.buttons["doc-Couchbase Under the Hood"], timeout: 60)
        XCTAssertFalse(element(app, "contentsKind").exists)
    }

    func testLoadingContentsIsOneXrayOperationAndSteppingAddsNothing() {
        let app = readyApp()
        openContents(app)
        selectChunk(app, 0)
        element(app, "nextChunk").tap()
        element(app, "nextChunk").tap()

        let picker = element(app, "detailTabPicker")
        picker.buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))
        let groups = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "xrayGroup-Contents of “\(manual)”"))
        waitFor(groups.firstMatch)
        // Accessibility reports a group's container and its header text separately; one operation has one frame.
        XCTAssertEqual(Set(groups.allElementsBoundByIndex.map { "\($0.frame)" }).count, 1, "one operation for loading the contents")
        let all = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'xrayGroup-'"))
        let before = all.count
        XCTAssertTrue(groups.firstMatch.label.contains("2 events"), groups.firstMatch.label)   // the chunk query and the image query

        picker.buttons["Source"].tap()
        element(app, "nextChunk").tap()
        picker.buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))
        XCTAssertEqual(all.count, before, "stepping reads nothing")
    }

    // MARK: 6.2 open in Database

    private func explorerTitle(_ app: XCUIApplication, startingWith prefix: String) -> XCUIElement {
        app.navigationBars.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    func testOpenInDatabaseFromAChunkShowsItsRecordAsJSONAndClosingReturnsToTheCard() {
        let app = readyApp()
        openContents(app)
        selectChunk(app, 0)
        element(app, "chunkPreview").buttons["openInDatabase"].tap()

        waitFor(element(app, "explorerJSON"))
        waitFor(explorerTitle(app, startingWith: "chunks/"))
        XCTAssertTrue(element(app, "xrayStoredDocument").label.contains("embeddingModel"))
        // The document link is one line of the JSON, and the JSON fits the screen.
        let link = element(app, "explorerRef-docId")
        waitFor(link)
        XCTAssertLessThan(link.frame.height, 30, "the link should not wrap: \(link.frame)")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThanOrEqual(element(app, "explorerJSON").frame.maxX, window.maxX + 1, "the JSON must not run off the screen")
        waitFor(element(app, "explorerShowFull-embedding"))

        element(app, "explorerDone").tap()
        waitFor(element(app, "chunkPreview"))
        XCTAssertTrue(element(app, "chunkPosition").label.hasPrefix("Chunk 1 of "))
    }

    func testOpenInDatabaseFromAnImageOffersThePreviewNextToItsBlob() {
        let app = readyApp()
        openContents(app)
        showImages(app)
        let row = element(app, "imageRow-0")
        waitFor(row)
        row.tap()
        waitFor(element(app, "imagePreview"))
        element(app, "imagePreview").buttons["openInDatabase"].tap()

        waitFor(explorerTitle(app, startingWith: "images/"))
        let preview = element(app, "explorerPreview-image")
        waitFor(preview)
        preview.tap()
        waitFor(element(app, "explorerImagePreview"))

        element(app, "explorerHidePreview-image").tap()
        waitFor(element(app, "explorerPreview-image"))
        XCTAssertFalse(element(app, "explorerImagePreview").exists, "the preview can be hidden again")
    }

    func testOpenInDatabaseFromAnOpenDocumentShowsItsDocumentRecord() {
        let app = readyApp()
        app.buttons["doc-\(manual)"].tap()
        waitFor(element(app, "sourcePage"))
        let button = app.buttons.matching(identifier: "openInDatabase").firstMatch
        waitFor(button)
        button.tap()

        waitFor(explorerTitle(app, startingWith: "documents/"))
        waitFor(element(app, "explorerChildren"))
    }
}
