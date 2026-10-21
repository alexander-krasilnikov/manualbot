import XCTest

/// The manual catalog, driven with a stub downloader that serves a small PDF for every entry (and refuses the entries a test
/// names), so nothing here uses the network.
final class CatalogUITests: UITestCase {
    private let datasheet = "couchbase-capella-datasheet"
    private let datasheetTitle = "Couchbase Capella datasheet"
    private let edgeDatasheet = "couchbase-edge-server-datasheet"
    private let security = "couchbase-capella-security-and-data-protection"

    /// An app past model setup with an empty library.
    private func readyApp(extra: [String] = []) -> XCUIApplication {
        let app = launch(extra: extra)
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)
        return app
    }

    private func openCatalogFromEmptyLibrary(_ app: XCUIApplication) {
        let button = element(app, "emptyImportCatalog")
        waitFor(button)
        button.tap()
        waitFor(app.navigationBars["Manual catalog"])
    }

    /// The library's narrow column keeps the toolbar's last buttons in the system's "More" menu, where Import is a submenu.
    private func openImportMenu(_ app: XCUIApplication) {
        let direct = element(app, "importButton")
        if direct.waitForExistence(timeout: 2) {
            direct.tap()
        } else {
            app.navigationBars["Library"].buttons["More"].tap()
            let submenu = app.buttons["Import"]
            waitFor(submenu)
            submenu.tap()
        }
    }

    private func openCategory(_ app: XCUIApplication, _ name: String) {
        let row = element(app, "catalogCategory-\(name)")
        waitFor(row)
        row.tap()
    }

    private func state(_ app: XCUIApplication, _ id: String) -> XCUIElement { element(app, "catalogState-\(id)") }

    /// The words of a row's state, however SwiftUI exposes them.
    private func stateText(_ app: XCUIApplication, _ id: String) -> String {
        let element = state(app, id)
        return element.label.isEmpty ? (element.value as? String ?? "") : element.label
    }

    private func waitForState(_ app: XCUIApplication, _ id: String, containing text: String, timeout: TimeInterval = 30) {
        let element = state(app, id)
        waitFor(element, timeout: timeout)
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout), .completed,
                       "\(id) never showed “\(text)”; it shows “\(stateText(app, id))”")
    }

    /// The first download from a host asks first; this accepts.
    private func acceptNotice(_ app: XCUIApplication) {
        let download = element(app, "catalogNoticeDownload")
        waitFor(download)
        download.tap()
    }

    // MARK: 6.1 two ways in

    func testBothImportRoutesOpenTheCatalogAndFilesStillOpensThePicker() {
        let app = readyApp()
        openCatalogFromEmptyLibrary(app)
        element(app, "catalogDone").tap()
        waitFor(app.navigationBars["Library"])

        openImportMenu(app)
        element(app, "importCatalog").tap()
        waitFor(app.navigationBars["Manual catalog"])
        element(app, "catalogDone").tap()
        waitFor(app.navigationBars["Library"])

        openImportMenu(app)
        element(app, "importFiles").tap()
        // The system's file picker is another process's view: it brings its own Cancel, and the catalog is not showing.
        let cancel = app.buttons["Cancel"]
        waitFor(cancel, timeout: 15)
        XCTAssertFalse(app.navigationBars["Manual catalog"].exists)
        cancel.tap()
    }

    // MARK: 6.2 finding entries

    func testSearchingForOutboardListsOnlyMatchingEntries() {
        let app = readyApp()
        openCatalogFromEmptyLibrary(app)
        waitFor(element(app, "catalogRow-hyundai-owners-manual-model-code-qx-venue-my2025-us-english"))

        let search = app.searchFields.firstMatch
        waitFor(search)
        search.tap()
        search.typeText("outboard")
        waitFor(element(app, "catalogRow-honda-bf25a-bf30a-outboard-owners-manual-2002"))
        XCTAssertTrue(element(app, "catalogRow-tohatsu-outboard-motors-2026-range-brochure").exists)
        XCTAssertFalse(element(app, "catalogRow-hyundai-owners-manual-model-code-qx-venue-my2025-us-english").exists)
        XCTAssertFalse(element(app, datasheet).exists)

        search.typeText(" nonsense")
        waitFor(element(app, "catalogEmpty"))
    }

    func testTheCatalogFilterShowsOnlyCatalogsAndKeepsTheCategoriesThatHaveOne() {
        let app = readyApp()
        openCatalogFromEmptyLibrary(app)
        openCategory(app, "Couchbase")
        waitFor(element(app, "catalogRow-\(datasheet)"))
        waitFor(element(app, "catalogRow-\(security)"))

        element(app, "catalogKind").buttons["Catalogs"].tap()
        waitFor(element(app, "catalogRow-\(datasheet)"))
        XCTAssertTrue(element(app, "catalogRow-\(edgeDatasheet)").exists)
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: element(app, "catalogRow-\(security)"))], timeout: 5), .completed,
                       "a whitepaper is not listed under the catalog filter")
    }

    // MARK: 6.2 importing

    func testASingleImportNamesTheHostAndReachesTheLibrary() {
        let app = readyApp()
        openCatalogFromEmptyLibrary(app)
        openCategory(app, "Couchbase")
        let importButton = element(app, "catalogImport-\(datasheet)")
        waitFor(importButton)
        importButton.tap()

        // Before anything is downloaded, the first download from a host says where it goes.
        let download = element(app, "catalogNoticeDownload")
        waitFor(download)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'info.couchbase.com'")).count > 0)
        download.tap()

        waitForState(app, datasheet, containing: "In library")
        XCTAssertFalse(element(app, "catalogImport-\(datasheet)").exists, "an entry in the library offers no import")
        element(app, "catalogDone").tap()
        waitFor(app.buttons["doc-\(datasheetTitle)"], timeout: 30)
    }

    func testAnImportedDocumentSaysWhereItCameFromInItsDetails() {
        let app = readyApp()
        openCatalogFromEmptyLibrary(app)
        openCategory(app, "Couchbase")
        let importButton = element(app, "catalogImport-\(datasheet)")
        waitFor(importButton)
        importButton.tap()
        acceptNotice(app)
        waitForState(app, datasheet, containing: "In library")
        element(app, "catalogDone").tap()

        let contents = element(app, "contents-\(datasheetTitle)")
        waitFor(contents, timeout: 60)   // only a document that is ready has contents
        contents.tap()
        let origin = element(app, "documentOrigin")
        waitFor(origin)
        XCTAssertTrue(origin.label.contains("info.couchbase.com"), "shows “\(origin.label)”")
    }

    func testSeveralEntriesImportAndTheRefusedOneOffersRetryAndTheBrowser() {
        let app = readyApp(extra: ["-uiTestCatalogFailing", security])
        openCatalogFromEmptyLibrary(app)
        openCategory(app, "Couchbase")
        for id in [datasheet, edgeDatasheet, security] {
            let select = element(app, "catalogSelect-\(id)")
            waitFor(select)
            select.tap()
        }
        let importSelected = element(app, "catalogImportSelected")
        XCTAssertEqual(importSelected.label, "Import 3")
        importSelected.tap()
        acceptNotice(app)

        waitForState(app, datasheet, containing: "In library")
        waitForState(app, edgeDatasheet, containing: "In library")
        waitForState(app, security, containing: "does not allow automatic downloads")
        waitFor(element(app, "catalogRetry-\(security)"))
        XCTAssertTrue(element(app, "catalogBrowser-\(security)").exists, "a refusing publisher's file can be opened in the browser")
        XCTAssertFalse(element(app, "catalogRetry-\(datasheet)").exists)
    }

    func testADownloadInProgressCanBeCancelled() {
        let app = readyApp(extra: ["-uiTestCatalogSlow"])
        openCatalogFromEmptyLibrary(app)
        openCategory(app, "Couchbase")
        let importButton = element(app, "catalogImport-\(datasheet)")
        waitFor(importButton)
        importButton.tap()
        acceptNotice(app)

        waitForState(app, datasheet, containing: "Downloading")
        let cancel = element(app, "catalogCancel-\(datasheet)")
        waitFor(cancel)
        cancel.tap()
        waitForState(app, datasheet, containing: "Not imported")
        waitFor(element(app, "catalogImport-\(datasheet)"))
    }

    func testAnEntrysDetailsShowThePublisherTheLicenceAndTheAddress() {
        let app = readyApp()
        openCatalogFromEmptyLibrary(app)
        openCategory(app, "Couchbase")
        let row = element(app, "catalogRow-\(datasheet)")
        waitFor(row)
        row.tap()
        waitFor(element(app, "catalogDetailLicence"))
        XCTAssertTrue(element(app, "catalogDetailPublisher").exists)
        let address = element(app, "catalogDetailAddress")
        // The source section sits below the fold of the sheet, and a list builds only the rows it shows.
        for _ in 0..<3 where !address.exists { app.swipeUp() }
        waitFor(address)
        let shown = address.label.isEmpty ? (address.value as? String ?? "") : address.label
        XCTAssertTrue(shown.hasPrefix("https://info.couchbase.com/"), "the address shows “\(shown)”")
        XCTAssertTrue(element(app, "catalogDetailBrowser").exists)
    }
}
