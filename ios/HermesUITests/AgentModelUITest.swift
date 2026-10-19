import XCTest

final class AgentModelUITest: XCTestCase {
    func testOpenAgentModelPicker() throws {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        app.launchArguments = ["-hermes.url", env["HERMES_URL"] ?? "", "-hermes.key", env["HERMES_KEY"] ?? "", "-hermes.tab", "agents"]
        app.launch()
        let arq = app.staticTexts["Arq"].firstMatch
        XCTAssertTrue(arq.waitForExistence(timeout: 20), "arq agent not listed")
        arq.tap()
        let model = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Model'")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        shot(app, "agent-detail")
        model.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["Arq's model"].waitForExistence(timeout: 10) || app.staticTexts["Arq's model"].exists)
        sleep(4)
        shot(app, "agent-picker")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: hostScratch + "/\(name).png"))
    }
}
