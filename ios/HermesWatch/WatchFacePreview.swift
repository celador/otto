#if DEBUG
import SwiftUI
import WidgetKit

/// Debug-only: the complications rendered in the app, so they can be screenshotted (-watch.page 9).
struct WatchFacePreview: View {
    var body: some View {
        let limits = LimitsEntry(date: .now, snapshot: SharedVault.limits())
        let working = LiveEntry(date: .now, status: LiveStatus(state: .working, line: "Searching the web", title: "Trip to Porto",
                                                              sessionID: nil, steps: 3, startedAt: .now.addingTimeInterval(-95), updatedAt: .now))
        let done = LiveEntry(date: .now, status: LiveStatus(state: .done, line: "Porto in 3 days: start at the Ribeira.", title: "Trip to Porto",
                                                           sessionID: nil, steps: 4, startedAt: nil, updatedAt: .now))
        ScrollView {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    LimitsRingView(entry: limits, forcedFamily: .accessoryCircular).frame(width: 50, height: 50)
                    LiveLineView(entry: working, forcedFamily: .accessoryCircular).frame(width: 50, height: 50)
                    ZStack { AccessoryWidgetBackground(); Image(systemName: "mic.fill").font(.title3.weight(.semibold)) }
                        .frame(width: 50, height: 50)
                }
                LiveLineView(entry: working, forcedFamily: .accessoryRectangular).frame(height: 60).padding(6)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                LiveLineView(entry: done, forcedFamily: .accessoryRectangular).frame(height: 60).padding(6)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                LimitsRingView(entry: limits, forcedFamily: .accessoryRectangular).frame(height: 60).padding(6)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
#endif
