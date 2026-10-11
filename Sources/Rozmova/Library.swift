import Combine
import Foundation

/// One call in the dashboard, read from its history folder.
struct CallRecord: Identifiable {
    let id: String
    var meta: SessionMeta
    /// Speech pieces with speakers; empty for calls transcribed before segments were saved.
    let pieces: [Segment]

    var layout: Layout {
        let media = meta.mediaFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Prefs.recordingsFolder.appendingPathComponent(id, isDirectory: true)
        return Layout(name: id, mediaFolder: media)
    }

    var title: String { meta.displayTitle }
    var turns: [Segment] { Transcriber.merge(pieces) }

    /// Labels in order of first appearance, "Я" first.
    var speakers: [String] {
        var seen: [String] = []
        for piece in pieces where !seen.contains(piece.speaker) {
            seen.append(piece.speaker)
        }
        return seen.filter { $0 == Transcriber.me } + seen.filter { $0 != Transcriber.me }
    }

    func name(of speaker: String) -> String {
        let custom = meta.speakerNames?[speaker] ?? ""
        return custom.isEmpty ? speaker : custom
    }

    /// Lowercased title, app and everything said, for search.
    let searchText: String
    /// Computed once on load; nil for calls without speech pieces.
    let stats: CallStats?

    init(id: String, meta: SessionMeta, pieces: [Segment]) {
        self.id = id
        self.meta = meta
        self.pieces = pieces
        self.searchText = ([meta.displayTitle, meta.app] + pieces.map(\.text)).joined(separator: " ").lowercased()
        self.stats = pieces.isEmpty ? nil : CallStats(pieces: pieces)
    }

    var summary: CallSummary {
        CallSummary(started: meta.started, duration: meta.duration, app: meta.app, stats: stats,
                    names: meta.speakerNames ?? [:])
    }
}

struct WeekGroup: Identifiable {
    let id: String
    let calls: [CallRecord]
}

/// All calls from History, newest first, plus search and renaming.
@MainActor
final class CallLibrary: ObservableObject {
    @Published private(set) var calls: [CallRecord] = []
    /// Sidebar rows that show the overview or the calendar instead of a call.
    static let overviewID = "overview"
    static let calendarID = "calendar"

    @Published var query = ""
    @Published var selection: String? = CallLibrary.overviewID
    @Published var period = Period.month
    /// Any date in the month the calendar shows.
    @Published var month = Date()
    /// The day whose calls and meetings are listed under the calendar.
    @Published var day: Date? = Date()

    /// Set by AppDelegate: transcribe a call again (while its separate tracks still exist).
    var onReprocess: (Layout) -> Void = { _ in }

    var selected: CallRecord? { calls.first { $0.id == selection } }

    var overview: Overview { Overview(calls.map(\.summary), period: period) }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Prefs.historyFolder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? []
        calls = folders.compactMap { folder -> CallRecord? in
            let layout = Layout(name: folder.lastPathComponent, mediaFolder: folder)
            guard let meta = try? SessionMeta.load(from: layout) else { return nil }
            return CallRecord(id: layout.name, meta: meta, pieces: SegmentsFile.load(layout))
        }
        .sorted { $0.meta.started > $1.meta.started }
        linkEvents()
        let pages = [Self.overviewID, Self.calendarID]
        if selection == nil || (!pages.contains(selection!) && !calls.contains(where: { $0.id == selection })) {
            selection = Self.overviewID
        }
    }

    /// Names calls recorded before Calendar access (or before this version) after their events.
    /// One Calendar query per month, not per call.
    private func linkEvents() {
        let calendar = CalendarEvents.shared
        guard calendar.hasAccess else { return }
        let unlinked = calls.indices.filter { calls[$0].meta.event == nil }
        let months = Dictionary(grouping: unlinked) { index in
            Calendar.current.dateInterval(of: .month, for: calls[index].meta.started)?.start ?? .distantPast
        }
        for indices in months.values {
            let from = indices.map { calls[$0].meta.started }.min() ?? Date()
            let to = indices.map { calls[$0].meta.started.addingTimeInterval(max(calls[$0].meta.duration, 60)) }.max() ?? from
            let events = calendar.events(from: from, to: to)
            guard !events.isEmpty else { continue }
            for index in indices {
                var call = calls[index]
                guard let event = CalendarEvents.best(start: call.meta.started, duration: call.meta.duration,
                                                      among: events) else { continue }
                call.meta.event = event.link
                do {
                    try call.meta.save(to: call.layout)
                    if !call.pieces.isEmpty {
                        try Transcript.write(meta: call.meta, layout: call.layout, turns: call.turns)
                    }
                } catch {
                    Log.info("Linking \(call.id) to an event failed: \(error.localizedDescription)")
                }
                calls[index] = CallRecord(id: call.id, meta: call.meta, pieces: call.pieces)
            }
        }
    }

    /// Calls that started on this day, earliest first.
    func calls(onDay day: Date) -> [CallRecord] {
        calls.filter { Calendar.current.isDate($0.meta.started, inSameDayAs: day) }
            .sorted { $0.meta.started < $1.meta.started }
    }

    var weeks: [WeekGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let found = needle.isEmpty ? calls : calls.filter { $0.searchText.contains(needle) }
        let calendar = Calendar(identifier: .iso8601)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "uk_UA")
        formatter.dateFormat = "d MMM"
        var groups: [WeekGroup] = []
        for call in found {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: call.meta.started) else { continue }
            let end = week.end.addingTimeInterval(-1)
            let title = "Тиждень \(formatter.string(from: week.start)) – \(formatter.string(from: end))"
            if let last = groups.last, last.id == title {
                groups[groups.count - 1] = WeekGroup(id: title, calls: last.calls + [call])
            } else {
                groups.append(WeekGroup(id: title, calls: [call]))
            }
        }
        return groups
    }

    /// Saves the name and rewrites the .txt with it.
    func rename(_ speaker: String, to name: String, in id: String) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        var call = calls[index]
        var names = call.meta.speakerNames ?? [:]
        names[speaker] = name.trimmingCharacters(in: .whitespaces)
        call.meta.speakerNames = names
        calls[index] = call
        do {
            try call.meta.save(to: call.layout)
            if !call.pieces.isEmpty {
                try Transcript.write(meta: call.meta, layout: call.layout, turns: call.turns)
            }
        } catch {
            Log.info("Rename failed: \(error.localizedDescription)")
        }
    }
}
