import AppKit
import GhosttyTerminal
import SwiftUI

/// The Mac Terminal pane, docked under the chat: drag the top edge to resize (height remembered),
/// Ctrl+` (or View → Terminal) toggles it, Cmd+T / Cmd+W open and close tabs while a terminal has focus.
// TODO(t_0c4e15a3): when the workspace dashboard layout (chat | board + usage) lands, dock this under its
// chat column instead of the whole detail pane.
struct MacTerminalDock<Content: View>: View {
    @Binding var isOpen: Bool
    let tabs: TerminalTabs
    let cwd: String?
    @ViewBuilder var content: Content
    @AppStorage("mac.terminalHeight") private var height: Double = 280
    @State private var dragStart: Double?
    /// Once opened, the pane stays mounted (zero height when hidden) so hiding it keeps every tab's
    /// Ghostty surface, screen and scrollback; only closing a tab ends its shell.
    @State private var mounted = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                content.frame(maxHeight: .infinity)
                if isOpen { handle(total: geo.size.height) }
                if mounted || isOpen {
                    TerminalPane(tabs: tabs, cwd: cwd, onHide: { isOpen = false })
                        .frame(height: isOpen ? clamped(height, total: geo.size.height) : 0)
                        .clipped()
                        .allowsHitTesting(isOpen)
                        .accessibilityHidden(!isOpen)
                        .onAppear { mounted = true }
                }
            }
        }
        .onChange(of: isOpen) { _, open in
            for tab in tabs.tabs { tab.state.isSurfaceVisible = open }
        }
    }

    private func clamped(_ h: Double, total: CGFloat) -> CGFloat {
        CGFloat(min(max(h, 120), max(Double(total) - 180, 120)))
    }

    private func handle(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .overlay(Color.clear.frame(height: 7).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let start = dragStart ?? Double(clamped(height, total: total))
                        dragStart = start
                        height = Double(clamped(start - v.translation.height, total: total))
                    }
                    .onEnded { _ in dragStart = nil }))
    }
}

/// Window-scoped shortcuts for the pane. A local monitor (not menu items) because Cmd+W is the window's
/// own Close and Cmd+T macOS's tab shortcut; these only take over while a terminal has keyboard focus.
@MainActor
final class MacTerminalKeys {
    private var monitor: Any?
    weak var window: NSWindow?
    var toggle: () -> Void = {}
    var newTab: () -> Void = {}
    var closeTab: () -> Void = {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if mods == .control, event.keyCode == 50 {   // ` (grave accent)
                self.toggle()
                return nil
            }
            guard mods == .command, window.firstResponder is AppTerminalView else { return event }
            switch event.charactersIgnoringModifiers {
            case "t": self.newTab(); return nil
            case "w": self.closeTab(); return nil
            default: return event
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Hands the hosting NSWindow to a closure (for window-scoped key handling).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(v.window) }
    }
}
