import XCTest

/// Photos → Share → Hermes → Start chat; Hermes should come to the front on the new chat.
final class SharePhotoUITest: XCTestCase {
    func testSharePhotoOpensHermes() throws {
        // Connect the app once so it writes the shared gateway/key the extension uses.
        let hermes = XCUIApplication(bundleIdentifier: "ai.elier.hermes")
        let env = ProcessInfo.processInfo.environment
        hermes.launchArguments = ["-hermes.url", env["HERMES_URL"] ?? "", "-hermes.key", env["HERMES_KEY"] ?? ""]
        hermes.launch()
        sleep(4)

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        sleep(4)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don’t Allow", "Don't Allow", "Not Now"] where springboard.buttons[label].exists { springboard.buttons[label].tap(); sleep(1) }
        for label in ["Continue", "Not Now"] where photos.buttons[label].exists { photos.buttons[label].tap(); sleep(1) }
        shot(photos, "p1-photos")
        let share0 = photos.buttons["PUOneUpBarButtonItemIdentifierShare"]
        if !share0.exists {
            // First thumbnail (top-left of the library grid).
            photos.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.23)).tap()
            sleep(3)
        }
        if !share0.exists { photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(2) }
        try? photos.debugDescription.write(toFile: hostScratch + "/share-photos-tree.txt", atomically: true, encoding: .utf8)
        let share = photos.buttons.matching(NSPredicate(format: "label == 'Share' OR identifier == 'PUOneUpBarButtonItemIdentifierShare'")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 8), "no Share button")
        share.tap()
        sleep(3)
        shot(photos, "p2-sheet")
        var target = photos.cells["Otto"].firstMatch
        if !target.waitForExistence(timeout: 4) { target = photos.buttons["Otto"].firstMatch }
        if !target.exists {
            photos.cells["More"].firstMatch.tap(); sleep(2)
            target = photos.cells.staticTexts["Otto"].firstMatch
        }
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Hermes not in share sheet")
        target.tap()
        sleep(4)
        shot(photos, "p3-extension")
        let start = photos.buttons["Start chat"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        let field = photos.textViews.firstMatch.exists ? photos.textViews.firstMatch : photos.textFields.firstMatch
        if field.exists { field.tap(); field.typeText("UI test: in one short sentence, what is in this photo? No tools.") }
        start.tap()
        sleep(12)
        shot(hermes, "p4-hermes")
        XCTAssertEqual(hermes.state, .runningForeground)
        sleep(20)
        shot(hermes, "p5-reply")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: hostScratch + "/share-\(name).png"))
    }
}
