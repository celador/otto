import SwiftUI

/// Recent chats from every device. Tap one to make it the conversation on the watch.
struct WatchChatsView: View {
    @Bindable var model: WatchModel
    let onOpen: () -> Void

    var body: some View {
        List {
            if model.chats.isEmpty {
                if model.chatsLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("No chats yet. Keep your iPhone nearby.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(model.chats) { chat in
                Button {
                    onOpen()
                    Task { await model.open(chat) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title).font(.footnote.weight(.semibold)).lineLimit(2)
                        if let t = chat.lastActive {
                            Text(Date(timeIntervalSince1970: t), style: .relative)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.loadChats() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.chatsLoading)
                    .accessibilityLabel("Refresh chats")
            }
        }
        .task { if model.chats.isEmpty { await model.loadChats() } }
    }
}
