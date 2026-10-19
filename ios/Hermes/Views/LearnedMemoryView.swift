import SwiftUI

// What Honcho (local, on the Mac) has learned from conversations — the "Learned" section of Memory.

struct HonchoState: Decodable, Sendable {
    let enabled: Bool
    let peers: [String]
    let peer: String?
    let card: [String]
    var conclusions: [Fact]

    struct Fact: Decodable, Sendable, Identifiable, Hashable {
        let ids: [String]
        let content: String
        let level: String?
        let createdAt: String?
        var id: String { ids.first ?? content }

        var date: Date? {
            guard let createdAt else { return nil }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: createdAt) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: createdAt)
        }

        /// Honcho levels: explicit (you said it) vs deductive/inductive (it worked it out).
        var inferred: Bool { (level ?? "explicit") != "explicit" }
    }

    /// "sam's sister is Alex" → "Sam's sister is Alex".
    static func display(_ text: String, peer: String?) -> String {
        var out = text
        if let peer, !peer.isEmpty, let first = peer.first, first.isLowercase {
            let name = first.uppercased() + peer.dropFirst()
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: peer) + "\\b"
            out = out.replacingOccurrences(of: pattern, with: name, options: .regularExpression)
        }
        if let first = out.first, first.isLowercase { out = first.uppercased() + out.dropFirst() }
        return out
    }
}

extension CompanionClient {
    func honcho(peer: String?) async throws -> HonchoState {
        let data = try await rawRequest("GET", "/hermes/honcho", query: peer.map { ["peer": $0] } ?? [:])
        return try HermesClient.decoder.decode(HonchoState.self, from: data)
    }

    func forgetHoncho(ids: [String]) async throws {
        _ = try await rawRequest("POST", "/hermes/honcho/forget",
                                 body: try JSONSerialization.data(withJSONObject: ["ids": ids]))
    }
}

/// Rows for the Learned section; lives inside MemoryView's List.
struct LearnedMemorySection: View {
    @Environment(AppModel.self) private var app
    let search: String
    @State private var state: HonchoState?
    @State private var peer: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let errorMessage { ErrorBanner(message: errorMessage) }
            if let state {
                if !state.enabled {
                    Section {
                        ContentUnavailableView("Not turned on", systemImage: "brain",
                                               description: Text("Honcho isn't set up on your Mac, so your agent only remembers what's in Notes and About you."))
                    }
                } else {
                    content(state)
                }
            } else if errorMessage == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .task(id: peer) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func content(_ s: HonchoState) -> some View {
        let facts = filtered(s)
        if s.peers.count > 1 {
            Picker("About", selection: Binding(get: { s.peer ?? "" }, set: { peer = $0 })) {
                ForEach(s.peers, id: \.self) { p in Text(HonchoState.display(p, peer: p)).tag(p) }
            }
        }
        if !s.card.isEmpty && search.isEmpty {
            Section("Profile") {
                ForEach(s.card, id: \.self) { Text(HonchoState.display($0, peer: s.peer)).font(.callout) }
            }
        }
        Section {
            if facts.isEmpty {
                Text(search.isEmpty ? "Nothing learned yet. Honcho picks things up as you chat; it can take a little while to show." : "No matches.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(HonchoState.display(fact.content, peer: s.peer)).font(.callout)
                    HStack(spacing: 6) {
                        if fact.inferred { Text("Inferred") }
                        if fact.inferred, fact.date != nil { Text("·") }
                        if let d = fact.date { Text(d.formatted(.relative(presentation: .named))) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { Task { await forget(fact) } } label: { Label("Forget", systemImage: "trash") }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = HonchoState.display(fact.content, peer: s.peer) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) { Task { await forget(fact) } } label: { Label("Forget", systemImage: "trash") }
                }
            }
        } header: {
            Text(s.conclusions.count == 1 ? "1 thing learned" : "\(s.conclusions.count) things learned")
                .font(.caption.weight(.semibold)).textCase(nil)
        } footer: {
            Text("Your agent learns these from your conversations using Honcho, which runs on your Mac. Nothing leaves it. Swipe to forget.")
        }
    }

    private func filtered(_ s: HonchoState) -> [HonchoState.Fact] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return s.conclusions }
        return s.conclusions.filter { $0.content.localizedCaseInsensitiveContains(q) }
    }

    private func load() async {
        guard let c = app.companionClient else { return }
        do {
            state = try await c.honcho(peer: peer)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func forget(_ fact: HonchoState.Fact) async {
        guard let c = app.companionClient else { return }
        do {
            try await c.forgetHoncho(ids: fact.ids)
            withAnimation { state?.conclusions.removeAll { $0.id == fact.id } }
            Haptics.tap()
        } catch { errorMessage = error.localizedDescription }
    }
}
