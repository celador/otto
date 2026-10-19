import SwiftUI

/// First launch: show a code; an iPhone/iPad (Hermes → Settings → Connect Apple TV) approves it.
struct TVPairView: View {
    @Environment(TVModel.self) private var model
    @State private var host = (Bundle.main.object(forInfoDictionaryKey: "HermesDefaultHost") as? String) ?? ""
    @State private var code: String?
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 50) {
            Text("Otto").font(.system(size: 90, weight: .bold))
            if let code {
                VStack(spacing: 30) {
                    Text("On your iPhone or iPad, open Otto → Settings → Connect Apple TV and enter")
                        .font(.title3).multilineTextAlignment(.center)
                    Text(code.map(String.init).joined(separator: " "))
                        .font(.system(size: 140, weight: .semibold, design: .monospaced))
                        .accessibilityLabel("Code \(code)")
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("Waiting for your phone…").foregroundStyle(.secondary)
                    }
                    Button("Get a new code") { Task { await start() } }
                }
            } else {
                VStack(spacing: 30) {
                    Text("Your Mac's Tailscale name").font(.title3)
                    TextField("my-mac.tailnet.ts.net", text: $host)
                        .frame(width: 900)
                    Text("The Tailscale app must be installed and signed in on this Apple TV.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        Task { await start() }
                    } label: {
                        if busy { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).multilineTextAlignment(.center).frame(maxWidth: 1300)
            }
        }
        .padding(80)
        .onDisappear { pollTask?.cancel() }
        #if DEBUG
        .task { if UserDefaults.standard.bool(forKey: "tv.autoPair") { await start() } }
        #endif
    }

    private func start() async {
        guard let relay = TVPairingClient.relayURL(from: host) else {
            errorMessage = "That doesn't look like a Tailscale name."
            return
        }
        busy = true
        defer { busy = false }
        pollTask?.cancel()
        let client = TVPairingClient(relay: relay)
        do {
            let s = try await client.start()
            code = s.code
            errorMessage = nil
            #if DEBUG
            NSLog("HERMESTV pairing code %@", s.code)
            #endif
            pollTask = Task { await poll(client, id: s.id) }
        } catch {
            code = nil
            errorMessage = "Couldn't reach your agent server at \(relay.host() ?? host). Check that Tailscale is on, then try again. (\(error.localizedDescription))"
        }
    }

    private func poll(_ client: TVPairingClient, id: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard let p = try? await client.poll(id) else { continue }
            switch p.status {
            case "approved":
                if let g = p.gateway.flatMap(URL.init(string:)), let r = p.relay.flatMap(URL.init(string:)), let k = p.api_key {
                    model.connect(TVConfig(gateway: g, relay: r, apiKey: k))
                }
                return
            case "expired":
                code = nil
                errorMessage = "The code expired. Select Connect for a new one."
                return
            default:
                continue
            }
        }
    }
}
