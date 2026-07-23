import Foundation
import XCTest
@testable import AgentIsland

final class CalendarSupportTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testMonthGridAlwaysUsesSixWeeks() {
        let days = IslandCalendar.days(
            inMonthContaining: date(2024, 2, 14),
            today: date(2024, 2, 14),
            calendar: calendar
        )

        XCTAssertEqual(days.count, 42)
        XCTAssertEqual(days.first?.date, date(2024, 1, 28))
        XCTAssertEqual(days.last?.date, date(2024, 3, 9))
    }

    func testLeapDayBelongsToFebruary() {
        let days = IslandCalendar.days(
            inMonthContaining: date(2024, 2, 1),
            today: date(2024, 2, 29),
            calendar: calendar
        )
        let leapDay = days.first { $0.date == date(2024, 2, 29) }

        XCTAssertEqual(leapDay?.number, 29)
        XCTAssertEqual(leapDay?.isInDisplayedMonth, true)
        XCTAssertEqual(leapDay?.isToday, true)
        XCTAssertEqual(days.filter(\.isToday).count, 1)
    }

    func testMonthNavigationCrossesYearBoundary() {
        XCTAssertEqual(
            IslandCalendar.month(byAdding: 1, to: date(2024, 12, 20), calendar: calendar),
            date(2025, 1, 1)
        )
        XCTAssertEqual(
            IslandCalendar.month(byAdding: -1, to: date(2025, 1, 20), calendar: calendar),
            date(2024, 12, 1)
        )
    }

    func testWeekdaySymbolsFollowTheCalendarsFirstWeekday() {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2
        let symbols = IslandCalendar.weekdaySymbols(
            calendar: mondayFirst,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(symbols.count, 7)
        XCTAssertEqual(symbols.first, "M")
        XCTAssertEqual(symbols.last, "S")
    }

    func testCompactWingAlternatesOnlyWhenSessionsExist() {
        let firstFace = Date(timeIntervalSinceReferenceDate: 0)
        let secondFace = firstFace.addingTimeInterval(IslandCalendar.compactFaceDuration)

        XCTAssertTrue(IslandCalendar.compactWingShowsSession(
            at: firstFace, sessionCount: 1, calendarPresented: false))
        XCTAssertFalse(IslandCalendar.compactWingShowsSession(
            at: secondFace, sessionCount: 1, calendarPresented: false))
        XCTAssertTrue(IslandCalendar.compactWingShowsSession(
            at: secondFace.addingTimeInterval(IslandCalendar.compactFaceDuration),
            sessionCount: 3,
            calendarPresented: false
        ))
    }

    func testCompactWingKeepsClockFaceWithoutSessionsOrWhileCalendarIsOpen() {
        let date = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertFalse(IslandCalendar.compactWingShowsSession(
            at: date, sessionCount: 0, calendarPresented: false))
        XCTAssertFalse(IslandCalendar.compactWingShowsSession(
            at: date, sessionCount: 2, calendarPresented: true))
    }

    func testEventKeyTracksLocalDayNotTimeOfDay() {
        let morning = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 14, hour: 8
        ))!
        let evening = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 14, hour: 22
        ))!

        XCTAssertEqual(
            IslandCalendar.eventDayKey(for: morning, calendar: calendar),
            IslandCalendar.eventDayKey(for: evening, calendar: calendar)
        )
        XCTAssertNotEqual(
            IslandCalendar.eventDayKey(for: morning, calendar: calendar),
            IslandCalendar.eventDayKey(for: date(2026, 6, 15), calendar: calendar)
        )
    }

    func testEventTitleIsSingleLineTrimmedAndBounded() {
        XCTAssertEqual(
            IslandCalendar.sanitizedEventTitle("Birthday  "),
            "Birthday"
        )
        XCTAssertEqual(
            IslandCalendar.sanitizedEventTitle(String(repeating: "a", count: 200)).count,
            IslandCalendar.maxEventTitleLength
        )
        XCTAssertEqual(IslandCalendar.sanitizedEventTitle(" \n\t "), "")
    }
}
