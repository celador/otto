import SwiftUI

/// Approves an Apple TV's pairing code (relay `POST /hermes/tvpair/approve`); the TV then
/// receives this device's gateway URL and key from the relay.
struct ConnectTVView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var busy = false
    @State private var done = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var digits: String { code.filter(\.isNumber) }

    var body: some View {
        Form {
            Section {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(.title, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onChange(of: code) { _, v in
                        let d = String(v.filter(\.isNumber).prefix(6))
                        if d != v { code = d }
                        if d.count == 6, !busy, !done { Task { await approve() } }
                    }
            } footer: {
                Text("On the Apple TV, open Otto. It shows a code; type it here. The Apple TV must have the Tailscale app signed in to your tailnet.")
            }
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            if done {
                Section { Label("Connected. Your Apple TV is ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            Section {
                Button {
                    Task { await approve() }
                } label: {
                    if busy { ProgressView() } else { Text("Connect") }
                }
                .disabled(digits.count != 6 || busy || done)
            }
        }
        .navigationTitle("Connect Apple TV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = true }
    }

    private func approve() async {
        guard let c = model.companionClient, let gateway = model.client?.config.baseURL else {
            errorMessage = "Connect this device to your agent server first."
            return
        }
        busy = true
        defer { busy = false }
        do {
            try await c.approveTV(code: digits, gateway: gateway, relay: c.baseURL)
            errorMessage = nil
            done = true
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension CompanionClient {
    func approveTV(code: String, gateway: URL, relay: URL) async throws {
        _ = try await rawRequest("POST", "/hermes/tvpair/approve", body: try JSONSerialization.data(withJSONObject: [
            "code": code, "gateway": gateway.absoluteString, "relay": relay.absoluteString,
        ]))
    }
}
