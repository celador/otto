import Foundation
import Testing
@testable import Hermes

/// iPad hang (build 93): building a ChatModel for an existing chat wrote its saved model/fast prefs
/// back to UserDefaults. Every write invalidates each `@AppStorage` view; the workspace dashboard then
/// re-ran its chat closure, which built another ChatModel, which wrote again — forever (watchdog kill).
@MainActor
struct ChatModelInitTests {
    @Test func openingASavedChatWritesNoDefaults() {
        let sid = "test_init_\(UUID().uuidString)"
        ModelPrefs.set(ModelChoice(provider: "anthropic", model: "claude-sonnet-5"), sessionID: sid)
        FastPrefs.set(true, sessionID: sid)
        defer { ModelPrefs.set(nil, sessionID: sid); FastPrefs.set(nil, sessionID: sid) }

        nonisolated(unsafe) var writes = 0
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                           object: nil, queue: nil) { _ in writes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let client = HermesClient(config: HermesConfig(baseURL: URL(string: "https://example.invalid")!, apiKey: "x"))
        for _ in 0..<3 {
            let m = ChatModel(client: client, sessionID: sid, loadCache: false)
            #expect(m.modelChoice?.model == "claude-sonnet-5")
            #expect(m.fastMode == true)
        }
        #expect(writes == 0)
    }

    @Test func realChangesStillPersist() {
        let sid = "test_init_\(UUID().uuidString)"
        defer { ModelPrefs.set(nil, sessionID: sid); FastPrefs.set(nil, sessionID: sid) }
        let client = HermesClient(config: HermesConfig(baseURL: URL(string: "https://example.invalid")!, apiKey: "x"))
        let m = ChatModel(client: client, sessionID: sid, loadCache: false)
        m.modelChoice = ModelChoice(provider: "anthropic", model: "claude-opus-5-5")
        m.fastMode = false
        #expect(ModelPrefs.get(sessionID: sid)?.model == "claude-opus-5-5")
        #expect(FastPrefs.get(sessionID: sid) == false)
        m.modelChoice = nil
        m.fastMode = nil
        #expect(ModelPrefs.get(sessionID: sid) == nil)
        #expect(FastPrefs.get(sessionID: sid) == nil)
    }
}
