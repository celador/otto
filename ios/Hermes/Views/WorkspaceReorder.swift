import SwiftUI
import UniformTypeIdentifiers

// Drag and drop in the sidebar (iPhone/iPad drawer and Mac sidebar):
// - workspaces reorder: rows move live while you drag; the order is saved on the relay (shared by
//   every device) a moment after the last move.
// - chats drop onto a workspace row to move them there (the row highlights while hovered).

extension View {
    /// `chatHover` (optional) is set to the workspace id while a chat is dragged over it.
    func workspaceReorderable(_ workspace: Workspace, dragging: Binding<String?>,
                              chatHover: Binding<String?> = .constant(nil)) -> some View {
        modifier(WorkspaceReorderable(workspace: workspace, dragging: dragging, chatHover: chatHover))
    }

    /// A chat row that can be dragged onto a workspace.
    func chatDraggable(_ sessionID: String, workspaceDrag: Binding<String?>) -> some View {
        onDrag {
            SidebarDrag.chats = [sessionID]
            workspaceDrag.wrappedValue = nil
            return NSItemProvider(object: ChatDragPayload.encode([sessionID]) as NSString)
        }
    }

    /// Dropping chats here moves them to `target` (nil = out of their workspace).
    func chatDropTarget(_ target: String?, hovering: Binding<Bool>) -> some View {
        onDrop(of: [.text], isTargeted: hovering) { providers in
            ChatDropLoader.load(providers) { ids in
                Task { @MainActor in await WorkspaceStore.shared.drop(ids, onto: target) }
            }
            return true
        }
    }
}

private struct WorkspaceReorderable: ViewModifier {
    let workspace: Workspace
    @Binding var dragging: String?
    @Binding var chatHover: String?

    func body(content: Content) -> some View {
        content
            .onDrag {
                dragging = workspace.id
                SidebarDrag.chats = []
                return NSItemProvider(object: workspace.id as NSString)
            }
            .onDrop(of: [.text], delegate: WorkspaceDropDelegate(target: workspace.id, dragging: $dragging, chatHover: $chatHover))
    }
}

/// Reads the dragged chat ids from the item (falls back to what this app started dragging).
enum ChatDropLoader {
    @MainActor static func load(_ providers: [NSItemProvider], _ done: @escaping @Sendable ([String]) -> Void) {
        let fallback = SidebarDrag.chats
        SidebarDrag.chats = []
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            if !fallback.isEmpty { done(fallback) }
            return
        }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            let ids = ChatDragPayload.decode(obj as? String)
            done(ids.isEmpty ? fallback : ids)
        }
    }
}

extension WorkspaceStore {
    /// Chats dropped on a workspace (or on "out of the workspace" when `target` is nil).
    func drop(_ ids: [String], onto target: String?) async {
        let moved = await ChatDrop.perform(ids, onto: target, owner: { self.workspace(forSession: $0)?.id }) { id, to in
            await self.move(id, to: to)
        }
        #if os(iOS)
        if !moved.isEmpty { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        #endif
        #if DEBUG
        NSLog("CHATDROP %@ -> %@ moved=%d", ids.joined(separator: ","), target ?? "none", moved.count)
        #endif
    }
}

private struct WorkspaceDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    @Binding var chatHover: String?

    @MainActor private var draggingChats: Bool { dragging == nil && !SidebarDrag.chats.isEmpty }

    @MainActor func dropEntered(info: DropInfo) {
        if draggingChats {
            chatHover = target
            return
        }
        guard let dragged = dragging, dragged != target else { return }
        let store = WorkspaceStore.shared
        var ids = store.active.map(\.id)
        guard let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.snappy) { store.reorder(ids) }
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    @MainActor func dropExited(info: DropInfo) {
        if chatHover == target { chatHover = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    @MainActor func validateDrop(info: DropInfo) -> Bool { dragging != nil || !SidebarDrag.chats.isEmpty }

    @MainActor func performDrop(info: DropInfo) -> Bool {
        if chatHover == target { chatHover = nil }
        if dragging != nil {
            dragging = nil
            return true
        }
        let target = self.target
        ChatDropLoader.load(info.itemProviders(for: [.text])) { ids in
            Task { @MainActor in await WorkspaceStore.shared.drop(ids, onto: target) }
        }
        return true
    }
}
