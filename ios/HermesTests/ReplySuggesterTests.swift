import Testing
import UIKit
@testable import Hermes

struct ReplySuggesterTests {
    @Test(arguments: [
        ("Build 61 is ready. Would you like me to install it on your phone?", "Yes, install it on my phone"),
        ("Done. Want me to deploy it?", "Yes, deploy it"),
        ("Tests pass.\n\nShould I go ahead and push to main?", "Yes, push to main"),
        ("I found **3 leads**. Do you want me to draft emails to them?", "Yes, draft emails to them"),
        ("Should I ship now or wait for review?", "Ship now"),
        ("Shall we start with the sidebar?", "Yes, let's start with the sidebar"),
        ("Here's the plan. Does that look right?", "Looks good"),
        ("That's the new copy. Does this sound good?", "Sounds good"),
        ("All set. Anything else?", "No, that's all"),
        ("I can also add a widget. Want me to?", "Yes, go ahead"),
        ("Want me to send you the PR link (it's on GitHub)?", "Yes, send me the PR link"),
        ("Would you like me to update the PR description?", "Yes, update the PR description"),
        ("Ready for me to submit it?", "Yes, go ahead"),
        // Offers that aren't questions (real endings from John's chats).
        ("1.3 is still waiting for you to submit, or say \"submit it\" and I'll do it.", "Submit it"),
        ("If they're off, tell me and I'll adjust the instructions.  I'd do item 2 next.", "Yes, do item 2 next"),
        ("If you want, I can install it on the mini.", "Yes, install it on the mini"),
        ("I can also add a widget if you'd like.", "Yes, add a widget"),
        ("Let me know if you want me to open a PR.", "Yes, open a PR"),
    ])
    func suggests(_ text: String, _ expected: String) {
        #expect(ReplySuggester.suggest(after: text) == expected)
    }

    @Test(arguments: [
        "Done — build 61 is installed.",
        "What's the name of the repo?",
        "Should I? I'm not sure. Here's what I found.",
        "",
        "If you'd rather do Thursday or a longer call, I can move it.",
        "Tell me which of these, if any, you want changed.",
        "I'd also like to take you up on that chat this week. When works for you?",
    ])
    func noSuggestion(_ text: String) {
        #expect(ReplySuggester.suggest(after: text) == nil)
    }

    @MainActor @Test func acceptFillsEmptyFieldOnly() {
        let tv = PastingTextView()
        var accepted = 0
        tv.onAcceptSuggestion = { accepted += 1 }
        tv.suggestion = "Yes, deploy it"
        #expect(tv.keyCommands?.contains { $0.input == UIKeyCommand.inputRightArrow } == true)
        tv.acceptSuggestion()
        #expect(tv.text == "Yes, deploy it")
        #expect(accepted == 1)
        // Not empty any more: → moves the caret again, and accepting is a no-op.
        #expect(tv.keyCommands?.contains { $0.input == UIKeyCommand.inputRightArrow } == false)
        tv.acceptSuggestion()
        #expect(accepted == 1)
    }

    @MainActor @Test func spaceBarDragRightAccepts() {
        let tv = PastingTextView()
        tv.suggestion = "Yes, go ahead"
        tv.beginFloatingCursor(at: CGPoint(x: 100, y: 10))
        tv.updateFloatingCursor(at: CGPoint(x: 104, y: 10))
        #expect(tv.text.isEmpty)
        tv.updateFloatingCursor(at: CGPoint(x: 130, y: 10))
        tv.endFloatingCursor()
        #expect(tv.text == "Yes, go ahead")
    }
}
