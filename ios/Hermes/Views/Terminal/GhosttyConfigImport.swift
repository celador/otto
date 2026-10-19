import Foundation

/// Turns the host Mac's own Ghostty config (served by the relay at `/hermes/terminal/config`) into the
/// lines Otto's embedded Ghostty surface loads, so the pane looks and types like John's Ghostty.
///
/// Pure (no GhosttyKit) so it is unit-tested; `TerminalEngine` feeds the result to libghostty.
enum GhosttyConfigImport {
    struct Result: Equatable {
        /// `key = value` pairs, in file order, safe for an embedded surface.
        var entries: [(key: String, value: String)]
        /// `theme = …` resolved by the caller (the embedded build ships no theme files).
        var lightTheme: String?
        var darkTheme: String?

        static func == (a: Result, b: Result) -> Bool {
            a.entries.map { "\($0.key)=\($0.value)" } == b.entries.map { "\($0.key)=\($0.value)" }
                && a.lightTheme == b.lightTheme && a.darkTheme == b.darkTheme
        }
    }

    /// Keys that only make sense for the standalone Ghostty app/window, or that would start something
    /// (the shell lives on the Hermes host, not in Otto).
    static let droppedPrefixes = ["macos-", "gtk-", "linux-", "adw-", "x11-", "quick-terminal", "window-",
                                  "auto-update", "initial-", "resize-overlay", "fullscreen", "shell-integration",
                                  "custom-shader", "app-notifications", "undo-timeout", "bell-audio"]
    static let droppedKeys: Set<String> = ["term", "command", "initial-command", "working-directory",
                                           "config-file", "theme", "confirm-close-surface",
                                           "quit-after-last-window-closed", "quit-after-last-window-closed-delay",
                                           "class", "title", "env", "input", "wait-after-command",
                                           "abnormal-command-exit-runtime", "async-backend", "desktop-notifications",
                                           "background-blur", "background-blur-radius"]
    /// Window padding means the same thing for a pane; Option-as-Alt is how John types in Ghostty.
    static let keptWindowKeys: Set<String> = ["window-padding-x", "window-padding-y", "window-padding-balance",
                                              "window-padding-color", "macos-option-as-alt"]

    /// Ghostty shortcuts that would act on the (absent) Ghostty app; unbinding them lets Otto's own
    /// pane shortcuts (Cmd+T / Cmd+W tabs, Ctrl+` toggle) and window commands through.
    static let ottoKeybinds = ["super+t=unbind", "super+w=unbind", "super+shift+w=unbind", "super+n=unbind",
                               "super+shift+n=unbind", "super+d=unbind", "super+shift+d=unbind",
                               "super+alt+w=unbind", "super+q=unbind", "super+comma=unbind",
                               "ctrl+grave_accent=unbind"]

    static func parse(_ text: String) -> Result {
        var out = Result(entries: [], lightTheme: nil, darkTheme: nil)
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !key.isEmpty else { continue }
            if key == "theme" {
                (out.lightTheme, out.darkTheme) = themes(value)
                continue
            }
            if !keep(key) { continue }
            out.entries.append((key, value))
        }
        out.entries += ottoKeybinds.map { ("keybind", $0) }
        return out
    }

    static func keep(_ key: String) -> Bool {
        if keptWindowKeys.contains(key) { return true }
        if droppedKeys.contains(key) { return false }
        return !droppedPrefixes.contains { key.hasPrefix($0) }
    }

    /// `theme = X` or `theme = light:A,dark:B` → (light, dark).
    static func themes(_ value: String) -> (String?, String?) {
        guard value.contains(":") else { return value.isEmpty ? (nil, nil) : (value, value) }
        var light: String?, dark: String?
        for part in value.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "light" { light = kv[1] } else if kv[0] == "dark" { dark = kv[1] }
        }
        return (light ?? dark, dark ?? light)
    }

    /// `font-size` from the config (nil when unset), for the pane's own default.
    static func fontSize(_ r: Result) -> Float? {
        r.entries.last { $0.key == "font-size" }.flatMap { Float($0.value) }
    }
}
