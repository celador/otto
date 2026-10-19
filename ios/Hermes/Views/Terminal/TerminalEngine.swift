import Combine
import Foundation
import GhosttyTerminal
import GhosttyTheme
import SwiftUI

/// Otto's Terminal: Ghostty's engine (libghostty via libghostty-spm, Metal renderer, host-managed I/O)
/// drawing a shell that runs on the Hermes host, reached through the relay's `/hermes/terminal`.
@MainActor
final class TerminalEngine {
    static let shared = TerminalEngine()

    private static let configKey = "terminal.ghosttyConfig"
    private(set) var controller: TerminalController
    private var loadedText: String?

    private init() {
        let cached = UserDefaults.standard.string(forKey: Self.configKey) ?? ""
        controller = Self.makeController(cached)
        loadedText = cached
    }

    static func makeController(_ text: String) -> TerminalController {
        let r = GhosttyConfigImport.parse(text)
        let config = TerminalConfiguration(startingFrom: .default) { b in
            #if os(iOS)
            // Ghostty's Mac font size reads tiny on a phone; keep John's size on iPad and the Mac.
            if UIDevice.current.userInterfaceIdiom == .phone { b.withFontSize(12) }
            #endif
            for e in r.entries {
                #if os(iOS)
                if e.key == "font-size", UIDevice.current.userInterfaceIdiom == .phone { continue }
                #endif
                b.withCustom(e.key, e.value)
            }
        }
        let light = r.lightTheme.flatMap { GhosttyThemeCatalog.theme(named: $0) }?.toTerminalConfiguration()
        let dark = r.darkTheme.flatMap { GhosttyThemeCatalog.theme(named: $0) }?.toTerminalConfiguration()
        let theme = (light == nil && dark == nil) ? TerminalTheme.default
            : TerminalTheme(light: light ?? dark ?? .init(), dark: dark ?? light ?? .init())
        return TerminalController(configSource: .generated(config.rendered), theme: theme)
    }

    /// Fetches the host's Ghostty config; a changed config applies to tabs opened afterwards.
    func refreshConfig(_ endpoint: RelayTerminalConnection.Endpoint) async {
        var url = endpoint.relay
        url.append(path: "/hermes/terminal/config")
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String, text != loadedText else { return }
        UserDefaults.standard.set(text, forKey: Self.configKey)
        loadedText = text
        controller = Self.makeController(text)
    }
}

/// One terminal tab: a Ghostty surface + the relay connection that feeds it.
@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    let cwd: String?
    let state: TerminalViewState
    @Published private(set) var status: RelayTerminalConnection.State = .connecting
    @Published private(set) var title: String
    private let connection: RelayTerminalConnection
    private let session: InMemoryTerminalSession
    private var started = false
    private var titleWatch: Any?

    init(endpoint: RelayTerminalConnection.Endpoint, cwd: String?, controller: TerminalController) {
        self.cwd = cwd
        title = cwd.map { ($0 as NSString).lastPathComponent } ?? "~"
        let conn = RelayTerminalConnection(endpoint: endpoint, cwd: cwd)
        connection = conn
        session = InMemoryTerminalSession(
            write: { data in conn.send(data) },
            resize: { viewport in conn.resize(cols: Int(viewport.columns), rows: Int(viewport.rows)) },
            suppressesPixelOnlyResizes: true
        )
        state = TerminalViewState(controller: controller)
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), resizeThrottleMilliseconds: 40)
        let session = self.session
        conn.onOutput = { data in session.receive(data) }
        conn.onExit = { code in session.finish(exitCode: UInt32(truncatingIfNeeded: max(code, 0)), runtimeMilliseconds: 0) }
        conn.onState = { [weak self] s in Task { @MainActor in self?.status = s } }
        titleWatch = state.$title.sink { [weak self] t in
            let t = t.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { self?.title = t }
        }
        // The first viewport report carries the real size; start then (or soon anyway).
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.startIfNeeded()
        }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        let size = state.surfaceSize
        connection.start(cols: size.map { Int($0.columns) } ?? 100, rows: size.map { Int($0.rows) } ?? 30)
    }

    /// "Run in terminal": types the command at the prompt without pressing Return.
    func paste(_ text: String) {
        _ = state.paste(text: text)
        state.requestFocus()
    }

    /// Raw bytes straight to the shell (DEBUG screenshot runs; a typed newline runs the line).
    func typeRaw(_ text: String) { session.sendInput(Data(text.utf8)) }

    func close() { connection.close() }

    var isEnded: Bool { if case .ended = status { true } else { false } }
}

/// The tabs in one window's Terminal pane.
@MainActor
@Observable
final class TerminalTabs {
    private(set) var tabs: [TerminalTab] = []
    var selectedID: UUID?
    var selected: TerminalTab? { tabs.first { $0.id == selectedID } ?? tabs.last }

    @discardableResult
    func newTab(endpoint: RelayTerminalConnection.Endpoint, cwd: String?) -> TerminalTab {
        let tab = TerminalTab(endpoint: endpoint, cwd: cwd, controller: TerminalEngine.shared.controller)
        tabs.append(tab)
        selectedID = tab.id
        return tab
    }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[i].close()
        tabs.remove(at: i)
        if selectedID == id { selectedID = tabs.indices.contains(i) ? tabs[i].id : tabs.last?.id }
    }

    func closeAll() {
        tabs.forEach { $0.close() }
        tabs.removeAll()
        selectedID = nil
    }
}

extension AppModel {
    /// Where the Terminal pane connects: the relay (same host/key as the board).
    var terminalEndpoint: RelayTerminalConnection.Endpoint? {
        guard let relay = kanbanClient?.baseURL, let key = client?.config.apiKey else { return nil }
        return .init(relay: relay, apiKey: key)
    }
}
