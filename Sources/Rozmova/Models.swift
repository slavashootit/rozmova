import Foundation

/// One stretch of speech from one side of the call. Times are seconds from the start.
struct Segment: Codable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

/// Where one call's files live. Three places, one name ("Call_2026-10-11_21-15"):
///
///     <recordings>/Call_…/Call_….mp4, Call_….m4a        the media you keep and upload
///     ~/Library/Application Support/Rozmova/History/Call_…/
///         Call_….txt, meta.json, segments.json          transcript and data, kept forever
///     ~/Library/Application Support/Rozmova/Raw/Call_…/
///         mic.m4a, system.m4a, screen.mp4               separate tracks, cleaned after a while
struct Layout {
    let name: String
    let mediaFolder: URL

    init(mediaFolder: URL) {
        self.name = mediaFolder.lastPathComponent
        self.mediaFolder = mediaFolder
    }

    init(name: String, mediaFolder: URL) {
        self.name = name
        self.mediaFolder = mediaFolder
    }

    var video: URL { mediaFolder.appendingPathComponent("\(name).mp4") }
    var audio: URL { mediaFolder.appendingPathComponent("\(name).m4a") }

    var history: URL { Prefs.historyFolder.appendingPathComponent(name, isDirectory: true) }
    var transcript: URL { history.appendingPathComponent("\(name).txt") }
    var meta: URL { history.appendingPathComponent("meta.json") }
    /// Every piece of speech with its speaker and time, before merging into turns: the
    /// statistics are computed from it.
    var segments: URL { history.appendingPathComponent("segments.json") }

    var raw: URL { Prefs.rawFolder.appendingPathComponent(name, isDirectory: true) }
    var mic: URL { raw.appendingPathComponent("mic.m4a") }
    var system: URL { raw.appendingPathComponent("system.m4a") }
    /// Screen as captured, until Mixdown adds the sound and moves it to the media folder.
    var silentScreen: URL { raw.appendingPathComponent("screen.mp4") }

    /// Can be transcribed (again): the separate tracks have not been cleaned yet.
    var hasTracks: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: meta.path)
            && (fm.fileExists(atPath: mic.path) || fm.fileExists(atPath: system.path))
    }
}

/// meta.json in each call's history folder.
struct SessionMeta: Codable {
    var app: String
    var title: String?
    var started: Date
    var duration: Double
    var language: String
    var hasScreen: Bool
    /// Where the .mp4 / .m4a are; the recordings folder may change later.
    var mediaFolder: String?
    /// "Співрозмовник 1" → "Роман", set in the dashboard.
    var speakerNames: [String: String]?
    /// The macOS Calendar event the call happened in, matched by time.
    var event: EventLink?

    /// The calendar event names a call better than a window title like "Zoom Meeting".
    var displayTitle: String {
        event?.title ?? title ?? "Дзвінок у \(app)"
    }

    static func load(from layout: Layout) throws -> SessionMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionMeta.self, from: Data(contentsOf: layout.meta))
    }

    func save(to layout: Layout) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: layout.history, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: layout.meta, options: .atomic)
    }
}

/// A copy of the calendar event, so the call keeps its name even if the event is deleted.
struct EventLink: Codable, Equatable {
    var title: String
    var start: Date
    var end: Date
    var calendar: String?
}

enum SegmentsFile {
    static func load(_ layout: Layout) -> [Segment] {
        guard let data = try? Data(contentsOf: layout.segments) else { return [] }
        return (try? JSONDecoder().decode([Segment].self, from: data)) ?? []
    }

    static func save(_ segments: [Segment], to layout: Layout) throws {
        try JSONEncoder().encode(segments).write(to: layout.segments, options: .atomic)
    }
}

enum Timecode {
    /// 3725 -> "01:02:05"
    static func string(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// For the menu bar: "4:05" or "1:02:05".
    static func short(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
