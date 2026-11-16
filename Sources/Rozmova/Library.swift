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

    /// The event, else who was there, else the app: "Олексій, Максим" beats `Meet: "grz-torn-ecj"`.
    var title: String {
        if let event = meta.event?.title { return event }
        let people = speakers.filter { $0 != Transcriber.me }.map { name(of: $0) }
            .filter { !$0.hasPrefix(Transcriber.them) }
        let unique = people.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !unique.isEmpty {
            let shown = unique.prefix(3).joined(separator: ", ")
            return unique.count > 3 ? shown + " і ще \(unique.count - 3)" : shown
        }
        if meta.title?.hasPrefix("Meet:") == true { return "Зустріч у Meet" }
        return meta.displayTitle
    }

    /// Too short to be a conversation (a test, a mis-click): kept, but out of the numbers.
    var isShort: Bool { meta.duration < CallRecord.shortSeconds }
    static let shortSeconds = 60.0
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
        self.searchText = ([meta.displayTitle, meta.app] + (meta.speakerNames ?? [:]).values + pieces.map(\.text)).joined(separator: " ").lowercased()
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
    static let peopleID = "people"

    /// Everyone with voice samples, for the "Люди" page.
    @Published private(set) var people: [Person] = []

    @Published var query = ""
    @Published var selection: String? = CallLibrary.overviewID
    @Published var period = Period(rawValue: Prefs.period) ?? .all {
        didSet { Prefs.period = period.rawValue }
    }
    /// Any date in the month the calendar shows.
    @Published var month = Date()
    /// The day whose calls and meetings are listed under the calendar.
    @Published var day: Date? = Date()

    /// The "delete the recording" / "delete the whole call" questions for the selected call.
    @Published var askDeleteMedia = false
    @Published var askDeleteCall = false

    /// Set by AppDelegate: transcribe a call again (while its separate tracks still exist).
    var onReprocess: (Layout) -> Void = { _ in }

    var selected: CallRecord? { calls.first { $0.id == selection } }

    var overview: Overview { Overview(calls.filter { !$0.isShort }.map(\.summary), period: period) }

    /// How many calls are running through transcription now (set by the app).
    @Published var processing = 0
    @Published var showShort = false

    var shortCalls: [CallRecord] { calls.filter(\.isShort) }

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
        people = People.load()
        let pages = [Self.overviewID, Self.calendarID, Self.peopleID]
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

    /// While searching: the words around the first match, for the sidebar row.
    func snippet(for call: CallRecord) -> String? {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        for piece in call.pieces {
            guard let range = piece.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let text = piece.text
            let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
            return (start > text.startIndex ? "…" : "") + text[start..<end].trimmingCharacters(in: .whitespaces)
                + (end < text.endIndex ? "…" : "")
        }
        return nil
    }

    /// Calls that started on this day, earliest first.
    func calls(onDay day: Date) -> [CallRecord] {
        calls.filter { Calendar.current.isDate($0.meta.started, inSameDayAs: day) }
            .sorted { $0.meta.started < $1.meta.started }
    }

    var weeks: [WeekGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        // While searching everything is looked through; otherwise the short ones wait in their own group.
        let found = needle.isEmpty ? calls.filter { !$0.isShort } : calls.filter { $0.searchText.contains(needle) }
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

    /// Moves the recording (video, audio, separate tracks) to the Trash. The transcript,
    /// statistics and names stay in History, so the call keeps counting in the overview.
    func deleteMedia(of id: String) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        var call = calls[index]
        trashMedia(call.layout)
        call.meta.mediaDeleted = true
        calls[index] = call
        do {
            try call.meta.save(to: call.layout)
        } catch {
            Log.info("Saving \(id) after deleting its media failed: \(error.localizedDescription)")
        }
    }

    /// Moves everything about the call to the Trash: recording, transcript, statistics.
    func deleteCall(_ id: String) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        let layout = calls[index].layout
        trashMedia(layout)
        trash(layout.history)
        calls.remove(at: index)
        if selection == id {
            selection = Self.overviewID
        }
    }

    private func trashMedia(_ layout: Layout) {
        trash(layout.video)
        trash(layout.audio)
        trash(layout.raw)
        // The media folder is made for this one call: drop it once nothing visible is left.
        let fm = FileManager.default
        if layout.mediaFolder.lastPathComponent == layout.name,
           let left = try? fm.contentsOfDirectory(at: layout.mediaFolder, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles]), left.isEmpty {
            trash(layout.mediaFolder)
        }
    }

    private func trash(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
        } catch {
            Log.info("Moving \(url.lastPathComponent) to the Trash failed: \(error.localizedDescription)")
        }
    }

    /// "24 дзвінки з 11 жовт. 2026": everything History holds, whatever period is picked.
    var historyNote: String? {
        let real = calls.filter { !$0.isShort }
        guard let first = real.last?.meta.started else { return nil }
        let short = calls.count - real.count
        return "В історії \(Format.calls(real.count)) з \(Format.shortDay(first))"
            + (short > 0 ? " · ще \(short) коротких записів не в цифрах" : "")
    }

    /// Saves the name, rewrites the .txt with it and remembers the voice under that name.
    func rename(_ speaker: String, to name: String, in id: String) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        var call = calls[index]
        var names = call.meta.speakerNames ?? [:]
        names[speaker] = name.trimmingCharacters(in: .whitespaces)
        call.meta.speakerNames = names
        // Typed by you now, so it is no longer a guess and may teach later calls.
        call.meta.recognized?.removeAll { $0 == speaker }
        call.meta.suggested?[speaker] = nil
        calls[index] = call
        save(call)
        if speaker != Transcriber.me {
            People.assign(call: id, label: speaker, print: VoiceBook.loadPrints(call.layout)[speaker],
                          seconds: People.spoken(in: call.pieces)[speaker] ?? 0, name: names[speaker] ?? "")
            people = People.load()
        }
    }

    /// Names to offer for a voice of this call: the invited people first, then everyone you
    /// have named before; without the names this call already uses.
    func nameIdeas(for call: CallRecord) -> [String] {
        let used = Set((call.meta.speakerNames ?? [:]).values)
        var ideas: [String] = []
        let known = people.sorted { $0.samples.count > $1.samples.count }.map(\.name)
        for name in (call.meta.event?.attendees ?? []) + known
        where name != Transcriber.me && !used.contains(name) && !ideas.contains(name) {
            ideas.append(name)
        }
        return Array(ideas.prefix(12))
    }

    /// The person is called differently from now on: in every call and in the voice samples.
    /// Renaming to an existing name joins the two people.
    func renamePerson(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old, old != Transcriber.me, new != Transcriber.me else { return }
        for index in calls.indices {
            var call = calls[index]
            guard let names = call.meta.speakerNames, names.values.contains(old)
                    || (call.meta.suggested ?? [:]).values.contains(old) else { continue }
            call.meta.speakerNames = names.mapValues { $0 == old ? new : $0 }
            call.meta.suggested = call.meta.suggested?.mapValues { $0 == old ? new : $0 }
            calls[index] = call
            save(call)
        }
        People.rename(old, to: new)
        people = People.load()
    }

    /// This recording no longer teaches what the person sounds like; the call keeps its names.
    func removeSample(_ sample: VoiceSample) {
        People.assign(call: sample.call, label: sample.label, print: nil, seconds: 0, name: "")
        people = People.load()
    }

    /// "Yes, that is them": a guessed or offered name becomes a name you set.
    func confirm(_ speaker: String, in id: String) {
        guard let call = calls.first(where: { $0.id == id }) else { return }
        let name = call.meta.suggested?[speaker] ?? call.meta.speakerNames?[speaker] ?? ""
        guard !name.isEmpty else { return }
        rename(speaker, to: name, in: id)
    }

    /// Two labels were one person: everything `speaker` said goes to `target`.
    func merge(_ speaker: String, into target: String, in id: String) {
        guard let index = calls.firstIndex(where: { $0.id == id }), speaker != target else { return }
        var call = calls[index]
        let pieces = call.pieces.map { piece -> Segment in
            var piece = piece
            if piece.speaker == speaker { piece.speaker = target }
            return piece
        }
        call.meta.speakerNames?[speaker] = nil
        call.meta.recognized?.removeAll { $0 == speaker }
        call.meta.suggested?[speaker] = nil
        var prints = VoiceBook.loadPrints(call.layout)
        prints[speaker] = nil
        do {
            try SegmentsFile.save(pieces, to: call.layout)
            if !prints.isEmpty {
                try VoiceBook.save(prints, to: call.layout)
            }
        } catch {
            Log.info("Merging voices failed: \(error.localizedDescription)")
            return
        }
        People.assign(call: id, label: speaker, print: nil, seconds: 0, name: "")
        people = People.load()
        call = CallRecord(id: id, meta: call.meta, pieces: pieces)
        calls[index] = call
        save(call)
    }

    private func save(_ call: CallRecord) {
        do {
            try call.meta.save(to: call.layout)
            if !call.pieces.isEmpty {
                try Transcript.write(meta: call.meta, layout: call.layout, turns: call.turns)
            }
        } catch {
            Log.info("Saving \(call.id) failed: \(error.localizedDescription)")
        }
    }
}
