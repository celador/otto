import XCTest

/// Tapping a Live Activity cold-launches Hermes with hermes://open?session=…; it must not crash.
final class LiveActivityOpenUITest: XCTestCase {
    func testColdLaunchFromSessionLink() throws {
        let sid = ProcessInfo.processInfo.environment["HERMES_TEST_SESSION"] ?? "api_1791302371_e15cc235"
        let app = XCUIApplication(bundleIdentifier: "ai.elier.hermes")
        app.terminate()
        app.open(URL(string: "hermes://open?session=\(sid)")!)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        sleep(8)
        XCTAssertEqual(app.state, .runningForeground, "Hermes closed after opening from the Live Activity link")
        app.open(URL(string: "hermes://open?session=\(sid)")!)
        sleep(5)
        XCTAssertEqual(app.state, .runningForeground)
    }
}
