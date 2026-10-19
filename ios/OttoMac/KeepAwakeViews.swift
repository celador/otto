import SwiftUI
import AppKit

// Keep Mac awake inside Otto (see KeepAwake.swift): the sidebar control in the main window, the
// View → Keep Mac Awake menu and Settings → Keep Awake. No menu bar (status) item.

private func shortTime(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }

private func remaining(_ end: Date, from now: Date = .now) -> String {
    let s = max(0, Int(end.timeIntervalSince(now)))
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d) d \(h) h" }
    if h > 0 { return "\(h) h \(m) min" }
    return "\(max(m, 1)) min"
}

extension KeepAwakeController {
    /// One line for the menu, the sidebar popover and Settings.
    var statusLine: String {
        switch mode {
        case .off:
            return "Off — this Mac sleeps normally"
        case .whileWorking:
            if agentsWorking == nil { return "Waiting for Hermes — can't see whether agents are working" }
            if agentsWorking == true {
                return workingCount > 1 ? "Awake — \(workingCount) agent runs working" : "Awake — an agent is working"
            }
            return "Will stay awake when an agent starts working"
        case .until(let end):
            return "Awake until \(shortTime(end)) (\(remaining(end)) left)"
        }
    }

    /// The Mac is being kept awake right now (by Otto's assertion or by lid-closed mode).
    var isAwakeNow: Bool { isHolding || lidClosedActive }

    var symbol: String {
        if lidClosedActive { return "cup.and.heat.waves.fill" }
        return isHolding ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    /// Short label for the sidebar control while the Mac is kept awake (the popover and tooltip say until when).
    var shortLabel: String { isAwakeNow ? "Awake" : "" }

    static let presets: [(TimeInterval, String)] = [
        (30 * 60, "30 Minutes"), (3600, "1 Hour"), (2 * 3600, "2 Hours"), (4 * 3600, "4 Hours"),
        (8 * 3600, "8 Hours"), (86400, "1 Day"),
    ]
}

enum MacSettingsTab: String {
    case general, connection, keepAwake
    static let key = "mac.settingsTab"
}

/// Opens Settings on the Keep Awake tab.
struct OpenKeepAwakeSettings {
    let openSettings: OpenSettingsAction
    func callAsFunction() {
        UserDefaults.standard.set(MacSettingsTab.keepAwake.rawValue, forKey: MacSettingsTab.key)
        NSApp.activate()
        openSettings()
    }
}

/// View → Keep Mac Awake (Otto's own main menu).
struct KeepAwakeMenu: View {
    @Bindable var awake: KeepAwakeController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(awake.statusLine)
        Divider()
        Button { awake.setMode(.off) } label: { check(awake.mode == .off, "Off") }
        Button { awake.setMode(.whileWorking) } label: { check(awake.mode == .whileWorking, "While Agents Are Working") }
        Menu {
            ForEach(KeepAwakeController.presets, id: \.1) { seconds, label in
                Button(label) { awake.startTimer(seconds: seconds) }
            }
            Divider()
            Button("Custom…") { OpenKeepAwakeSettings(openSettings: openSettings)() }
        } label: { check(awake.mode.isTimer, "For a Duration") }
        if awake.mode.isTimer {
            Button("Add 30 Minutes") { awake.addTime(30 * 60) }
            Button("Add 1 Hour") { awake.addTime(3600) }
            Button("End Now") { awake.endEarly() }
        }
        Divider()
        if awake.lidClosedInstalled {
            Toggle("Stay Awake with Lid Closed", isOn: Binding(get: { awake.lidClosedWanted },
                                                              set: { awake.setLidClosed($0) }))
        } else {
            Button("Stay Awake with Lid Closed…") {
                OpenKeepAwakeSettings(openSettings: openSettings)()
                awake.setLidClosed(true)
            }
            .disabled(awake.setupBusy != nil || awake.relay == nil)
        }
        Divider()
        Button("Keep Awake Settings…") { OpenKeepAwakeSettings(openSettings: openSettings)() }
    }

