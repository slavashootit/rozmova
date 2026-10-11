import Foundation

/// Speech-to-text for one recording. Each side is transcribed separately, so "who said it"
/// comes for free: the mic is you, system audio is everyone else (then split by voice).
enum Transcriber {
    static let me = "Я"
    static let them = "Співрозмовник"

    struct Result {
        /// Every recognized piece with its speaker, in time order: what the statistics use.
        let pieces: [Segment]
        /// Pieces merged into speaker turns: what the transcript shows.
        let turns: [Segment]
    }

    static func transcribe(_ layout: Layout, language: String, engine: SpeechEngine) async throws -> Result {
        var mine: [Segment] = []
        var theirs: [Segment] = []
        do {
            for (audio, speaker) in [(layout.mic, me), (layout.system, them)] {
                guard FileManager.default.fileExists(atPath: audio.path) else { continue }
                let raw: [Segment]
                switch engine {
                case .parakeet: raw = try await Parakeet.transcribe(audio, language: language)
                case .groq: raw = try await Groq.transcribe(audio, language: language)
                }
                let segments = clean(raw, speaker: speaker)
                if speaker == me { mine = segments } else { theirs = segments }
            }
        } catch {
            await Parakeet.unload()
            throw error
        }
        // The model holds a lot of memory; the app idles in the menu bar until the next call.
        await Parakeet.unload()
        if Prefs.splitVoices {
            theirs = await Voices.label(theirs, audio: layout.system)
        }
        let pieces = (removeEcho(mine, heard: theirs) + theirs).sorted { $0.start < $1.start }
        return Result(pieces: pieces, turns: merge(pieces))
    }

    /// Drops empty and invented phrases, collapses loops, labels the speaker.
    private static func clean(_ segments: [Segment], speaker: String) -> [Segment] {
        var result: [Segment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let text = segment.text.replacingOccurrences(of: "\u{FFFD}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isHallucination(text) else { continue }
            // Whisper sometimes loops on one phrase; keep the first.
            if let last = result.last, last.text == text, segment.start - last.end < 5 { continue }
            result.append(Segment(start: segment.start, end: segment.end, speaker: speaker, text: text))
        }
        return result
    }

    /// Phrases Whisper invents on silence or music (learned from subtitled videos).
    private static let phantomPhrases = [
        "дякую за перегляд", "субтитри створ", "субтитри зроб", "редактор субтитр", "субтитры сдела",
        "субтитры созда", "продолжение следует", "спасибо за просмотр", "amara.org",
        "thank you for watching", "thanks for watching",
    ]
    /// Whole-segment only: "музика" alone is a phantom, a sentence about music is not.
    private static let phantomWords: Set<String> = ["музика", "музыка", "music", "оплески", "applause", "сміх", "laughter"]

    private static func isHallucination(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(.symbols))
        if normalized.isEmpty || phantomWords.contains(normalized) { return true }
        return normalized.count < 80 && phantomPhrases.contains { normalized.contains($0) }
    }

    // MARK: - Cleanup

    /// On speakers instead of headphones the mic hears the other side too. A mic segment that
    /// repeats words the system track has at the same moment is that echo, not you.
    private static func removeEcho(_ mine: [Segment], heard theirs: [Segment]) -> [Segment] {
        mine.filter { segment in
            let words = wordSet(segment.text)
            guard words.count >= 3 else { return true }
            let overlapping = theirs.filter { $0.end >= segment.start - 2 && $0.start <= segment.end + 2 }
            guard !overlapping.isEmpty else { return true }
            let heard = overlapping.reduce(into: Set<String>()) { $0.formUnion(wordSet($1.text)) }
            let shared = Double(words.intersection(heard).count) / Double(words.count)
            return shared < 0.6
        }
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 1 })
    }

    /// Time order; consecutive pieces from the same speaker become one turn.
    static func merge(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.speaker == segment.speaker,
               segment.start - last.end < 2, last.text.count + segment.text.count < 800 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
