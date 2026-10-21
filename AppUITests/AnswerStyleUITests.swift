import XCTest

/// The Answer style page and replies not from the documents (grounded-chat spec), on the stand-in services.
final class AnswerStyleUITests: UITestCase {
    private func readyApp() -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 30)
        waitFor(app.buttons["doc-X200 Manual"])
        return app
    }

    private func openAnswerStyle(_ app: XCUIApplication) {
        element(app, "settingsButton").tap()
        waitFor(element(app, "settingsSheet"))
        element(app, "settingsAnswersRow").tap()
        waitFor(element(app, "answerStyleSlider"))
    }

    private func heading(_ app: XCUIApplication) -> String { element(app, "answerStyleHeading").label }

    /// Moves the slider to an offset from the tuned distance (the slider runs from -0.06 to +0.10).
    private func setOffset(_ app: XCUIApplication, _ offset: Double) {
        element(app, "answerStyleSlider").adjust(toNormalizedSliderPosition: (offset + 0.06) / 0.16)
    }

    func testTheSliderNamesTheStopAndItsDistanceAndResetsToBalanced() {
        let app = readyApp()
        openAnswerStyle(app)
        // At the embedding model's tuned distance: 0.76 for the stand-in model, 0.28 for EmbeddingGemma 2.
        let start = heading(app)
        XCTAssertEqual(start, "Balanced · 0.76")
        XCTAssertFalse(element(app, "answerStyleReset").isEnabled, "already Balanced")

        setOffset(app, 0.10)
        XCTAssertTrue(heading(app).hasPrefix("Open · "), heading(app))
        XCTAssertTrue(element(app, "answerStyleHint").label.contains("can be wrong"))

        element(app, "answerStyleReset").tap()
        XCTAssertEqual(heading(app), start)
    }

    func testAConversationalReplyIsMarkedAsNotFromTheDocuments() {
        let app = readyApp()
        openAnswerStyle(app)
        setOffset(app, 0.04)
        XCTAssertTrue(heading(app).hasPrefix("Conversational · "), heading(app))
        backToSettings(app, from: "Answer style")
        element(app, "settingsDone").tap()
        waitFor(app.navigationBars["Library"], timeout: 30)

        ask(app, "Tell me about quantum computing")
        waitFor(element(app, "notFromDocumentsLabel"), timeout: 15)
        XCTAssertTrue(element(app, "assistantMessage").label.contains("manuals in your library"))
        XCTAssertFalse(element(app, "notFoundMessage").exists)
        XCTAssertFalse(app.staticTexts["Sources"].exists, "a reply not from the documents has no sources")
    }
}
