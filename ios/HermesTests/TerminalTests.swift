import Foundation
import Testing
@testable import Hermes

/// Terminal pane: the host's Ghostty config is imported safely, and the relay URL is built right.
struct TerminalConfigImportTests {
    static let sample = """
    theme = Monokai Classic
    font-family = Fira Code
    font-size = 14
    background-opacity = 0.85

    macos-titlebar-style = hidden
    macos-option-as-alt = true
    # fullscreen = non-native-padded-notch

    window-padding-x = 10
    window-padding-y = 8

    copy-on-select = false
    confirm-close-surface = false

    # SSH compatibility for remote hosts without ghostty terminfo
    term = xterm-256color
    """

    @Test func importsLookAndDropsAppOnlyKeys() {
        let r = GhosttyConfigImport.parse(Self.sample)
        let keys = r.entries.map(\.key)
        #expect(r.lightTheme == "Monokai Classic" && r.darkTheme == "Monokai Classic")
        for k in ["font-family", "font-size", "background-opacity", "window-padding-x", "window-padding-y",
                  "copy-on-select", "macos-option-as-alt"] {
            #expect(keys.contains(k), "\(k) kept")
        }
        for k in ["macos-titlebar-style", "term", "confirm-close-surface", "theme", "fullscreen"] {
            #expect(!keys.contains(k), "\(k) dropped")
        }
        #expect(r.entries.first { $0.key == "font-family" }?.value == "Fira Code")
        #expect(GhosttyConfigImport.fontSize(r) == 14)
    }

    @Test func unbindsGhosttyAppShortcutsSoOttoGetsThem() {
        let binds = GhosttyConfigImport.parse("").entries.filter { $0.key == "keybind" }.map(\.value)
        #expect(binds.contains("super+t=unbind"))
        #expect(binds.contains("super+w=unbind"))
        #expect(binds.contains("ctrl+grave_accent=unbind"))
        // Clear, copy/paste and font size stay Ghostty's own.
        #expect(!binds.contains { $0.hasPrefix("super+k=") || $0.hasPrefix("super+c=") || $0.hasPrefix("super+v=") })
    }

    @Test func lightDarkThemesAndQuotedValues() {
        let r = GhosttyConfigImport.parse("theme = light:Builtin Light,dark:Dracula\nfont-family = \"JetBrains Mono\"\nkeybind = ctrl+a=select_all")
        #expect(r.lightTheme == "Builtin Light")
        #expect(r.darkTheme == "Dracula")
        #expect(r.entries.first { $0.key == "font-family" }?.value == "JetBrains Mono")
        #expect(r.entries.contains { $0.key == "keybind" && $0.value == "ctrl+a=select_all" })
    }

    @Test func relayURL() throws {
        let tailnet = try #require(RelayTerminalConnection.url(relay: URL(string: "https://nano.example.ts.net:8651")!,
                                                               cwd: "/Users/sam/code/my app", cols: 120, rows: 40, session: nil))
        #expect(tailnet.scheme == "wss")
        #expect(tailnet.path == "/hermes/terminal")
        let q = URLComponents(url: tailnet, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.first { $0.name == "cwd" }?.value == "/Users/sam/code/my app")
        #expect(q.first { $0.name == "cols" }?.value == "120")
        let local = try #require(RelayTerminalConnection.url(relay: URL(string: "http://127.0.0.1:8650")!,
                                                             cwd: nil, cols: 80, rows: 24, session: "abc"))
        #expect(local.absoluteString == "ws://127.0.0.1:8650/hermes/terminal?cols=80&rows=24&session=abc")
    }
}
