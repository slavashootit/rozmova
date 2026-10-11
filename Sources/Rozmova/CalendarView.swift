import AppKit
import SwiftUI

/// One thing on a day: a recorded call, or a Calendar meeting that has no recording.
enum DayItem: Identifiable {
    case call(CallRecord)
    case meeting(CalEvent)

    var id: String {
        switch self {
        case .call(let call): return "call-" + call.id
        case .meeting(let event): return "event-" + event.id
        }
    }

    var start: Date {
        switch self {
        case .call(let call): return call.meta.started
        case .meeting(let event): return event.start
        }
    }
}

/// The days shown for a month: whole weeks, Monday first.
struct MonthGrid {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "uk_UA")
        calendar.firstWeekday = 2
        return calendar
    }()

    let first: Date
    let days: [Date]

    init(month: Date) {
        let calendar = Self.calendar
        first = calendar.dateInterval(of: .month, for: month)?.start ?? calendar.startOfDay(for: month)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let cells = (lead + count + 6) / 7 * 7
        let start = calendar.date(byAdding: .day, value: -lead, to: first) ?? first
        days = (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var start: Date { days.first ?? first }
    var end: Date { Self.calendar.date(byAdding: .day, value: 1, to: days.last ?? first) ?? first }

    func contains(_ day: Date) -> Bool {
        Self.calendar.isDate(day, equalTo: first, toGranularity: .month)
    }

    var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "uk_UA")
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: first).capitalizedFirst
    }
}

/// "Календар" in the dashboard: a month of calls, with meetings from macOS Calendar next to them.
struct CalendarView: View {
    @ObservedObject var library: CallLibrary
    @ObservedObject var events: CalendarEvents

    private static let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Нд"]