    @ViewBuilder
    private func check(_ on: Bool, _ title: String) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// The main window's control: a cup in the sidebar footer, "Awake" next to it while the Mac is kept
/// awake. Click for the modes and the lid-closed toggle.
struct KeepAwakeSidebarControl: View {
    @Bindable var awake: KeepAwakeController
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: awake.symbol)
                    .font(.system(size: 11.5))
                    .foregroundStyle(awake.isAwakeNow ? Theme.accent : Color.secondary)
                if awake.isAwakeNow {
                    Text(awake.shortLabel).font(.system(size: 11)).foregroundStyle(Theme.accent).lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(awake.statusLine)
        .accessibilityLabel("Keep Mac awake")
        .accessibilityValue(awake.statusLine)
        .popover(isPresented: $open, arrowEdge: .top) {
            KeepAwakeForm(awake: awake, compact: true)
                .frame(width: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings → Keep Awake.
struct KeepAwakeSettings: View {
    @Bindable var awake: KeepAwakeController

    var body: some View {
        KeepAwakeForm(awake: awake, compact: false)
    }
}

/// Modes + lid-closed mode. Used in Settings and in the sidebar popover.
struct KeepAwakeForm: View {
    @Bindable var awake: KeepAwakeController
    var compact: Bool
    @State private var days = 0
    @State private var hours = 2
    @State private var minutes = 0
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Form {
            Section {
                Picker("Keep this Mac awake", selection: Binding(get: { pickerValue }, set: choose)) {
                    Text("Off").tag(0)
                    Text("While agents are working").tag(1)
                    Text("For a duration").tag(2)
                }
                .pickerStyle(.radioGroup)
                Text(awake.statusLine).foregroundStyle(.secondary)
                if pickerValue == 2 || awake.mode.isTimer {
                    HStack {
                        Stepper("\(days) d", value: $days, in: 0...7)
                        Stepper("\(hours) h", value: $hours, in: 0...23)
                        Stepper("\(minutes) min", value: $minutes, in: 0...55, step: 5)
                    }
                    HStack {
                        Button(awake.mode.isTimer ? "Restart Timer" : "Start") { awake.startTimer(seconds: durationSeconds) }
                            .disabled(durationSeconds < 60)
                        if awake.mode.isTimer {
                            Button("Add \(durationLabel)") { awake.addTime(durationSeconds) }
                                .disabled(durationSeconds < 60)
                            Button("End Now") { awake.endEarly() }
                        }
                    }
                }
            } footer: {
                if !compact {
                    Text("Stops idle sleep only while it's needed, and lets go when agents finish, when Hermes can't be reached and when Otto quits. With the lid closed a Mac still sleeps unless \"Stay awake with lid closed\" is on or an external display is connected.")
                }
            }

            Section {
                lidClosed
            } header: {
                Text("Lid closed")
            } footer: {
                if !compact {
                    Text("Hermes on this Mac turns off sleep while agents work or until the timer ends, and turns it back on when they finish, when the battery drops below 10% (Low Power Mode below 40%) or when the Mac gets too hot. A backstop restores sleep if Hermes stops.")
                }
            }

            if compact {
                Section {
                    Button("Keep Awake Settings…") { OpenKeepAwakeSettings(openSettings: openSettings)() }
                }
            }
        }
        .formStyle(.grouped)
        .task { await awake.poll() }
    }

    @ViewBuilder private var lidClosed: some View {
        if awake.relayOutdated {
            Text("The Hermes relay on this Mac needs restarting before lid-closed mode is available.")
                .foregroundStyle(.secondary)
        } else if awake.relay == nil {
            Text(awake.relayError ?? "Connecting to Hermes…").foregroundStyle(.secondary)
        } else {
            Toggle("Stay awake with lid closed", isOn: Binding(get: { awake.lidClosedWanted && awake.lidClosedInstalled },
                                                             set: { awake.setLidClosed($0) }))
                .disabled(awake.setupBusy != nil)
            if let busy = awake.setupBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(awake.setupMessage ?? (busy == "setup" ? "Setting up…" : "Undoing…"))
                }
            } else if let msg = awake.setupMessage {
                Label(msg, systemImage: awake.setupFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(awake.setupFailed ? Color.orange : Color.secondary)
            } else if !awake.lidClosedInstalled {
                Text("The first time, macOS asks you to approve this once with Touch ID or your password.")
                    .foregroundStyle(.secondary)
            }
            if let note = awake.lidClosedNote {
                Label("Ended: \(note)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if awake.lidClosedInstalled, let r = awake.relay {
                LabeledContent("Now", value: r.holding ? "Keeping this Mac awake with the lid closed" : "Not keeping it awake")
                if let b = r.battery, let p = b.percent {
                    LabeledContent("Battery", value: "\(p)%" + (b.onBattery == true ? " on battery" : " on power")
                                   + (r.lowPowerByUs == true ? ", Low Power Mode on" : ""))
                }
                if let t = r.thermal { LabeledContent("Temperature", value: t.capitalized) }
                if !compact {
                    Button("Undo Lid-Closed Setup") { Task { await awake.runSetup("undo") } }
                        .disabled(awake.setupBusy != nil)
                }
            }
        }
    }

    private var pickerValue: Int {
        switch awake.mode { case .off: 0; case .whileWorking: 1; case .until: 2 }
    }

    private func choose(_ v: Int) {
        switch v {
        case 0: awake.setMode(.off)
        case 1: awake.setMode(.whileWorking)
        default: if !awake.mode.isTimer { awake.startTimer(seconds: durationSeconds) }
        }
    }

    private var durationSeconds: TimeInterval { TimeInterval(days * 86400 + hours * 3600 + minutes * 60) }

    private var durationLabel: String {
        [days > 0 ? "\(days) d" : nil, hours > 0 ? "\(hours) h" : nil, minutes > 0 ? "\(minutes) min" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}
