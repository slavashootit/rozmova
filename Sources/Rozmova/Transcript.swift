import Foundation

/// The .txt transcript: a short header, then one line per turn, "[time] who: what".
/// "Я" is certain (your mic); "Співрозмовник 1, 2…" are guessed by voice, or renamed by you.
enum Transcript {
    static func text(meta: SessionMeta, name: String, turns: [Segment]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var header = "\(name)\n\(formatter.string(from: meta.started)) · \(meta.app)"
        if let title = meta.title, !title.isEmpty, title != meta.app {
            header += " · \(title)"
        }
        header += " · \(Int((meta.duration / 60).rounded())) хв"
        let names = meta.speakerNames ?? [:]
        let lines = turns.map { "[\(Timecode.string($0.start))] \(names[$0.speaker] ?? $0.speaker): \($0.text)" }
        let body = lines.isEmpty ? "Мови в записі не знайшлося." : lines.joined(separator: "\n\n")
        return header + "\n\n" + body + "\n"
    }

    static func write(meta: SessionMeta, layout: Layout, turns: [Segment]) throws {
        try text(meta: meta, name: layout.name, turns: turns)
            .write(to: layout.transcript, atomically: true, encoding: .utf8)
    }
}
