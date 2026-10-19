#if DEBUG
import SwiftUI
import WidgetKit

/// Debug-only (-hermes.widgetPreview YES): the Home/Lock Screen widgets rendered in the app with live data,
/// so they can be screenshotted (the simulator can't place widgets from automation).
struct WidgetPreviewView: View {
    @State private var now: NowEntry?
    @State private var jobs: JobsEntry?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let now {
                    HStack(spacing: 16) {
                        card(HermesNowView(entry: now, forcedFamily: .systemSmall), .systemSmall, w: 170, h: 170)
                        card(JobsWidgetView(entry: jobs ?? JobsEntry(date: .now, jobs: [], kicks: [], connected: true), forcedFamily: .systemSmall), .systemSmall, w: 170, h: 170)
                    }
                    card(HermesNowView(entry: now, forcedFamily: .systemMedium), .systemMedium, w: 356, h: 170)
                    if let jobs { card(JobsWidgetView(entry: jobs, forcedFamily: .systemMedium), .systemMedium, w: 356, h: 170) }
                    card(HermesNowView(entry: working, forcedFamily: .systemMedium), .systemMedium, w: 356, h: 170)
                    HStack(spacing: 12) {
                        HermesNowView(entry: working, forcedFamily: .accessoryRectangular)
                            .frame(width: 172, height: 76).padding(6).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                        HermesNowView(entry: now, forcedFamily: .accessoryRectangular)
                            .frame(width: 140, height: 76).padding(6).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                } else {
                    ProgressView("Loading live data…")
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .task {
            let latest = await NowProvider.fetchLatest() ?? NowProvider.cachedLatest()
            now = NowEntry(date: .now, status: .idle, latest: latest, connected: SharedVault.relay() != nil)
            if let r = SharedVault.relay(), let list = try? await JobsAPI.list(relay: r.relay, apiKey: r.apiKey) {
                let ordered = JobsAPI.ordered(list)
                let kick = ordered.dropFirst().first.map { [JobKick(jobID: $0.id, at: .now, previousLastRun: $0.lastRunAt)] } ?? []
                jobs = JobsEntry(date: .now, jobs: ordered, kicks: kick, connected: true)
            }
        }
    }

    private var working: NowEntry {
        NowEntry(date: .now, status: LiveStatus(state: .working, line: "Searching the web", title: "Weekend in Porto",
                                                sessionID: nil, steps: 3, startedAt: .now.addingTimeInterval(-95), updatedAt: .now),
                 latest: nil, connected: true)
    }

    private func card(_ v: some View, _ family: WidgetFamily, w: CGFloat, h: CGFloat) -> some View {
        v.padding(16)
            .frame(width: w, height: h)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
#endif
