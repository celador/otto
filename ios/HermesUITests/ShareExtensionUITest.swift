import XCTest

/// Drives Safari → Share → Hermes → Start chat, and checks Hermes ends up in front.
/// Run on demand: xcodebuild test -scheme HermesShareUITest -destination …
final class ShareExtensionUITest: XCTestCase {
    func testShareFromSafariOpensHermes() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launchArguments = ["-u", "https://example.com/"]
        safari.launch()
        safari.open(URL(string: "https://example.com/")!)
        sleep(6)
        attach(safari, "1-safari")

        // iOS 26 Safari: dismiss the one-time tip, then … → Share.
        let close = safari.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap(); sleep(1) }
        dump(safari, "tree-safari")
        let more = safari.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
                                                       ["More", "Page Menu", "More options"], ["MoreButton", "PageMenuButton"])).firstMatch
        if more.waitForExistence(timeout: 4) {
            more.tap()
            sleep(2)
            dump(safari, "tree-menu")
        }
        let share = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Share' OR identifier == 'ShareButton'")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5), "No Share button")
        share.tap()
        sleep(3)
        attach(safari, "2-sheet")
        dump(safari, "tree-sheet")

        var hermes = safari.cells["Otto"].firstMatch
        if !hermes.waitForExistence(timeout: 4) { hermes = safari.buttons["Otto"].firstMatch }
        if !hermes.exists {
            // Not in the favourites row yet: More → find it.
            safari.cells["More"].firstMatch.tap()
            sleep(2)
            attach(safari, "2b-more")
            hermes = safari.cells.staticTexts["Otto"].firstMatch
        }
        XCTAssertTrue(hermes.waitForExistence(timeout: 5), "Hermes not in the share sheet")
        hermes.tap()
        sleep(3)
        attach(safari, "3-extension")

        let start = safari.buttons["Start chat"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8), "Share extension UI didn't appear")
        start.tap()
        sleep(6)

        let app = XCUIApplication(bundleIdentifier: "ai.elier.hermes")
        attach(app, "4-hermes")
        XCTAssertEqual(app.state, .runningForeground, "Hermes didn't come to the front")
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        try? app.debugDescription.write(toFile: hostScratch + "/share-\(name).txt", atomically: true, encoding: .utf8)
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: hostScratch + "/share-\(name).png"))
    }
}
