import Foundation

/// One stable cell in the six-row month grid. Adjacent-month dates remain
/// visible (dimmed by the view) so the calendar never jumps in height.
struct IslandCalendarDay: Identifiable, Equatable {
    let date: Date
    let number: Int
    let isInDisplayedMonth: Bool
    let isToday: Bool

    var id: Date { date }
}

/// Calendar arithmetic and formatting kept outside SwiftUI so month boundaries,
/// locale ordering, and leap years are testable without launching a window.
enum IslandCalendar {
    static let compactFaceDuration: TimeInterval = 5
    static let maxEventTitleLength = 80
    private static let formatterLock = NSLock()
    private static var formatterCache: [String: DateFormatter] = [:]
    private static let formatterCacheLimit = 16

    static func compactWingShowsSession(
        at date: Date,
        sessionCount: Int,
        calendarPresented: Bool
    ) -> Bool {
        guard sessionCount > 0, !calendarPresented else { return false }
        return Int(date.timeIntervalSinceReferenceDate / compactFaceDuration)
            .isMultiple(of: 2)
    }

    static func eventDayKey(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return [
            String(describing: calendar.identifier),
            String(components.era ?? 0),
            String(components.year ?? 0),
            String(components.month ?? 0),
            String(components.day ?? 0)
        ].joined(separator: "-")
    }

    static func sanitizedEventTitle(_ title: String) -> String {
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(maxEventTitleLength))
    }

    static func startOfMonth(
        containing date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func month(
        byAdding offset: Int,
        to date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        let start = startOfMonth(containing: date, calendar: calendar)
        return calendar.date(byAdding: .month, value: offset, to: start) ?? start
    }

    static func days(
        inMonthContaining displayedDate: Date,
        today: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [IslandCalendarDay] {
        let monthStart = startOfMonth(containing: displayedDate, calendar: calendar)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart)
            ?? monthStart

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }
            return IslandCalendarDay(
                date: date,
                number: calendar.component(.day, from: date),
                isInDisplayedMonth: calendar.isDate(
                    date,
                    equalTo: monthStart,
                    toGranularity: .month
                ),
                isToday: calendar.isDate(date, inSameDayAs: today)
            )
        }
    }

    static func weekdaySymbols(
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> [String] {
        let symbols = withFormatter(
            template: "weekday-symbols",
            calendar: calendar,
            locale: locale
        ) { formatter in
            formatter.veryShortStandaloneWeekdaySymbols ?? []
        }
        guard symbols.count == 7 else { return symbols }
        let first = min(max(calendar.firstWeekday - 1, 0), symbols.count - 1)
        return Array(symbols[first...] + symbols[..<first])
    }

    static func monthTitle(
        _ date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        formatted(date, template: "MMMM y", calendar: calendar, locale: locale)
    }

    static func compactDate(
        _ date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        formatted(date, template: "MMM d", calendar: calendar, locale: locale)
    }

    static func compactTime(
        _ date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        formatted(date, template: "j:mm", calendar: calendar, locale: locale)
    }

    static func longDate(
        _ date: Date,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        formatted(date, template: "EEEE, MMMM d", calendar: calendar, locale: locale)
    }

    private static func formatted(
        _ date: Date,
        template: String,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        withFormatter(template: template, calendar: calendar, locale: locale) {
            $0.string(from: date)
        }
    }

    /// DateFormatter is expensive and Foundation can retain its ICU backing
    /// storage after deallocation. SwiftUI may reevaluate the compact wing for
    /// unrelated agent updates, so keep a tiny bounded cache and serialize access
    /// to make the pure helpers safe in parallel tests as well as on the UI thread.
    private static func withFormatter<T>(
        template: String,
        calendar: Calendar,
        locale: Locale,
        body: (DateFormatter) -> T
    ) -> T {
        let key = [
            String(describing: calendar.identifier),
            String(calendar.firstWeekday),
            locale.identifier,
            calendar.timeZone.identifier,
            template
        ].joined(separator: "|")

        formatterLock.lock()
        defer { formatterLock.unlock() }

        let formatter: DateFormatter
        if let cached = formatterCache[key] {
            formatter = cached
        } else {
            if formatterCache.count >= formatterCacheLimit {
                formatterCache.removeAll(keepingCapacity: true)
            }
            let created = DateFormatter()
            created.calendar = calendar
            created.locale = locale
            created.timeZone = calendar.timeZone
            if template != "weekday-symbols" {
                created.setLocalizedDateFormatFromTemplate(template)
            }
            formatterCache[key] = created
            formatter = created
        }

        return body(formatter)
    }
}
