import SwiftUI

/// Second page on the watch (scroll down / Digital Crown): your Codex and Claude limits.
struct WatchLimitsView: View {
    @Bindable var model: WatchModel

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let providers = model.limits?.orderedProviders ?? []
                    if providers.isEmpty {
                        if model.limitsLoading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("No limits yet. Keep your iPhone nearby.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(providers) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Text(p.name).font(.headline)
                                if let plan = p.planLabel { Text(plan).font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let incident = p.incident {
                                Text(incident).font(.caption2).foregroundStyle(.orange)
                            }
                            ForEach(p.windows) { w in
                                LimitWindowRow(window: w, showPace: false, compact: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .navigationTitle("Limits")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.loadLimits() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(model.limitsLoading)
                        .accessibilityLabel("Refresh limits")
                }
            }
            .task { if model.limits == nil { await model.loadLimits() } }
    }
}
