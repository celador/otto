import SwiftUI

/// Your scheduled Hermes jobs. Tap one to run it now; the output goes wherever the job already sends it.
struct WatchJobsView: View {
    @Bindable var model: WatchModel

    var body: some View {
        List {
            if model.jobs.isEmpty {
                if model.jobsLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(model.jobsError ?? "No scheduled jobs.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(model.jobs) { job in
                NavigationLink(value: job) { JobRow(job: job, model: model) }
            }
        }
        .navigationTitle("Jobs")
        .navigationDestination(for: JobLite.self) { job in WatchJobDetail(jobID: job.id, model: model) }
        .task { await model.loadJobs() }
    }
}

private struct JobRow: View {
    let job: JobLite
    @Bindable var model: WatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(job.title).font(.footnote.weight(.semibold)).lineLimit(2)
            }
            Text(model.jobNotes[job.id] ?? JobText.subtitle(job)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var dot: Color {
        if model.isRunning(job) { return .blue }
        if job.isPaused { return .gray }
        return job.lastFailed ? .red : .green
    }
}

struct WatchJobDetail: View {
    let jobID: String
    @Bindable var model: WatchModel

    private var job: JobLite? { model.jobs.first { $0.id == jobID } }

    var body: some View {
        ScrollView {
            if let job {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.title).font(.headline)
                    Text(JobText.subtitle(job)).font(.caption2).foregroundStyle(.secondary)
                    Text("Output goes to \(job.deliveryLabel).").font(.caption2).foregroundStyle(.secondary)
                    Button {
                        Task { await model.run(job) }
                    } label: {
                        Label(model.isRunning(job) ? "Running…" : "Run now",
                              systemImage: model.isRunning(job) ? "hourglass" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .disabled(model.isRunning(job))
                    .padding(.top, 4)
                    if let note = model.jobNotes[job.id] {
                        Text(note).font(.footnote.weight(.semibold)).frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .navigationTitle("Job")
    }
}

enum JobText {
    static func subtitle(_ job: JobLite) -> String {
        if job.isPaused { return "Paused" }
        var parts: [String] = []
        if let n = job.nextRun { parts.append("Next " + when(n)) }
        if job.lastFailed { parts.append("last failed") } else if let l = job.lastRun { parts.append("ran " + when(l)) }
        return parts.joined(separator: " · ")
    }

    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return time }
        if cal.isDateInTomorrow(d) { return "tmrw \(time)" }
        if cal.isDateInYesterday(d) { return "yest. \(time)" }
        return d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
