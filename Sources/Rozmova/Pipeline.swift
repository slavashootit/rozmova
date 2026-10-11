import Foundation

/// After a call: the transcript (.txt) and the speech pieces for statistics, both in the call's
/// history folder. Also re-runs for an older call ("Обробити запис заново") while its separate
/// tracks are still there, and builds the .m4a / .mp4 if they are missing.
enum Pipeline {
    struct Result {
        let file: URL
        let note: String?
    }

    static func process(_ layout: Layout) async throws -> Result {
        if !FileManager.default.fileExists(atPath: layout.audio.path) {
            do {
                try await Mixdown.run(layout)
            } catch {
                Log.info("Mixdown failed: \(error.localizedDescription)")
            }
        }

        var meta = try SessionMeta.load(from: layout)
        if meta.event == nil, let link = await CalendarEvents.shared.link(forCallAt: meta.started, duration: meta.duration) {
            meta.event = link
            try meta.save(to: layout)
        }
        let result = try await Transcriber.transcribe(layout, language: meta.language, engine: Prefs.engine)
        try SegmentsFile.save(result.pieces, to: layout)
        try Transcript.write(meta: meta, layout: layout, turns: result.turns)
        return Result(file: layout.transcript, note: result.turns.isEmpty ? "Мови в записі не знайшлося." : nil)
    }
}
