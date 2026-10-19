import SwiftUI

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var key = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        OttoMark(size: 72)
                            .padding(.bottom, 4)
                        Text("Otto")
                            .font(.largeTitle.bold())
                        Text("Chat with your own AI agent from your phone. Connect to the agent server running on your computer.")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                Section {
                    TextField("https://my-mac.tailnet.ts.net:8642", text: $url)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Access token", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address and access token come from your own agent server's settings. Otto has no account and nothing to buy. The token is stored only in this phone's Keychain.")
                }

                Section {
                    Button {
                        pasteLink()
                    } label: {
                        Label("Paste connection link", systemImage: "doc.on.clipboard")
                    }
                } footer: {
                    Text("Or scan the connection QR code shown by your server with the Camera app.")
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting { ProgressView() } else { Text("Connect").bold() }
                            Spacer()
                        }
                    }
                    .disabled(url.trimmed.isEmpty || key.trimmed.isEmpty || isConnecting)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onOpenURL { link in
            // Scanning the QR from the Mac opens hermes://connect?url=…&key=…
            guard let parsed = AppModel.parseConnectionLink(link.absoluteString) else { return }
            url = parsed.url
            key = parsed.key
            Task { await connect() }
        }
    }

    private func pasteLink() {
        guard let text = UIPasteboard.general.string,
              let parsed = AppModel.parseConnectionLink(text) else {
            error = "The clipboard doesn't contain a hermes://connect link."
            return
        }
        url = parsed.url
        key = parsed.key
        error = nil
    }

    private func connect() async {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await model.connect(urlString: url, apiKey: key)
        } catch let urlError as URLError {
            error = switch urlError.code {
            case .cannotFindHost, .cannotConnectToHost, .timedOut, .notConnectedToInternet:
                "Can't reach the gateway. Check that Tailscale is on and the gateway is running."
            default: urlError.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
