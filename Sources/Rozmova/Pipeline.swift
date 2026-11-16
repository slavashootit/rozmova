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
        var pieces = result.pieces
        var prints = result.voices
        if !prints.isEmpty {
            let oldPrints = VoiceBook.loadPrints(layout)
            let oldNames = meta.speakerNames ?? [:]
            let oldRecognized = meta.recognized ?? []
            var names: [String: String] = [:]
            var recognized: [String] = []
            if oldPrints.isEmpty {
                names = oldNames
                recognized = oldRecognized
            } else {
                // Transcribed again: the voices are numbered anew, so names follow the voice,
                // not the number. "Я" and other labels without a print keep theirs.
                for (label, name) in oldNames where oldPrints[label] == nil {
                    names[label] = name
                }
                for (label, old) in People.carryOver(new: prints, old: oldPrints) {
                    guard let name = oldNames[old], !name.isEmpty else { continue }
                    names[label] = name
                    if oldRecognized.contains(old) {
                        recognized.append(label)
                    }
                }
            }

            // Voices you named in earlier calls, for the labels still without a name.
            let unnamed = prints.filter { (names[$0.key] ?? "").isEmpty }
            let taken = Set(names.filter { $0.key != Transcriber.me }.values.filter { !$0.isEmpty })
            let guesses = People.recognize(unnamed, skipping: layout.name, taken: taken)
            var suggested: [String: String] = [:]
            var owner: [String: String] = [:]
            for (label, guess) in guesses.sorted(by: { $0.value.distance < $1.value.distance }) {
                if !guess.sure {
                    suggested[label] = guess.name
                } else if let first = owner[guess.name] {
                    // One person split into two voices: fold the weaker one into the first.
                    pieces = pieces.map { piece in
                        var piece = piece
                        if piece.speaker == label { piece.speaker = first }
                        return piece
                    }
                    prints[label] = nil
                } else {
                    owner[guess.name] = label
                    names[label] = guess.name
                    recognized.append(label)
                }
            }

            try VoiceBook.save(prints, to: layout)
            meta.speakerNames = names.isEmpty ? nil : names
            meta.recognized = recognized.isEmpty ? nil : recognized
            meta.suggested = suggested.isEmpty ? nil : suggested
            try meta.save(to: layout)

            // The samples of this call are taken again from the new prints.
            People.forget(call: layout.name)
            let seconds = People.spoken(in: pieces)
            for (label, name) in names where !name.isEmpty && !recognized.contains(label) {
                People.assign(call: layout.name, label: label, print: prints[label],
                              seconds: seconds[label] ?? 0, name: name)
            }
        }
        try SegmentsFile.save(pieces, to: layout)
        let turns = Transcriber.merge(pieces)
        try Transcript.write(meta: meta, layout: layout, turns: turns)
        return Result(file: layout.transcript, note: turns.isEmpty ? "Мови в записі не знайшлося." : nil)
    }
}
