import XCTest

@MainActor
class UITestCase: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        // The three-column layout is the landscape one; portrait collapses the library into a sidebar toggle.
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func launch(_ scenario: String = "happy", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestModelStub", scenario] + extra
        // `TEST_RUNNER_UITEST_DEMO_MODE=1 xcodebuild test …` runs the whole suite with demo mode on.
        if ProcessInfo.processInfo.environment["UITEST_DEMO_MODE"] != nil, !extra.contains("-demoMode") {
            app.launchArguments.append("-demoMode")
        }
        app.launch()
        return app
    }

    /// Finds an element by accessibility identifier regardless of its type.
    func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) did not appear", file: file, line: line)
    }

    func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "\(element) never became enabled", file: file, line: line)
    }

    func ask(_ app: XCUIApplication, _ question: String) {
        let input = element(app, "chatInput")
        waitEnabled(input)
        input.tap()
        input.typeText(question)
        element(app, "sendButton").tap()
    }
}

final class ModelSetupUITests: UITestCase {
    func testFirstLaunchShowsModelsSizesAndStorage() {
        let app = launch()
        waitFor(app.navigationBars["Set up models"], timeout: 5)
        XCTAssertTrue(app.staticTexts["EmbeddingGemma 300M"].exists)
        XCTAssertTrue(app.staticTexts["Gemma 4 E4B"].exists)
        XCTAssertTrue(app.staticTexts["Storage"].exists)
        XCTAssertTrue(app.buttons["startDownload"].isEnabled)
    }

