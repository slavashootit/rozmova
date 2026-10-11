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
    /// Sidebar row that shows the overview instead of a call.
    static let overviewID = "overview"

    @Published var query = ""
    @Published var selection: String? = CallLibrary.overviewID
    @Published var period = Period.month

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
        if selection == nil || (selection != Self.overviewID && !calls.contains(where: { $0.id == selection })) {
            selection = Self.overviewID
        }
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
