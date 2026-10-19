import SwiftUI
import UniformTypeIdentifiers

/// What the menu bar / keyboard shortcuts can do to the chat in the focused window.
struct ChatCommandActions: Equatable {
    let id: ObjectIdentifier
    var focusComposer: () -> Void
    var stop: () -> Void
    var showModels: () -> Void
    var showCommands: () -> Void
    var find: () -> Void
    var voice: () -> Void
    var isRunning: Bool
    var hasSession: Bool

    /// Closures don't compare; identity + the state the menus show do. Without this every
    /// render published a "new" value and re-ran the menu commands.
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.isRunning == b.isRunning && a.hasSession == b.hasSession
    }
}

extension FocusedValues {
    @Entry var chatCommands: ChatCommandActions? = nil
}

/// Mac-only chat chrome: model + slash buttons in the window toolbar, image file import,
/// Esc to stop, and the actions the Chat menu commands call.
struct MacChatChrome: ViewModifier {
    let model: ChatModel
    @Binding var showModelPicker: Bool
    @Binding var showCommands: Bool
    @Binding var commandsFilter: String
    @Binding var inputFocused: Bool
    @Binding var showVoice: Bool
    @Binding var showFileImporter: Bool
    @Binding var finding: Bool
    let onImages: ([Data]) -> Void
    @Environment(AppModel.self) private var app

    private var modelName: String {
        if let c = model.modelChoice { return c.shortName }
        if let o = app.modelOptions, let m = o.model, !m.isEmpty {
            return ModelChoice(provider: o.provider ?? "", model: m).shortName
        }
        return "Model"
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let jpegs = urls.prefix(4).compactMap { url -> Data? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return (try? Data(contentsOf: url)).flatMap(ImageEncoder.jpeg(from:))
                }
                onImages(jpegs)
            }
            .modifier(MacImageDrop(enabled: !model.isRunning, onImages: onImages))
            .onExitCommand { if model.isRunning { Task { await model.stop() } } }
            .background {
                // ⌘K also focuses the message field (⌘L is the menu item), like ChatGPT/Claude.
                Button("") { inputFocused = true }
                    .keyboardShortcut("k")
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .focusedSceneValue(\.chatCommands, ChatCommandActions(
                id: ObjectIdentifier(model),
                focusComposer: { inputFocused = true },
                stop: { Task { await model.stop() } },
                showModels: { showModelPicker = true },
                showCommands: { commandsFilter = ""; showCommands = true },
                find: { finding = true },
                voice: { showVoice = true },
                isRunning: model.isRunning,
                hasSession: model.sessionID != nil
            ))
    }
}
