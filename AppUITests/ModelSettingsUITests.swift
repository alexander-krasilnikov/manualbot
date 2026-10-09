import XCTest

/// The Models page (model-catalog spec), on the stand-in services: two models are installed by the first-run setup, a second
/// embedding model is offered from the catalog, and the search finds a scripted set of language models.
final class ModelSettingsUITests: UITestCase {
    private let defaultEmbedder = "embeddinggemma-2-text-vision-440m"
    private let defaultGenerator = "gemma-4-e2b"
    private let otherEmbedder = "stub-text-embedder"

    private func readyApp(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"] + extra)
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)   // seeding imports five documents first
        waitFor(app.buttons["doc-X200 Manual"])
        return app
    }

    private func openModels(_ app: XCUIApplication) {
        element(app, "settingsButton").tap()
        waitFor(element(app, "settingsSheet"))
        element(app, "settingsModelsRow").tap()
        waitFor(element(app, "modelsPage"))
    }

    private func closeModels(_ app: XCUIApplication) {
        backToSettings(app, from: "Models")
        element(app, "settingsDone").tap()
        waitFor(app.navigationBars["Library"], timeout: 30)
    }

    /// Downloads the stand-in embedding model offered by the catalog, and waits until it is installed.
    private func installOtherEmbedder(_ app: XCUIApplication) {
        let download = element(app, "downloadModel-\(otherEmbedder)")
        waitFor(download)
        download.tap()
        waitFor(element(app, "installedModel-\(otherEmbedder)"))
    }

    /// Taps a button of the alert on screen by its title. The alert can expose a button more than once, so the first one is used.
    private func tapAlertButton(_ app: XCUIApplication, _ title: String) {
        let button = app.alerts.firstMatch.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        waitFor(button)
        button.tap()
    }

    private func search(_ app: XCUIApplication, for text: String) {
        let field = element(app, "modelSearchField")
        waitFor(field)
        field.tap()
        field.typeText(text)
        element(app, "modelSearchButton").tap()
    }

    func testThePageShowsTheTwoDefaultsAsInUse() {
        let app = readyApp()
        openModels(app)
        waitFor(element(app, "inUse-\(defaultEmbedder)"))
        waitFor(element(app, "inUse-\(defaultGenerator)"))
        XCTAssertTrue(app.staticTexts["EmbeddingGemma 2"].exists)
        XCTAssertTrue(app.staticTexts["Gemma 4 E2B"].exists)
        XCTAssertTrue(element(app, "storageAvailable").exists)
        // Embedding models are offered on this page too, from the list the app ships with.
        XCTAssertTrue(app.staticTexts["Embedding models"].exists || element(app, "downloadModel-\(otherEmbedder)").exists)
        XCTAssertFalse(element(app, "deleteModel-\(defaultEmbedder)").exists, "the model in use cannot be deleted")
    }

    func testActivatingAnotherEmbedderNamesTheCostAndConfirmingReindexesTheLibrary() {
        let app = readyApp()
        openModels(app)
        installOtherEmbedder(app)
        element(app, "useModel-\(otherEmbedder)").tap()

        let alert = app.alerts.firstMatch
        waitFor(alert)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS '5 documents will be re-indexed'")).firstMatch.exists,
                      "the confirmation counts the documents")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'cannot analyze photos'")).firstMatch.exists)
        tapAlertButton(app, "Use Stub Text Embedder")

        waitFor(element(app, "inUse-\(otherEmbedder)"), timeout: 60)
        closeModels(app)

        // Every document is indexed again by the new model, and the new model has no photos: the photo controls say so.
        let ready = app.descendants(matching: .any).matching(identifier: "status-ready")
        if !ready.element(boundBy: 2).waitForExistence(timeout: 180) {
            func count(_ id: String) -> Int { app.descendants(matching: .any).matching(identifier: id).count }
            XCTFail("after the switch: ready \(count("status-ready")), working \(count("status-working")), queued \(count("status-queued")), failed \(count("status-failed")), rows \(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'doc-'")).count)")
        }
        waitFor(element(app, "photosUnavailableButton"), timeout: 30)
        XCTAssertFalse(element(app, "attachPhotoButton").exists)
        element(app, "photosUnavailableButton").tap()
        let explanation = app.alerts.firstMatch
        waitFor(explanation)
        XCTAssertTrue(explanation.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Stub Text Embedder'")).firstMatch.exists,
                      "the explanation names the embedding model in use")
    }

    func testDismissingTheConfirmationChangesNothing() {
        let app = readyApp()
        openModels(app)
        installOtherEmbedder(app)
        element(app, "useModel-\(otherEmbedder)").tap()
        waitFor(app.alerts.firstMatch)
        tapAlertButton(app, "Cancel")

        XCTAssertTrue(element(app, "inUse-\(defaultEmbedder)").exists)
        XCTAssertFalse(element(app, "inUse-\(otherEmbedder)").exists)
        XCTAssertTrue(element(app, "installedModel-\(otherEmbedder)").exists, "it stays installed, unused")
    }

    func testAnOfflineSearchSaysSearchingNeedsAConnection() {
        let app = readyApp(["-uiTestSearch", "offline"])
        openModels(app)
        search(app, for: "gemma")
        let message = element(app, "searchOffline")
        waitFor(message)
        XCTAssertTrue(message.label.contains("Searching needs a network connection"))
        XCTAssertTrue(element(app, "inUse-\(defaultGenerator)").exists, "the installed models keep working")
    }

    func testASearchJudgesEachResultBeforeItIsDownloaded() {
        let app = readyApp()
        openModels(app)
        search(app, for: "gemma")
        waitFor(element(app, "verdict-stub-gemma-small"))
        XCTAssertEqual(element(app, "verdict-stub-gemma-small").label, "Checked after download")
        element(app, "settingsSheet").swipeUp()   // the keyboard covers the lower rows until the list is scrolled
        waitFor(element(app, "verdict-stub-embedder-file"))
        XCTAssertEqual(element(app, "verdict-stub-embedder-file").label, "Checked after download")
        XCTAssertTrue(element(app, "untested-stub-embedder-file").exists, "an embedding model outside the built-in list is flagged")
        waitFor(element(app, "verdict-stub-gemma-huge"))
        XCTAssertEqual(element(app, "verdict-stub-gemma-huge").label, "Too large for this iPad")
        XCTAssertTrue(element(app, "downloadModel-stub-gemma-small").exists)
        XCTAssertTrue(element(app, "downloadModel-stub-embedder-file").exists, "an embedding model can be downloaded too")
        XCTAssertFalse(element(app, "downloadModel-stub-gemma-huge").exists, "a model too large for the device cannot be downloaded")
    }

    func testAnEmbeddingModelFoundBySearchIsUntestedAndUsingItSaysSo() {
        let app = readyApp()
        openModels(app)
        search(app, for: "embed")
        let download = element(app, "downloadModel-stub-embedder-file")
        waitFor(download)
        download.tap()
        // The list is scrolled to the search, so the result itself shows that the download finished.
        let installed = element(app, "searchResult-stub-embedder-file").descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Installed'")).firstMatch
        waitFor(installed)
        XCTAssertTrue(element(app, "untested-stub-embedder-file").exists, "flagged as untested")
        element(app, "settingsSheet").swipeDown()
        element(app, "settingsSheet").swipeDown()
        waitFor(element(app, "installedModel-stub-embedder-file"))
        XCTAssertFalse(element(app, "inUse-stub-embedder-file").exists, "downloading does not switch")

        let use = element(app, "useModel-stub-embedder-file")
        waitFor(use)
        use.tap()
        waitFor(app.alerts.firstMatch)
        XCTAssertTrue(app.alerts.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not been tested'")).firstMatch.exists)
        tapAlertButton(app, "Cancel")
        XCTAssertFalse(element(app, "inUse-stub-embedder-file").exists, "nothing changes unless the user confirms")
    }

    func testAModelInstalledFromSearchIsListedWithItsLicenceInAbout() {
        let app = readyApp()
        openModels(app)
        search(app, for: "gemma")
        let download = element(app, "downloadModel-stub-gemma-small")
        waitFor(download)
        download.tap()
        // The list is scrolled to the search, so the result itself shows that the download finished.
        let installed = element(app, "searchResult-stub-gemma-small").descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Installed'")).firstMatch
        waitFor(installed)
        closeModels(app)

        element(app, "aboutButton").tap()
        waitFor(app.staticTexts["Stub Gemma Small"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Licensed under the MIT License'")).firstMatch.exists,
                      "the licence its repository states")
        XCTAssertTrue(app.staticTexts["EmbeddingGemma 2"].exists, "the defaults are listed too")
    }

    func testASearchIsRecordedInTheXrayAsAModelRequest() {
        let app = readyApp()
        openModels(app)
        search(app, for: "gemma")
        waitFor(element(app, "verdict-stub-gemma-small"))
        closeModels(app)

        let picker = element(app, "detailTabPicker")
        waitFor(picker)
        picker.buttons["X-ray"].tap()
        waitFor(element(app, "xrayPanel"))
        waitFor(element(app, "xrayGroup-Model search"))
    }
}
