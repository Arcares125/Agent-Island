import SwiftUI

/// A compact, native-feeling month calendar opened from the notch's right wing.
/// It refreshes once per minute—enough for its clock and midnight rollover,
/// without keeping a per-second timer alive in the menu bar.
struct CalendarPanelView: View {
    @ObservedObject var model: IslandModel

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @State private var editingEventDate: Date?
    @State private var eventDraft = ""
    @FocusState private var eventFieldFocused: Bool

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 28), spacing: 5),
        count: 7
    )

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let days = IslandCalendar.days(
                inMonthContaining: model.calendarMonth,
                today: timeline.date,
                calendar: calendar
            )

            ZStack(alignment: .bottom) {
                VStack(spacing: 8) {
                    calendarHeader(now: timeline.date)

                    Rectangle()
                        .fill(IslandPalette.line)
                        .frame(height: 1)

                    monthNavigation

                    LazyVGrid(columns: columns, spacing: 5) {
                        ForEach(IslandCalendar.weekdaySymbols(calendar: calendar, locale: locale), id: \.self) {
                            symbol in
                            Text(symbol.uppercased())
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(IslandPalette.secondary.opacity(0.8))
                                .frame(maxWidth: .infinity)
                        }

                        ForEach(days) { day in
                            dayButton(day)
                        }
                    }
                }

                if let editingEventDate {
                    eventEditor(for: editingEventDate)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(2)
                }
            }
            .animation(.easeOut(duration: 0.16), value: model.calendarMonth)
            .animation(.easeOut(duration: 0.18), value: editingEventDate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar")
    }

    private func calendarHeader(now: Date) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: 0x9480D8).opacity(0.16))
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xB7A7EE))
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(IslandCalendar.longDate(now, calendar: calendar, locale: locale))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandPalette.text)
                    .lineLimit(1)
                Text("Local time")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(IslandPalette.secondary)
                    .textCase(.uppercase)
            }

            Spacer(minLength: 8)

            Text(IslandCalendar.compactTime(now, calendar: calendar, locale: locale))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(IslandPalette.text)

            Button {
                model.toggleCalendar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(IslandPalette.secondary)
                    .frame(width: 24, height: 24)
                    .background(IslandPalette.raised)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close calendar")
        }
        .frame(height: 32)
    }

    private var monthNavigation: some View {
        HStack(spacing: 7) {
            navigationButton(systemName: "chevron.left", monthOffset: -1)

            Text(IslandCalendar.monthTitle(model.calendarMonth, calendar: calendar, locale: locale))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(IslandPalette.text)
                .frame(maxWidth: .infinity)
                .contentTransition(.interpolate)

            Button("Today") {
                model.showCalendarToday()
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color(hex: 0xB7A7EE))
            .buttonStyle(.plain)
            .help("Return to today")

            navigationButton(systemName: "chevron.right", monthOffset: 1)
        }
        .frame(height: 26)
    }

    private func navigationButton(systemName: String, monthOffset: Int) -> some View {
        Button {
            model.moveCalendarMonth(by: monthOffset)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(IslandPalette.secondary)
                .frame(width: 24, height: 24)
                .background(IslandPalette.raised)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(monthOffset < 0 ? "Previous month" : "Next month")
    }

    private func dayButton(_ day: IslandCalendarDay) -> some View {
        let isSelected = calendar.isDate(day.date, inSameDayAs: model.calendarSelectedDate)
        let event = model.calendarEvent(on: day.date, calendar: calendar)

        return Button {
            model.selectCalendarDate(day.date)
        } label: {
            Text("\(day.number)")
                .font(.system(size: 10, weight: day.isToday || isSelected ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(dayTextColor(day, isSelected: isSelected))
                .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(hex: 0x9480D8))
                    } else if day.isToday {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(hex: 0x9480D8).opacity(0.14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color(hex: 0x9480D8).opacity(0.8), lineWidth: 1)
                            }
                    }
                }
                .overlay(alignment: .bottom) {
                    if event != nil {
                        Circle()
                            .fill(
                                isSelected
                                    ? IslandPalette.surface.opacity(0.8)
                                    : Color(hex: 0xE9A27C)
                            )
                            .frame(width: 3, height: 3)
                            .padding(.bottom, 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                beginEditingEvent(on: day.date)
            }
        )
        .help(dayHelp(for: day.date, event: event))
    }

    private func beginEditingEvent(on date: Date) {
        model.selectCalendarDate(date)
        eventDraft = model.calendarEvent(on: date, calendar: calendar) ?? ""
        editingEventDate = date
        DispatchQueue.main.async {
            eventFieldFocused = true
        }
    }

    private func eventEditor(for date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.calendarEvent(on: date, calendar: calendar) == nil ? "NEW EVENT" : "EDIT EVENT")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0xE9A27C))
                    Text(IslandCalendar.longDate(date, calendar: calendar, locale: locale))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IslandPalette.text)
                }

                Spacer()

                Button {
                    closeEventEditor()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(IslandPalette.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            TextField("Birthday", text: $eventDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandPalette.text)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(IslandPalette.surface.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(hex: 0x9480D8).opacity(eventFieldFocused ? 0.9 : 0.35))
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .focused($eventFieldFocused)
                .onSubmit { saveEvent(on: date) }
                .onChange(of: eventDraft) { _, value in
                    if value.count > IslandCalendar.maxEventTitleLength {
                        eventDraft = String(value.prefix(IslandCalendar.maxEventTitleLength))
                    }
                }

            HStack(spacing: 8) {
                if model.calendarEvent(on: date, calendar: calendar) != nil {
                    Button("Remove") {
                        model.saveCalendarEvent("", on: date, calendar: calendar)
                        closeEventEditor()
                    }
                    .foregroundStyle(Color(hex: 0xE58A62))
                    .buttonStyle(.plain)
                }

                Spacer()

                Button("Cancel") {
                    closeEventEditor()
                }
                .foregroundStyle(IslandPalette.secondary)
                .buttonStyle(.plain)

                Button("Save") {
                    saveEvent(on: date)
                }
                .fontWeight(.semibold)
                .foregroundStyle(IslandPalette.surface)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Color(hex: 0xB7A7EE))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(10)
        .frame(maxWidth: 330)
        .background(IslandPalette.raised.opacity(0.98))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(IslandPalette.line)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
    }

    private func saveEvent(on date: Date) {
        model.saveCalendarEvent(eventDraft, on: date, calendar: calendar)
        closeEventEditor()
    }

    private func closeEventEditor() {
        eventFieldFocused = false
        editingEventDate = nil
        eventDraft = ""
    }

    private func dayHelp(for date: Date, event: String?) -> String {
        let day = IslandCalendar.longDate(date, calendar: calendar, locale: locale)
        if let event { return "\(day) — \(event). Double-click to edit." }
        return "\(day). Double-click to add an event."
    }

    private func dayTextColor(_ day: IslandCalendarDay, isSelected: Bool) -> Color {
        if isSelected { return IslandPalette.surface }
        if !day.isInDisplayedMonth { return IslandPalette.secondary.opacity(0.38) }
        if day.isToday { return Color(hex: 0xC6B9F2) }
        return IslandPalette.text.opacity(0.9)
    }
}
