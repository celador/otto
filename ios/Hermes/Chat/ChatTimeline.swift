import Foundation

/// Message times and day separators for the chat. Pure: dates, calendar and "now" come in.
enum ChatTimeline {
    /// The rows that start a new day (the first dated row overall, then the first dated row whose
    /// calendar day differs from the previous dated row), mapped to their date. Undated rows are skipped.
    nonisolated static func dayStarts(_ rows: [(id: String, date: Date?)],
                                      calendar: Calendar = .current) -> [String: Date] {
        var out: [String: Date] = [:]
        var lastDay: Date?
        for row in rows {
            guard let date = row.date else { continue }
            let day = calendar.startOfDay(for: date)
            if day != lastDay { out[row.id] = date }
            lastDay = day
        }
        return out
    }

    /// "Today", "Yesterday", a weekday within the last week, else "Oct 12" ("Oct 12, 2025" in another year).
    nonisolated static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                                     locale: Locale = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2..<7:
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.wide))
        default:
            var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day()
            if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
                style = style.year()
            }
            return date.formatted(style)
        }
    }

    /// "2:14 PM" in the device's locale and time zone.
    nonisolated static func timeLabel(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                        calendar: calendar, timeZone: calendar.timeZone))
    }
}
