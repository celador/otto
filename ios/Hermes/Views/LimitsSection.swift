import SwiftUI
import WidgetKit

/// Usage → "Limits": every AI subscription CodexBar watches on the Mac (Codex, Claude, …),
/// with each rolling window, when it resets, and whether you're on pace.
struct LimitsSection: View {
    let snapshot: LimitsSnapshot?
    let loading: Bool
    let failed: String?

    var body: some View {
        Section {
            if let snapshot, !snapshot.providers.isEmpty {
                ForEach(snapshot.orderedProviders + snapshot.providers.filter { $0.windows.isEmpty }) { p in
                    ProviderLimitsCard(provider: p)
                }
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking your limits…").foregroundStyle(.secondary)
                }
            } else if let message = snapshot?.error ?? failed {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                Text("Turn on providers in CodexBar on your Mac to see them here.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Limits")
        } footer: {
            footer
        }
    }

    private var footer: some View {
        Group {
            if let date = snapshot?.fetchedDate {
                Text("From CodexBar on your Mac · updated \(date, style: .relative) ago\(snapshot?.stale == true ? " · couldn't refresh" : "")")
            } else {
                Text("From CodexBar on your Mac.")
            }
        }
    }
}

private struct ProviderLimitsCard: View {
    let provider: LimitProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderMark(id: provider.id)
                Text(provider.name).font(.headline)
                if let plan = provider.planLabel {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Spacer()
                if let credits = provider.credits, credits > 0 {
                    Text("\(credits, format: .number.precision(.fractionLength(0...2))) credits")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let incident = provider.incident {
                Label(incident, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            if let error = provider.error, provider.windows.isEmpty {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(provider.windows) { w in
                LimitWindowRow(window: w)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Small monochrome provider badge (no third-party logos bundled).
struct ProviderMark: View {
    let id: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 24, height: 24)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var symbol: String {
        switch id {
        case "codex", "openai": "chevron.left.forwardslash.chevron.right"
        case "claude": "sparkle"
        case "cursor": "cursorarrow.rays"
        case "gemini": "diamond"
        case "copilot": "airplane"
        default: "gauge.with.dots.needle.33percent"
        }
    }
}

@MainActor
@Observable
final class LimitsStore {
    static let shared = LimitsStore()
    private(set) var snapshot: LimitsSnapshot? = SharedVault.limits()
    private(set) var loading = false
    private(set) var failed: String?

    func load(_ client: CompanionClient, refresh: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            let s = try await client.limits(refresh: refresh)
            snapshot = s
            failed = nil
            SharedVault.saveLimits(s)
            WatchBridge.shared.pushLimits(s)
            WidgetCenter.shared.reloadTimelines(ofKind: LimitsWidgetKind.kind)
        } catch {
            failed = "Couldn't reach CodexBar on your Mac."
        }
    }
}