    var body: some View {
        let grid = MonthGrid(month: library.month)
        let items = Self.items(grid: grid, calls: library.calls, events: events)
        let monthCalls = library.calls.filter { grid.contains($0.meta.started) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(grid, calls: monthCalls)
                if !events.hasAccess {
                    connect
                }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(Self.weekdays, id: \.self) { name in
                            Text(name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(grid.days, id: \.self) { day in
                            DayCell(day: day,
                                    inMonth: grid.contains(day),
                                    selected: library.day.map { MonthGrid.calendar.isDate($0, inSameDayAs: day) } ?? false,
                                    items: items[MonthGrid.calendar.startOfDay(for: day)] ?? [],
                                    library: library)
                        }
                    }
                }
                if let day = library.day {
                    agenda(day, items: items[MonthGrid.calendar.startOfDay(for: day)] ?? Self.items(for: day, library: library, events: events))
                }
            }
            .padding(24)
        }
        // Access may have been switched on in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            events.refresh()
        }
    }

    private func header(_ grid: MonthGrid, calls: [CallRecord]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(grid.title).font(.largeTitle.bold())
            if !calls.isEmpty {
                let hours = calls.reduce(0) { $0 + $1.meta.duration } / 3600
                Text("Дзвінків: \(calls.count) · \(String(format: "%.1f", hours)) год")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Попередній місяць")
                Button("Сьогодні") {
                    library.month = Date()
                    library.day = Date()
                }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .help("Наступний місяць")
            }
            .buttonStyle(.bordered)
        }
    }

    private func shift(_ months: Int) {
        let month = MonthGrid.calendar.date(byAdding: .month, value: months, to: MonthGrid(month: library.month).first) ?? Date()
        library.month = month
        library.day = MonthGrid(month: month).contains(Date()) ? Date() : nil
    }

    private var connect: some View {
        Card("Зустрічі з Календаря macOS", subtitle: nil) {
            Text("Підключи Календар, і зустрічі з'являться поруч із дзвінками, а записи отримають назви подій замість «Дзвінок у Zoom». Rozmova лише читає календар і нічого в ньому не змінює.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(events.canAsk ? "Підключити Календар" : "Відкрити налаштування приватності") {
                if events.canAsk {
                    Task {
                        await events.requestAccess()
                        library.reload()
                    }
                } else {
                    events.openPrivacySettings()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func agenda(_ day: Date, items: [DayItem]) -> some View {
        Card(Format.day(day).capitalizedFirst, subtitle: nil) {
            if items.isEmpty {
                Text("У цей день нічого немає.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                switch item {
                case .call(let call):
                    Button {
                        library.selection = call.id
                    } label: {
                        HStack(spacing: 12) {
                            AppBadge(app: call.meta.app, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(call.title).fontWeight(.medium).lineLimit(1)
                                Text(Self.details(call))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                case .meeting(let event):
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: event.color))
                            .frame(width: 4, height: 32)
                            .padding(.horizontal, 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).lineLimit(1)
                            Text(Format.timeRange(event.start, event.end.timeIntervalSince(event.start)) + " · " + event.calendar)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(event.end < Date() ? "не записано" : "попереду")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Data

    /// "15:02 – 15:54 · 52 хв · Робота"
    private static func details(_ call: CallRecord) -> String {
        var parts = [Format.timeRange(call.meta.started, call.meta.duration), Format.minutes(call.meta.duration)]
        if let calendar = call.meta.event?.calendar {
            parts.append(calendar)
        }
        return parts.joined(separator: " · ")
    }

    /// Calls and unrecorded meetings of the visible weeks, by day.
    @MainActor
    private static func items(grid: MonthGrid, calls: [CallRecord], events: CalendarEvents) -> [Date: [DayItem]] {
        _ = events.revision
        let shown = calls.filter { $0.meta.started >= grid.start && $0.meta.started < grid.end }
        return group(calls: shown, meetings: events.events(from: grid.start, to: grid.end))
    }

    /// For a selected day outside the visible weeks.
    @MainActor
    private static func items(for day: Date, library: CallLibrary, events: CalendarEvents) -> [DayItem] {
        let start = MonthGrid.calendar.startOfDay(for: day)
        let end = MonthGrid.calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return group(calls: library.calls(onDay: day), meetings: events.events(from: start, to: end))[start] ?? []
    }

    /// A meeting that has a call recorded during it is shown as that call only.
    private static func group(calls: [CallRecord], meetings: [CalEvent]) -> [Date: [DayItem]] {
        let recorded = Set(calls.compactMap { call in
            CalendarEvents.best(start: call.meta.started, duration: call.meta.duration, among: meetings)?.id
        })
        let all = calls.map(DayItem.call) + meetings.filter { !recorded.contains($0.id) }.map(DayItem.meeting)
        return Dictionary(grouping: all) { MonthGrid.calendar.startOfDay(for: $0.start) }
            .mapValues { $0.sorted { $0.start < $1.start } }
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let selected: Bool
    let items: [DayItem]
    @ObservedObject var library: CallLibrary

    private static let limit = 3

    var body: some View {
        let isToday = MonthGrid.calendar.isDateInToday(day)
        VStack(alignment: .leading, spacing: 3) {
            Text("\(MonthGrid.calendar.component(.day, from: day))")
                .font(.callout.weight(isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary))
                .frame(width: 24, height: 24)
                .background(Circle().fill(isToday ? Color.accentColor : Color.clear))
            ForEach(items.prefix(Self.limit)) { item in
                line(item)
            }
            if items.count > Self.limit {
                Text("ще \(items.count - Self.limit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(inMonth ? 1 : 0.45)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.07), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { library.day = day }
    }

    @ViewBuilder
    private func line(_ item: DayItem) -> some View {
        switch item {
        case .call(let call):
            let color = AppStyle.color(call.meta.app)
            Button {
                library.selection = call.id
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(Self.time(call.meta.started)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text(call.title).font(.caption).lineLimit(1)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(call.title), \(Format.timeRange(call.meta.started, call.meta.duration))")
        case .meeting(let event):
            HStack(spacing: 4) {
                Circle().strokeBorder(Color(nsColor: event.color), lineWidth: 1.5).frame(width: 6, height: 6)
                Text(Self.time(event.start)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(event.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .help("\(event.title), \(event.calendar)")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

extension String {
    /// "жовтень 2026" -> "Жовтень 2026"
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
