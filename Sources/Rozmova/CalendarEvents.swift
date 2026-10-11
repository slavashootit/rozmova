import AppKit
import EventKit

/// A timed event from macOS Calendar.
struct CalEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String
    let color: NSColor
    /// Join link of an online meeting (Zoom, Meet, Teams…); nil for an offline event.
    let onlineLink: URL?
    let hasAttendees: Bool

    var isOnline: Bool { onlineLink != nil }
    /// More likely to be the call than a "focus time" block.
    var isMeeting: Bool { isOnline || hasAttendees }

    var link: EventLink { EventLink(title: title, start: start, end: end, calendar: calendar) }
}

/// macOS Calendar, read only: meetings next to calls in the dashboard, and their names on calls.
/// Everything stays empty until the user allows access.
@MainActor
final class CalendarEvents: ObservableObject {
    static let shared = CalendarEvents()

    private let store = EKEventStore()
    /// Bumped when access is granted or the calendar changes, so views query again.
    @Published private(set) var revision = 0

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    func refresh() {
        revision += 1
    }

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asked once; after "Don't Allow" only System Settings can change it.
    var canAsk: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    func requestAccess() async {
        NSApp.activate()
        do {
            let granted = try await store.requestFullAccessToEvents()
            Log.info("Calendar access: \(granted)")
        } catch {
            Log.info("Calendar access failed: \(error.localizedDescription)")
        }
        revision += 1
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Timed events that overlap the interval. All-day events (birthdays, holidays) are left out.
    func events(from start: Date, to end: Date) -> [CalEvent] {
        guard hasAccess, start < end else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { event in
                CalEvent(
                    id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)@\(event.startDate.timeIntervalSince1970)",
                    title: (event.title ?? "").isEmpty ? "Без назви" : event.title,
                    start: event.startDate,
                    end: event.endDate,
                    calendar: event.calendar.title,
                    color: event.calendar.color ?? .systemGray,
                    onlineLink: Self.meetingLink(in: [event.url?.absoluteString, event.location, event.notes]),
                    hasAttendees: event.hasAttendees
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// The event a finished call happened in, if any.
    func event(forCallAt start: Date, duration: Double) -> CalEvent? {
        let end = start.addingTimeInterval(max(duration, 60))
        return Self.best(start: start, duration: duration, among: events(from: start, to: end))
    }

    func link(forCallAt start: Date, duration: Double) -> EventLink? {
        event(forCallAt: start, duration: duration)?.link
    }

    /// The meeting going on now or starting in the next few minutes: names the "record?" prompt.
    func current(at now: Date = Date()) -> CalEvent? {
        events(from: now, to: now.addingTimeInterval(10 * 60))
            .filter { $0.end > now }
            .sorted { ($0.isMeeting ? 0 : 1, abs($0.start.timeIntervalSince(now))) < ($1.isMeeting ? 0 : 1, abs($1.start.timeIntervalSince(now))) }
            .first
    }

    /// Online meetings starting within the next `seconds`.
    func onlineStarting(within seconds: Double, from now: Date = Date()) -> [CalEvent] {
        events(from: now, to: now.addingTimeInterval(seconds))
            .filter { $0.isOnline && $0.start >= now.addingTimeInterval(-30) && $0.start <= now.addingTimeInterval(seconds) }
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                       "facetime.apple.com", "webex.com", "whereby.com", "meet.jit.si"]
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The first video call link in the event's URL, location or notes. An event without one is
    /// treated as offline: a link pasted only in a chat cannot be seen.
    static func meetingLink(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in linkDetector?.matches(in: text, range: range) ?? [] {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return url
                }
            }
        }
        return nil
    }

    /// The event the call overlaps most. Grazing an edge does not count: the overlap must be at
    /// least 5 minutes or half the call. Meetings with attendees or a link win over plain blocks.
    nonisolated static func best(start: Date, duration: Double, among events: [CalEvent]) -> CalEvent? {
        let length = max(duration, 60)
        let end = start.addingTimeInterval(length)
        var best: (event: CalEvent, score: Double)?
        for event in events {
            let overlap = min(end, event.end).timeIntervalSince(max(start, event.start))
            guard overlap > 0, overlap >= min(300, length / 2) else { continue }
            let score = overlap * (event.isMeeting ? 2 : 1)
            if best == nil || score > best!.score {
                best = (event, score)
            }
        }
        return best?.event
    }
}
