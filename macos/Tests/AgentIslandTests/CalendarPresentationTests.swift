import Foundation
import XCTest
@testable import AgentIsland

final class CalendarPresentationTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "CalendarPresentationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    private func makeModel() -> IslandModel {
        IslandModel(defaults: makeDefaults())
    }

    @MainActor
    func testCalendarButtonOpensAndClosesPersistentPanel() {
        let model = makeModel()
        XCTAssertFalse(model.isCalendarPresented)
        XCTAssertFalse(model.isExpanded)

        model.toggleCalendar()
        XCTAssertTrue(model.isCalendarPresented)
        XCTAssertTrue(model.isShowingCalendar)
        XCTAssertTrue(model.isExpanded)
        XCTAssertEqual(
            model.preferredSize.height,
            model.persistentHeaderSize.height + IslandModel.calendarPanelContentHeight,
            accuracy: 0.5
        )
        XCTAssertGreaterThanOrEqual(model.preferredSize.width, 480)

        model.toggleCalendar()
        XCTAssertFalse(model.isCalendarPresented)
        XCTAssertFalse(model.isExpanded)
    }

    @MainActor
    func testCalendarDoesNotReplaceSelectedAgentTab() {
        let model = makeModel()
        model.selectTab(.settings)
        model.toggleCalendar()
        model.toggleCalendar()
        XCTAssertEqual(model.selectedTab, .settings)
    }

    @MainActor
    func testCalendarMonthMovesAndSelectedAdjacentDayBecomesItsMonth() {
        let model = makeModel()
        let original = model.calendarMonth
        model.moveCalendarMonth(by: 1)
        XCTAssertEqual(
            model.calendarMonth,
            IslandCalendar.month(byAdding: 1, to: original)
        )

        let nextYear = Calendar.autoupdatingCurrent.date(
            byAdding: .year,
            value: 1,
            to: original
        )!
        model.selectCalendarDate(nextYear)
        XCTAssertEqual(
            model.calendarMonth,
            IslandCalendar.startOfMonth(containing: nextYear)
        )
    }

    @MainActor
    func testAgentQuestionTakesPriorityOverOpenCalendar() {
        let model = makeModel()
        model.toggleCalendar()
        XCTAssertTrue(model.isShowingCalendar)

        model.setPhase(.question)
        XCTAssertFalse(model.isCalendarPresented)
        XCTAssertTrue(model.isQuestionPeeking)
        XCTAssertTrue(model.isExpanded)
    }

    @MainActor
    func testVolumePeekDoesNotCoverOpenCalendar() {
        let model = makeModel()
        model.toggleCalendar()
        model.handleVolumeChange(level: 0.5, delta: 0.1)

        XCTAssertTrue(model.isShowingCalendar)
        XCTAssertFalse(model.isVolumePeeking)
        XCTAssertFalse(model.isShowingVolumeHUD)
    }

    @MainActor
    func testCalendarEventPersistsEditsAndRemovesLocally() {
        let defaults = makeDefaults()
        let date = Date(timeIntervalSince1970: 1_781_395_200)
        let model = IslandModel(defaults: defaults)

        model.saveCalendarEvent("Birthday ", on: date)
        XCTAssertEqual(model.calendarEvent(on: date), "Birthday")
        XCTAssertEqual(IslandModel(defaults: defaults).calendarEvent(on: date), "Birthday")

        model.saveCalendarEvent("Dinner", on: date)
        XCTAssertEqual(model.calendarEventNotes.count, 1)
        XCTAssertEqual(model.calendarEvent(on: date), "Dinner")

        model.saveCalendarEvent("", on: date)
        XCTAssertNil(model.calendarEvent(on: date))
        XCTAssertNil(IslandModel(defaults: defaults).calendarEvent(on: date))
    }

    @MainActor
    func testCalendarEventStoreStaysBounded() {
        let defaults = makeDefaults()
        let existing = Dictionary(uniqueKeysWithValues: (0..<IslandModel.calendarEventNotesLimit).map {
            ("seed-\($0)", "event \($0)")
        })
        defaults.set(existing, forKey: IslandModel.calendarEventNotesKey)
        let model = IslandModel(defaults: defaults)

        model.saveCalendarEvent("One more", on: Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(model.calendarEventNotes.count, IslandModel.calendarEventNotesLimit)
        XCTAssertEqual(
            model.calendarEvent(on: Date(timeIntervalSinceReferenceDate: 0)),
            "One more"
        )
    }
}
