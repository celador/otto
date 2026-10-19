import GhosttyTerminal
import SwiftUI

/// Terminal pane: a tab strip over Ghostty surfaces (one per tab, all kept alive so switching tabs
/// keeps each shell's screen and scrollback). Used docked under the chat (Mac, iPad) and full screen
/// (iPhone).
struct TerminalPane: View {
    @Bindable var tabs: TerminalTabs
    /// New tabs start here (the open workspace's folder; nil = home).
    var cwd: String?
    var onHide: (() -> Void)?
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            ZStack {
                Color.black.opacity(0.92)
                ForEach(tabs.tabs) { tab in
                    TerminalTabSurface(tab: tab, isSelected: tab.id == tabs.selected?.id)
                }
                if tabs.tabs.isEmpty { emptyState }
            }
        }
        .task {
            if let e = app.terminalEndpoint {
                await TerminalEngine.shared.refreshConfig(e)
                if tabs.tabs.isEmpty { tabs.newTab(endpoint: e, cwd: cwd) }
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs.tabs) { tab in
                        TerminalTabButton(tab: tab, isSelected: tab.id == tabs.selected?.id,
                                          select: { tabs.selectedID = tab.id; tab.state.requestFocus() },
                                          close: { tabs.close(tab.id) })
                    }
                }
            }
            Button(action: newTab) { Image(systemName: "plus").frame(width: 24, height: 22) }
                .buttonStyle(.borderless)
                .help("New terminal tab (⌘T)")
            Spacer(minLength: 0)
            if let onHide {
                Button(action: onHide) { Image(systemName: "chevron.down").frame(width: 24, height: 22) }
                    .buttonStyle(.borderless)
                    .help("Hide terminal (⌃`)")
                    .padding(.trailing, 6)
            }
        }
        .font(.system(size: 12))
        .frame(height: 30)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if app.terminalEndpoint == nil {
                Text("Connect Otto to your agent server to open a terminal.")
                    .foregroundStyle(.secondary)
            } else {
                Button("New Terminal", action: newTab)
            }
        }
    }

    func newTab() {
        guard let e = app.terminalEndpoint else { return }
        tabs.newTab(endpoint: e, cwd: cwd)
    }
}

private struct TerminalTabButton: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if tab.status == .reconnecting || tab.status == .connecting {
                ProgressView().controlSize(.mini)
            } else if tab.isEnded {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            Text(tab.title).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: 180)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Close tab (⌘W)")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

private struct TerminalTabSurface: View {
    @ObservedObject var tab: TerminalTab
    let isSelected: Bool

    var body: some View {
        TerminalSurfaceView(context: tab.state)
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
            .overlay(alignment: .top) { statusBanner }
            .onChange(of: isSelected) { _, now in
                if now { DispatchQueue.main.async { tab.state.requestFocus() } }
            }
            .onAppear {
                if isSelected { DispatchQueue.main.async { tab.state.requestFocus() } }
            }
            .onChange(of: tab.state.surfaceSize) { _, _ in tab.startIfNeeded() }
    }

    @ViewBuilder private var statusBanner: some View {
        if isSelected {
            switch tab.status {
            case .reconnecting:
                banner("Reconnecting…")
            case .ended(let why):
                banner(why)
            default:
                EmptyView()
            }
        }
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
    }
}
