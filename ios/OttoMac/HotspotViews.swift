import SwiftUI
import AppKit

// Settings → Hotspot (see Hotspot.swift): switch this Mac to the iPhone's Personal Hotspot when Wi-Fi
// stops working, and back when it returns. The helper that does it runs outside Otto (the App Store app
// can't change networks); this tab sets it up, edits its settings and shows what it's doing.

struct HotspotSettings: View {
    @Bindable var hotspot: HotspotController
    @State private var name = ""
    @State private var password = ""
    @State private var loadedName = false

    var body: some View {
        Form {
            if hotspot.status == nil {
                Section {
                    Text(hotspot.stateLine).foregroundStyle(.secondary)
                }
            } else if !hotspot.installed {
                setupSection
            } else {
                settingsSection
                statusSection
            }
        }
        .formStyle(.grouped)
        .task {
            // Poll while the tab is open (a test or a failover changes the status every few seconds).
            while !Task.isCancelled {
                await hotspot.poll()
                if !loadedName, let s = hotspot.status {
                    name = s.hotspotSsid
                    loadedName = true
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Sections

    private var setupSection: some View {
        Section {
            Text("When this Mac's Wi-Fi stops reaching the internet, Otto can switch it to your iPhone's Personal Hotspot so Hermes and your agents stay online, then switch back when the Wi-Fi works again.")
            Text("A small helper does the switching, because the Otto app itself isn't allowed to change networks. Setting it up takes about a minute and needs no password.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Set Up") { Task { await hotspot.setUp() } }
                    .disabled(hotspot.busy != nil)
                if hotspot.busy == "setup" {
                    ProgressView().controlSize(.small)
                    Text("Setting up…").foregroundStyle(.secondary)
                }
            }
            messageRow
        } header: {
            Text("iPhone hotspot")
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle("Switch to my iPhone hotspot when Wi-Fi stops working", isOn: Binding(
                get: { hotspot.status?.enabled == true },
                set: { on in Task { await hotspot.save(enabled: on, ssid: trimmedName) } }))
                .disabled(hotspot.busy != nil || trimmedName.isEmpty)
            TextField("Hotspot name", text: $name, prompt: Text("Your iPhone's name (Settings → General → About)"))
                .onSubmit { Task { await hotspot.save(ssid: trimmedName) } }
            SecureField("Password", text: $password,
                        prompt: Text(hotspot.status?.passwordSaved == true ? "Saved in your Keychain" : "Settings → Personal Hotspot on the iPhone"))
                .onSubmit(savePassword)
            HStack {
                Button("Save") {
                    if password.isEmpty { Task { await hotspot.save(ssid: trimmedName) } } else { savePassword() }
                }
                .disabled(hotspot.busy != nil || trimmedName.isEmpty || (password.isEmpty && trimmedName == hotspot.status?.hotspotSsid))
                Button("Test Now") { Task { await hotspot.test() } }
                    .disabled(hotspot.busy != nil || !hotspot.running || hotspot.status?.hotspotSsid.isEmpty != false)
                    .help("Joins the hotspot, checks the internet answers, and comes back to Wi-Fi.")
                if let busy = hotspot.busy, busy != "setup" {
                    ProgressView().controlSize(.small)
                    Text(busy == "test" ? "Testing… (up to a minute)" : "Saving…").foregroundStyle(.secondary)
                }
            }
            messageRow
        } header: {
            Text("iPhone hotspot")
        } footer: {
            Text("Otto waits about 25 seconds without internet before switching, so brief blips are ignored, and switches back once your Wi-Fi has been working for 2 minutes so phone data isn't used for longer than needed. It works with the lid closed and whether or not Keep Awake is on. On the iPhone, keep Personal Hotspot's \"Allow Others to Join\" on.")
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("Now") {
                Label(hotspot.stateLine, systemImage: hotspot.stateSymbol)
            }
            if let s = hotspot.status {
                if let f = s.lastFailover { LabeledContent("Last switch to hotspot", value: HotspotController.time(f.at)) }
                if let b = s.lastSwitchBack { LabeledContent("Last switch back", value: HotspotController.time(b.at)) }
                if let t = s.lastTest {
                    LabeledContent("Last test") {
                        Text((t.ok == true ? "Worked" : "Failed") + " · " + HotspotController.time(t.at))
                            .foregroundStyle(t.ok == true ? Color.secondary : Color.orange)
                    }
                }
                if let e = s.lastError, e.at > (s.lastFailover?.at ?? 0), e.at > (s.lastTest?.at ?? 0) - 120 {
                    LabeledContent("Last problem") {
                        Text(e.detail ?? "Unknown").foregroundStyle(.orange).multilineTextAlignment(.trailing)
                    }
                }
                if hotspot.running, s.passwordSaved == false, !s.hotspotSsid.isEmpty {
                    Label("No password saved. Otto can still join if this Mac already knows the hotspot.", systemImage: "key")
                        .foregroundStyle(.secondary)
                }
                if hotspot.namesHidden {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("macOS hides Wi-Fi names from the helper until Location Services is on for \"Otto Network Helper\". Otto still switches, but it can only go back to your Wi-Fi by letting macOS pick its preferred network after 10 minutes.", systemImage: "location.slash")
                            .foregroundStyle(.secondary)
                        Button("Open Location Services Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Status")
        }
    }

    @ViewBuilder private var messageRow: some View {
        if let msg = hotspot.message {
            Label(msg, systemImage: hotspot.messageFailed ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(hotspot.messageFailed ? Color.orange : Color.secondary)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func savePassword() {
        let pw = password
        password = ""
        Task { await hotspot.save(ssid: trimmedName, password: pw) }
    }
}
