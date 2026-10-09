import XCTest

/// Two simulators sharing one library through the real replicator and the Docker Compose stack in `sync/`. Run the same test
/// on two simulators at once; the one named "Air" signs in as `ipad2`, the other as `ipad1`. Each seeds the five sample
/// documents, so when sync works each library ends up with ten, all ready, five of them received from the other simulator.
///
///     (cd sync && docker compose up -d --wait)
///     TEST_RUNNER_SYNC_E2E=1 xcodebuild test -project ManualBot.xcodeproj -scheme ManualBot \
///       -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' \
///       -only-testing:ManualBotUITests/SyncEndToEndUITests
///
/// `SYNC_E2E_HOLD` (seconds) keeps the app on screen at the end, to take screenshots.
final class SyncEndToEndUITests: UITestCase {
    func testTwoSimulatorsEndUpWithTheSameLibrary() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SYNC_E2E"] != nil, "needs the stack in sync/ and SYNC_E2E=1")
        let device = environment["SIMULATOR_DEVICE_NAME"] ?? ""
        let user = device.contains("Air") ? "ipad2" : "ipad1"

        let app = launch(extra: ["-uiTestSeed", "-uiTestSync", "live", "-uiTestSyncUser", user])
        app.buttons["startDownload"].tap()
        waitFor(app.navigationBars["Library"], timeout: 60)

        let documents = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'doc-'"))
        let ready = app.descendants(matching: .any).matching(identifier: "status-ready")
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline, !(documents.count == 10 && ready.count == 10) { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(documents.count, 10, "\(user): five of its own documents and five received")
        XCTAssertEqual(ready.count, 10, "\(user): every document is searchable")

        let cloud = element(app, "syncIndicator")
        XCTAssertTrue(cloud.exists)
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Sync: Up to date'"), object: cloud)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 30), .completed, "\(user): the cloud says “\(cloud.label)”")

        if let hold = environment["SYNC_E2E_HOLD"].flatMap(TimeInterval.init) { Thread.sleep(forTimeInterval: hold) }
    }
}
