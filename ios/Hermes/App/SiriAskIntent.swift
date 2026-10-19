import AppIntents
import Foundation

/// "Hey Siri, ask Hermes …": Hermes answers and Siri speaks it, without opening the app.
/// The chat is saved like any other, so the full answer (and anything still running) is in the app.
struct AskHermesForAnswerIntent: AppIntent {
    static var title: LocalizedStringResource { "Get an Answer from Otto" }
    static var description: IntentDescription {
        IntentDescription("Asks your agent a question and speaks the answer, without opening the app.")
    }
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you want to ask Otto?"))
    var question: String

    static var parameterSummary: some ParameterSummary { Summary("Ask Otto \(\.$question)") }

    static let instructions = """
    This question was asked out loud through Siri; your reply will be spoken by Siri. Answer in one to \
    three short conversational sentences, no markdown, no lists, no URLs. Use your tools as usual if the \
    question needs them. Do not claim an action succeeded before it actually did.
    """

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // The app's own saved connection, else what it last shared with the widgets.
        let lite: HermesLite
        if let c = KeychainStore.load(),
           let relay = KanbanClient.relayURL(forGateway: c.baseURL,
                                             override: UserDefaults.standard.string(forKey: "kanban.relayURL") ?? "") {
            lite = HermesLite(gateway: c.baseURL, relay: relay, apiKey: c.apiKey, timeout: 20)
        } else if let relay = SharedVault.relay(), let gateway = SharedVault.gateway() {
            lite = HermesLite(gateway: gateway, relay: relay.relay, apiKey: relay.apiKey, timeout: 20)
        } else {
            return .result(value: "", dialog: "Open Otto once and connect it to your agent server first.")
        }
        let turn: HermesLite.Turn
        do {
            let words = question.split(separator: " ").prefix(8).joined(separator: " ")
            let sid = try await lite.createSession(title: "Siri · " + (words.count > 50 ? String(words.prefix(50)) + "…" : words))
            turn = try await lite.ask(audio: nil, text: question, sessionID: sid, instructions: Self.instructions,
                                      context: { q in await HealthContext.contextIfRelevant(q) })
        } catch {
            return .result(value: "", dialog: "I couldn't reach your agent server. Is it running and reachable?")
        }
        // Siri waits about half a minute; past that, the answer lands in the app.
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(900))
            guard let st = try? await lite.status(runID: turn.runID), st.isDone else { continue }
            let out = WatchSnippet.plain(st.output ?? "")
            if st.status == "completed", !out.isEmpty, out != "[SILENT]" {
                return .result(value: out, dialog: IntentDialog(stringLiteral: Self.spoken(out)))
            }
            return .result(value: "", dialog: "Otto couldn't finish that one. It's in the app if you want to try again.")
        }
        return .result(value: "", dialog: "Otto is still working on it. The answer will be in the app.")
    }

    /// Siri reads everything it's given; keep it to a few sentences.
    static func spoken(_ text: String) -> String {
        guard text.count > 600 else { return text }
        let cut = text.prefix(600)
        if let end = cut.lastIndex(where: { ".!?".contains($0) }) { return String(cut[...end]) + " The rest is in the app." }
        return String(cut) + "… The rest is in the app."
    }
}