    func testDownloadCompletesAndEnablesChat() {
        let app = launch(extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"])
        waitEnabled(element(app, "chatInput"))
        XCTAssertFalse(element(app, "languageModelBanner").exists)
    }

    func testEmbedderReadyBeforeLanguageModel() {
        let app = launch("llmFailsOnce", extra: ["-uiTestSeed"])
        app.buttons["startDownload"].tap()

        // Import is available (library shown) while chat waits for the language model.
        waitFor(app.navigationBars["Library"])
        XCTAssertFalse(element(app, "chatInput").isEnabled)
        waitFor(element(app, "chatDisabledReason"))

        app.buttons["retry-gemma-4-e4b"].tap()
        waitEnabled(element(app, "chatInput"))
    }

    func testABundledEmbedderMeansNoSetupScreenAndOnlyTheLanguageModelIsDownloaded() {
        let app = launch("bundled", extra: ["-uiTestSeed"])
        // Straight to the workspace: importing and searching need nothing to be downloaded.
        waitFor(app.navigationBars["Library"])
        XCTAssertFalse(app.navigationBars["Set up models"].exists)
        XCTAssertFalse(element(app, "chatInput").isEnabled, "chat waits for the language model")
        waitFor(element(app, "languageModelBanner"))
        XCTAssertFalse(app.staticTexts["EmbeddingGemma 300M"].exists, "the built-in model is not offered for download")
        XCTAssertTrue(app.staticTexts["Gemma 4 E4B"].exists)

        app.buttons["startDownload"].tap()
        waitEnabled(element(app, "chatInput"))
    }

    func testAboutCarriesTheGemmaNotice() {
        let app = launch("bundled", extra: ["-uiTestSeed"])
        waitFor(app.navigationBars["Library"])
        element(app, "aboutButton").tap()
        waitFor(app.staticTexts["EmbeddingGemma 300M"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Gemma Terms of Use'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Gemma 4 E4B"].exists)
    }

    func testInsufficientStorageDisablesDownload() {
        let app = launch("lowStorage")
        waitFor(app.staticTexts["insufficientStorage"], timeout: 5)
        XCTAssertFalse(app.buttons["startDownload"].isEnabled)
    }
}

final class WorkspaceUITests: UITestCase {
    private func readyApp(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(extra: ["-uiTestSeed"] + extra)
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"])
        waitFor(app.buttons["doc-X200 Manual"])
        return app
    }

    func testSeededPhotoDocumentIsReadyWithAThumbnail() {
        let app = readyApp()
        let row = app.buttons["doc-Nameplate X100"]
        waitFor(row)
        let shown = NSPredicate(format: "value == 'thumbnail shown'")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shown, object: row)], timeout: 30), .completed,
                       "the photo's row should show its picture; value was \(String(describing: row.value))")
        XCTAssertTrue(row.label.contains("Photo"), row.label)
    }

    func testSeededDocumentsAreReadyInTheLibrary() {
        let app = readyApp()
        XCTAssertTrue(app.buttons["doc-Warranty"].exists)
        let ready = app.descendants(matching: .any).matching(identifier: "status-ready")
        XCTAssertGreaterThanOrEqual(ready.count, 2)
    }

    func testAnswerCitesASourceThatOpensWithTheHighlightedPassage() {
        let app = readyApp()
        ask(app, "How do I reset the X200?")

        let answer = element(app, "assistantMessage")
        waitFor(answer, timeout: 15)
        XCTAssertTrue(answer.label.contains("power button"), "answer was: \(answer.label)")
        let citation = element(app, "citation-1")
        waitFor(citation)

        citation.tap()
        waitFor(element(app, "highlightedPassage"))
        XCTAssertEqual(element(app, "sourceTitle").label, "X200 Manual")
    }

    func testAttachingAPhotoShowsItAndLetsItBeSentWithoutWords() {
        let app = readyApp()
        XCTAssertFalse(element(app, "sendButton").isEnabled, "nothing to send yet")
        element(app, "attachPhotoButton").tap()
        waitFor(element(app, "attachedPhoto"))
        waitEnabled(element(app, "sendButton"))

        element(app, "removePhotoButton").tap()
        XCTAssertFalse(element(app, "attachedPhoto").exists)
        XCTAssertFalse(element(app, "sendButton").isEnabled)

        element(app, "attachPhotoButton").tap()
        element(app, "sendButton").tap()
        waitFor(element(app, "userPhoto"), timeout: 15)
        XCTAssertFalse(element(app, "attachedPhoto").exists, "the photo goes with the question")
    }

    func testAPhotoAloneIsAnsweredWithTheMatchingPhotoAndItsPage() {
        let app = readyApp()
        element(app, "attachPhotoButton").tap()
        waitEnabled(element(app, "sendButton"))
        element(app, "sendButton").tap()

        waitFor(element(app, "matchesMessage"), timeout: 30)
        XCTAssertFalse(element(app, "streamingText").exists, "nothing is generated for a photo alone")
        let match = element(app, "imageMatch-1")
        waitFor(match)
        XCTAssertTrue(match.label.contains("X200 Service Manual") && match.label.contains("page 2"), match.label)
        waitFor(element(app, "citation-1"))

        match.tap()
        waitFor(element(app, "sourcePage"))
        XCTAssertEqual(element(app, "sourceTitle").label, "X200 Service Manual")
        XCTAssertEqual(element(app, "sourcePage").label, "Page 2 of 3")
    }

    func testAnAnswerShowsThePhotosOnTheCitedPage() {
        let app = readyApp()
        ask(app, "How often should I descale the X200-B?")
        let answer = element(app, "assistantMessage")
        waitFor(answer, timeout: 15)
        let source = element(app, "citation-1")
        waitFor(source)
        XCTAssertTrue(source.label.contains("X200 Service Manual"), source.label)
        waitFor(element(app, "citedPhotos"))
        let photo = element(app, "citedPhoto-1")
        waitFor(photo)

        photo.tap()   // opens the page the photo is on
        waitFor(element(app, "sourcePage"))
        XCTAssertEqual(element(app, "sourcePage").label, "Page 2 of 3")
    }

    func testAPhotoAndAQuestionTogetherAreAnsweredWithCitations() {
        let app = readyApp()
        element(app, "attachPhotoButton").tap()
        ask(app, "How often should I descale it?")
        waitFor(element(app, "userPhoto"), timeout: 15)
        waitFor(element(app, "assistantMessage"), timeout: 30)
        XCTAssertFalse(element(app, "matchesMessage").exists)
        waitFor(element(app, "citation-1"))
    }

    func testCitingAPdfOpensTheCitedPageWithTheHighlightedPassage() {
        let app = readyApp()
        ask(app, "How often should I replace the HEPA filter?")
        let source = element(app, "citation-1")
        waitFor(source, timeout: 15)
        XCTAssertTrue(source.label.contains("Filter Guide"), source.label)
        let sourceLabel = source.label
        source.tap()

        waitFor(element(app, "sourcePage"))
        XCTAssertEqual(element(app, "sourceTitle").label, "Filter Guide")
        // The viewer must open the very page the citation names ("Source 1: Filter Guide, page N").
        let cited = sourceLabel.components(separatedBy: "page ").last?.prefix(while: \.isNumber) ?? ""
        XCTAssertFalse(cited.isEmpty, sourceLabel)
        XCTAssertEqual(element(app, "sourcePage").label, "Page \(cited) of 3")
        waitFor(element(app, "passageHighlighted"))
    }

    func testCitationToADeletedDocumentShowsTheStoredPassage() {
        let app = readyApp()
        ask(app, "How do I reset the X200?")
        waitFor(element(app, "citation-1"), timeout: 15)
        let title = element(app, "citation-1").label

        // Delete the cited document from the library.
        let cited = title.contains("Warranty") ? "Warranty" : "X200 Manual"
        app.buttons["doc-\(cited)"].press(forDuration: 1)
        app.buttons["Delete"].tap()
        app.buttons["Delete"].firstMatch.tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.buttons["doc-\(cited)"])], timeout: 10), .completed)

        element(app, "citation-1").tap()
        waitFor(element(app, "documentDeleted"))
        waitFor(element(app, "highlightedPassage"))
    }

    func testCitationsStillOpenInPortrait() {
        let app = readyApp()
        XCUIDevice.shared.orientation = .portrait
        ask(app, "How do I reset the X200?")
        let citation = element(app, "citation-1")
        waitFor(citation, timeout: 15)
        citation.tap()
        waitFor(element(app, "highlightedPassage"))   // the source column is reachable in the collapsed layout
    }

    func testOffTopicQuestionIsRefusedWithSuggestions() {
        let app = readyApp()
        ask(app, "Tell me about quantum computing")
        waitFor(element(app, "notFoundMessage"), timeout: 15)
        XCTAssertTrue(element(app, "notFoundMessage").label.contains("couldn't find"))
        XCTAssertTrue(element(app, "citation-1").exists, "closest passages should be offered")
    }

    func testStoppingKeepsThePartialAnswerMarkedStopped() {
        let app = readyApp(["-uiTestSlow"])
        ask(app, "How do I reset the X200?")
        waitFor(element(app, "stopButton"), timeout: 15)
        waitFor(element(app, "streamingText"), timeout: 15)
        element(app, "stopButton").tap()
        waitFor(element(app, "stoppedLabel"), timeout: 15)
        XCTAssertTrue(element(app, "assistantMessage").exists)
        XCTAssertTrue(element(app, "sendButton").exists, "input should be usable again")
    }

    func testNarrowingTheScopeExcludesOtherDocuments() {
        let app = readyApp()
        element(app, "pinMenu").tap()
        app.buttons["Warranty"].tap()
        waitFor(element(app, "scope-Warranty"))

        ask(app, "How do I reset the X200?")   // the answer is in the manual, which is out of scope
        let source = element(app, "citation-1")
        waitFor(source, timeout: 15)

        // Whatever comes back (an answer or suggestions) may only draw on the pinned document.
        XCTAssertTrue(source.label.contains("Warranty"), source.label)
        XCTAssertFalse(source.label.contains("X200 Manual"))
        let answer = element(app, "assistantMessage")
        if answer.exists { XCTAssertFalse(answer.label.contains("power button"), "text from the unpinned manual leaked: \(answer.label)") }
    }

    func testRenamingADocument() {
        let app = readyApp()
        app.buttons["doc-Warranty"].press(forDuration: 1)
        app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        waitFor(field)
        field.clearAndType("Guarantee")
        app.alerts.buttons["Rename"].tap()
        waitFor(app.buttons["doc-Guarantee"])
        XCTAssertFalse(app.buttons["doc-Warranty"].exists)
    }

    func testDeletingADocument() {
        let app = readyApp()
        app.buttons["doc-Warranty"].press(forDuration: 1)
        app.buttons["Delete"].tap()
        app.buttons["Delete"].firstMatch.tap()  // confirmation
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.buttons["doc-Warranty"])], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["doc-X200 Manual"].exists)
    }

    func testNewChatAndChatList() {
        let app = readyApp()
        ask(app, "How do I reset the X200?")
        waitFor(element(app, "assistantMessage"), timeout: 15)
        element(app, "newChatButton").tap()
        XCTAssertFalse(element(app, "assistantMessage").exists, "a new chat starts empty")
        element(app, "chatsButton").tap()
        waitFor(app.navigationBars["Chats"])
        waitFor(app.staticTexts["How do I reset the X200?"])  // the first chat is titled after its first question
    }
}

extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
