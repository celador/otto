import Testing
import UIKit
@testable import Hermes

@MainActor
struct ComposerKeyTests {
    @Test func returnSendsShiftReturnAddsLine() {
        let tv = PastingTextView()
        var sent = 0
        tv.onSubmit = { sent += 1 }
        let cmds = tv.keyCommands ?? []
        #expect(cmds.contains { $0.input == "\r" && $0.modifierFlags.isEmpty && $0.action == #selector(PastingTextView.returnPressed) })
        #expect(cmds.contains { $0.input == "\r" && $0.modifierFlags == .shift && $0.action == #selector(PastingTextView.insertNewline) })
        tv.text = "hi"
        tv.returnPressed()
        #expect(sent == 1)
        tv.insertNewline()
        #expect(tv.text == "hi\n")
        #expect(sent == 1)
    }
}
