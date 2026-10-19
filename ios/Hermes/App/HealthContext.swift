import Foundation
import HealthKit

/// Opt-in: when you ask Hermes about sleep, training, heart rate or energy, a short Apple Health
/// summary rides along in the run's instructions (not in the visible message). Nothing is read or
/// sent unless the toggle in Settings is on and the question is about your body.
enum HealthContext {
    static let enabledKey = "health.enabled"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let store = HKHealthStore()

    private static var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [HKObjectType.workoutType()]
        s.insert(HKCategoryType(.sleepAnalysis))
        for id in [HKQuantityTypeIdentifier.restingHeartRate, .heartRateVariabilitySDNN, .stepCount,
                   .activeEnergyBurned, .vo2Max] {
            s.insert(HKQuantityType(id))
        }
        return s
    }

    /// Shows the Health permission sheet (iOS only asks once; later changes are in the Health app).
    static func requestAccess() async -> Bool {
        guard available else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            return false
        }
    }

    private static let words = [
        "sleep", "slept", "sleeping", "nap", "tired", "exhausted", "fatigued?", "energy", "heart", "hrv", "resting",
        "recover(y|ed|ing)?", "workouts?", "work out", "train(ing|ed)?", "exercise[sd]?", "cardio", "steps",
        "walk(ed|ing)?", "run(ning)? (today|yesterday|this week)", "health", "fitness", "stress(ed)?", "rest day",
        "calories?", "gym", "vo2", "marathon", "5k", "10k",
    ]
    private static let pattern = try! NSRegularExpression(pattern: "\\b(" + words.joined(separator: "|") + ")\\b",
                                                          options: [.caseInsensitive])

    static func isRelevant(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func contextIfRelevant(_ text: String) async -> String? {
        guard enabled, available, isRelevant(text) else { return nil }
        return await summary()
    }

    /// A few plain lines, e.g. "Last night: 7h 12m asleep (11:40 PM–7:05 AM)".
    static func summary(now: Date = .now) async -> String? {
        var lines: [String] = []
        if let s = await sleep(now: now) { lines.append("Last night's sleep: \(s)") }
        if let r = await latestAndAverage(.restingHeartRate, unit: .count().unitDivided(by: .minute()), days: 7) {
            lines.append("Resting heart rate: \(Int(r.latest.rounded())) bpm (7-day average \(Int(r.average.rounded())))")
        }
        if let h = await latestAndAverage(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), days: 7) {
            lines.append("Heart rate variability: \(Int(h.latest.rounded())) ms (7-day average \(Int(h.average.rounded())))")
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let stepsToday = await sum(.stepCount, unit: .count(), from: today, to: now)
        let stepsYesterday = await sum(.stepCount, unit: .count(), from: yesterday, to: today)
        if stepsToday != nil || stepsYesterday != nil {
            lines.append("Steps: \(fmt(stepsToday)) today so far, \(fmt(stepsYesterday)) yesterday")
        }
        if let kcal = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: today, to: now) {
            lines.append("Active energy today: \(Int(kcal)) kcal")
        }
        if let w = await workouts(days: 7, now: now) { lines.append("Workouts in the last 7 days: \(w)") }
        if let v = await latestAndAverage(.vo2Max, unit: HKUnit(from: "ml/kg*min"), days: 60) {
            lines.append(String(format: "VO2 max: %.1f", v.latest))
        }
        guard !lines.isEmpty else { return nil }
        return """
        Health data from my iPhone (Apple Health, read just now; use it only if it helps answer, \
        don't repeat it all back):
        """ + "\n- " + lines.joined(separator: "\n- ")
    }

    // MARK: Queries

    private static func sleep(now: Date) async -> String? {
        let start = Calendar.current.date(byAdding: .hour, value: -20, to: now)!
        let d = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis),
                                                                     predicate: HKQuery.predicateForSamples(withStart: start, end: now))],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await d.result(for: store), !samples.isEmpty else { return nil }
        var asleep: TimeInterval = 0, deep: TimeInterval = 0, rem: TimeInterval = 0
        var first: Date?, last: Date?
        for s in samples {
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { continue }
            let dur = s.endDate.timeIntervalSince(s.startDate)
            switch v {
            case .asleepCore, .asleepUnspecified: asleep += dur
            case .asleepDeep: asleep += dur; deep += dur
            case .asleepREM: asleep += dur; rem += dur
            default: continue
            }
            first = min(first ?? s.startDate, s.startDate)
            last = max(last ?? s.endDate, s.endDate)
        }
        guard asleep > 0, let first, let last else { return nil }
        var out = "\(hm(asleep)) asleep (\(first.formatted(date: .omitted, time: .shortened))–\(last.formatted(date: .omitted, time: .shortened))"
        if deep > 0 || rem > 0 { out += "; deep \(hm(deep)), REM \(hm(rem))" }
        return out + ")"
    }

    private static func latestAndAverage(_ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int) async -> (latest: Double, average: Double)? {
        let type = HKQuantityType(id)
        let since = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let predicate = HKQuery.predicateForSamples(withStart: since, end: .now)
        let latestQ = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                              sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
        guard let latest = try? await latestQ.result(for: store).first?.quantity.doubleValue(for: unit) else { return nil }
        let avgQ = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .discreteAverage)
        let avg = (try? await avgQ.result(for: store))?.averageQuantity()?.doubleValue(for: unit) ?? latest
        return (latest, avg)
    }

    private static func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async -> Double? {
        let q = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: HKQuantityType(id),
                                                                        predicate: HKQuery.predicateForSamples(withStart: from, end: to)),
                                            options: .cumulativeSum)
        return (try? await q.result(for: store))?.sumQuantity()?.doubleValue(for: unit)
    }

    private static func workouts(days: Int, now: Date) async -> String? {
        let since = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        let d = HKSampleQueryDescriptor(predicates: [.workout(HKQuery.predicateForSamples(withStart: since, end: now))],
                                        sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 8)
        guard let ws = try? await d.result(for: store), !ws.isEmpty else { return nil }
        return ws.map { w in
            var s = "\(name(w.workoutActivityType)) \(Int(w.duration / 60)) min"
            if let km = w.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo))
                ?? w.statistics(for: HKQuantityType(.distanceCycling))?.sumQuantity()?.doubleValue(for: .meterUnit(with: .kilo)),
               km > 0.1 {
                s += String(format: " %.1f km", km)
            }
            return s + " (\(w.startDate.formatted(.dateTime.weekday(.abbreviated))))"
        }.joined(separator: "; ")
    }

    private static func name(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: "Run"
        case .walking: "Walk"
        case .cycling: "Ride"
        case .swimming: "Swim"
        case .surfingSports: "Surf"
        case .yoga: "Yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength"
        case .highIntensityIntervalTraining: "HIIT"
        case .hiking: "Hike"
        case .pilates: "Pilates"
        case .soccer: "Football"
        case .tennis: "Tennis"
        default: "Workout"
        }
    }

    private static func hm(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    private static func fmt(_ v: Double?) -> String {
        guard let v else { return "—" }
        return Int(v).formatted()
    }
}
