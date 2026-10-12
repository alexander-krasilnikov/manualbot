import XCTest

/// The Sync page and the cloud in the toolbar, on the stand-in replicator (`-uiTestSync <scenario>`).
final class SyncUITests: UITestCase {
    private func library(_ scenario: String? = nil) -> XCUIApplication {
        let app = launch(extra: scenario.map { ["-uiTestSync", $0] } ?? [])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)
        return app
    }

    /// Taps the switch itself: the middle of the row is its label, which does not flip it.
    private func flipSyncSwitch(_ app: XCUIApplication) {
        let row = element(app, "syncToggle")
        waitFor(row)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    }

    /// The Sync page's state row is one element, labelled like "State, Up to date".
    private func waitForPageState(_ summary: String, in app: XCUIApplication, timeout: TimeInterval = 15, line: UInt = #line) {
        let row = element(app, "syncState")
        waitFor(row, line: line)
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", summary), object: row)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: timeout), .completed,
                       "the state row says “\(row.label)”, expected “\(summary)”", line: line)
    }

    /// The toolbar's cloud says its state in its label: "Sync: Up to date".
    private func waitForCloud(_ summary: String, in app: XCUIApplication, timeout: TimeInterval = 15) {
        let indicator = element(app, "syncIndicator")
        waitFor(indicator)
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Sync: \(summary)"), object: indicator)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: timeout), .completed,
                       "the cloud says “\(indicator.label)”, expected “Sync: \(summary)”")
    }

    func testTheGearOpensSettingsWithModelsAndSync() {
        let app = library()
        element(app, "settingsButton").tap()
        waitFor(element(app, "settingsSheet"))
        waitFor(element(app, "settingsModelsRow"))
        waitFor(element(app, "settingsSyncRow"))

        element(app, "settingsSyncRow").tap()
        waitFor(element(app, "syncPage"))
        backToSettings(app, from: "Sync")
        element(app, "settingsModelsRow").tap()
        waitFor(element(app, "modelsPage"))
    }

    func testTheCloudShowsEachStateAndOpensTheSyncPage() {
        let states = [("off", "Off"), ("syncing", "Syncing…"), ("upToDate", "Up to date"), ("paused", "Paused"), ("error", "Error")]
        for (scenario, summary) in states {
            let app = library(scenario)
            waitForCloud(summary, in: app)

            element(app, "syncIndicator").tap()
            waitFor(element(app, "syncPage"))
            waitForPageState(summary, in: app)
            app.terminate()
        }
    }

    func testAPausedSyncSaysWhy() {
        let app = library("paused")
        element(app, "syncIndicator").tap()
        waitFor(element(app, "syncDetail"))
        let reason = element(app, "syncDetail").label
        XCTAssertTrue(reason.contains("paused"), reason)
        XCTAssertTrue(reason.contains("EmbeddingGemma 2"), "the reason names the fleet model: \(reason)")
    }

    func testARefusedLoginSaysSo() {
        let app = library("error")
        element(app, "syncIndicator").tap()
        waitFor(element(app, "syncDetail"))
        XCTAssertTrue(element(app, "syncDetail").label.contains("refused"))
    }

    func testEnteringTheServerAndTurningSyncOn() {
        let app = library()
        waitForCloud("Off", in: app)
        element(app, "syncIndicator").tap()
        waitFor(element(app, "syncPage"))

        let address = element(app, "syncAddress")
        address.tap()
        address.typeText("localhost:4984")
        let username = element(app, "syncUsername")
        username.tap()
        username.typeText("ipad1")
        let password = element(app, "syncPassword")
        password.tap()
        password.typeText("secret")
        flipSyncSwitch(app)

        waitForPageState("Up to date", in: app)
        backToSettings(app, from: "Sync")
        element(app, "settingsDone").tap()
        waitForCloud("Up to date", in: app)
    }

    func testTurningSyncOffFromThePage() {
        let app = library("upToDate")
        waitForCloud("Up to date", in: app)
        element(app, "syncIndicator").tap()
        waitFor(element(app, "syncToggle"))
        flipSyncSwitch(app)
        waitForPageState("Off", in: app)
    }
}
