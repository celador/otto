import SwiftUI

struct SettingsView: View {
    /// "0.1.0 (2)": the build number goes up with every install on the phone.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showDefaultModel = false
    @State private var defaultModel = ModelPrefs.defaultChoice
    @AppStorage(HealthContext.enabledKey) private var healthEnabled = false
    @State private var debugVoicePicker = false
    @State private var debugSpanishPicker = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section("Server") {
                    LabeledContent("Address", value: model.client?.config.baseURL.host() ?? "—")
                    if let v = model.serverVersion { LabeledContent("Server version", value: v) }
                    LabeledContent("This app", value: Self.appVersion)
                    LabeledContent("Status", value: model.isOffline ? "Unreachable" : "Connected")
                }
                Section {
                    Button {
                        showDefaultModel = true
                    } label: {
                        LabeledContent("Model for new chats", value: defaultModel?.shortName ?? "Server default")
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Each chat can override this from its ⋯ menu.")
                }
                VoiceModeSettingsSection()
                VoiceSettingsSection()
                    .id("voice")
                if HealthContext.available {
                    Section {
                        Toggle("Share health with your agent", isOn: Binding(get: { healthEnabled }, set: { on in
                            if on {
                                Task { healthEnabled = await HealthContext.requestAccess() }
                            } else {
                                healthEnabled = false
                            }
                        }))
                    } header: {
                        Text("Apple Health")
                    } footer: {
                        Text("When you ask about sleep, workouts, heart rate, steps or energy (here, by voice on your watch, or through Siri), your agent gets a short summary of your Apple Health data for that question. It goes only to your own agent server and the AI model it uses. Nothing is sent for other questions. Choose which data Otto can read in the Health app → Sharing → Apps.")
                    }
                }
                #if os(iOS)
                Section {
                    NavigationLink("Connect Apple TV") { ConnectTVView() }
                } footer: {
                    Text("Open Otto on your Apple TV and enter the code it shows. The TV gets this connection; you never type the token on the TV.")
                }
                #endif
                Section {
                    TextField("Board relay (default: port \(KanbanClient.defaultPort))",
                              text: Binding(get: { model.kanbanRelayOverride }, set: { model.kanbanRelayOverride = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote)
                } header: {
                    Text("Board")
                } footer: {
                    Text("Leave empty to use your server's host on port \(KanbanClient.defaultPort). Uses the same access token.")
                }
                Section {
                    Button("Disconnect", role: .destructive) {
                        model.disconnect()
                        dismiss()
                    }
                } footer: {
                    Text("Removes the server address, access token and cached chats from this phone.")
                }
                Section {
                    Link("Hermes Agent on GitHub", destination: URL(string: "https://github.com/NousResearch/hermes-agent")!)
                    Link("MIT License", destination: URL(string: "https://github.com/NousResearch/hermes-agent/blob/main/LICENSE")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("Works with Hermes Agent, open source under the MIT License, © 2025 Nous Research. Otto is an independent app, not made by or affiliated with Nous Research.")
                        .id("about")
                }
            }
            #if DEBUG
            .onAppear {
                // Screenshot runs: `-hermes.settings about` scrolls to the credits.
                switch UserDefaults.standard.string(forKey: "hermes.settings") {
                case "about":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { proxy.scrollTo("about", anchor: .top) }
                case "voice":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { proxy.scrollTo("voice", anchor: .top) }
                case "voicepicker":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { debugVoicePicker = true }
                case "spanishpicker":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { debugSpanishPicker = true }
                default: break
                }
            }
            #endif
            }
            .navigationDestination(isPresented: $debugVoicePicker) { VoicePickerView(kind: .main) }
            .navigationDestination(isPresented: $debugSpanishPicker) { VoicePickerView(kind: .spanish) }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            #if os(iOS)
            .toolbar { Button("Done") { dismiss() } }
            #endif
            .sheet(isPresented: $showDefaultModel) {
                ModelPickerView(selection: Binding(get: { defaultModel }, set: {
                    defaultModel = $0
                    ModelPrefs.defaultChoice = $0
                }))
            }
        }
    }
}
