import FluidAudio
import Foundation

/// Splits "everyone else" into Співрозмовник 1, 2… by voice: FluidAudio's offline pipeline
/// (pyannote segmentation, WeSpeaker voice prints, VBx clustering) on this Mac. It is a guess:
/// similar voices can merge, one voice can split. With a single voice the label stays plain.
enum Voices {
    struct Labeled {
        let segments: [Segment]
        /// Voice print (WeSpeaker embedding) per label: "Співрозмовник 1" or plain "Співрозмовник".
        let prints: [String: [Float]]
    }

    /// What the diarizer heard: a voice id per transcript piece and a print per voice id.
    private struct Split {
        let voices: [String]
        let prints: [String: [Float]]
    }

    private static func split(_ segments: [Segment], audio: URL) async -> Split? {
        guard !segments.isEmpty else { return nil }
        let turns: [TimedSpeakerSegment]
        let database: [String: [Float]]
        do {
            let manager = OfflineDiarizerManager()
            try await manager.prepareModels()
            let result = try await manager.process(audio)
            turns = result.segments
            database = result.speakerDatabase ?? [:]
        } catch {
            Log.info("Voice split failed: \(error.localizedDescription)")
            return nil
        }
        guard !turns.isEmpty else { return nil }

        // Each transcript piece goes to the voice that overlaps it most, or the nearest one.
        let voices = segments.map { segment -> String in
            var best: (id: String, score: Double)?
            for turn in turns {
                let start = Double(turn.startTimeSeconds)
                let end = Double(turn.endTimeSeconds)
                let overlap = min(segment.end, end) - max(segment.start, start)
                // Negative overlap is the gap; a small gap still beats a large one.
                if best == nil || overlap > best!.score {
                    best = (turn.speakerId, overlap)
                }
            }
            return best?.id ?? ""
        }
        var prints: [String: [Float]] = [:]
        for voice in Set(voices) {
            prints[voice] = database[voice] ?? averagePrint(of: voice, in: turns)
        }
        return Split(voices: voices, prints: prints)
    }

    static func label(_ segments: [Segment], audio: URL) async -> Labeled {
        guard let split = await split(segments, audio: audio) else { return Labeled(segments: segments, prints: [:]) }
        let voices = split.voices

        // Number voices in order of first appearance; ignore a split into just one voice.
        var numbers: [String: Int] = [:]
        for voice in voices where numbers[voice] == nil {
            numbers[voice] = numbers.count + 1
        }
        guard numbers.count > 1 else {
            let print = voices.first.flatMap { split.prints[$0] }
            return Labeled(segments: segments, prints: print.map { [Transcriber.them: $0] } ?? [:])
        }
        let labeled = zip(segments, voices).map { segment, voice in
            var labeled = segment
            labeled.speaker = "\(segment.speaker) \(numbers[voice] ?? 0)"
            return labeled
        }
        var byLabel: [String: [Float]] = [:]
        for (voice, number) in numbers {
            byLabel["\(Transcriber.them) \(number)"] = split.prints[voice]
        }
        return Labeled(segments: labeled, prints: byLabel)
    }

    struct Mine {
        let segments: [Segment]
        /// Prints of people found on the microphone besides you, by their new label.
        let prints: [String: [Float]]
        /// Your own voice print, when the microphone clearly held one voice.
        let myPrint: [Float]?
    }

    /// A voice needs this much speech on the microphone to count as a person, not noise.
    private static let personSeconds = 30.0

    /// The microphone track: usually only you. When others sit in the room with you (or the
    /// call plays through speakers), their voices become Співрозмовник N instead of "Я".
    /// That needs a sample of your voice from an earlier headphone call; without one
    /// everything on the microphone stays "Я", as before.
    static func splitMine(_ segments: [Segment], audio: URL, others: [String: [Float]]) async -> Mine {
        let unchanged = Mine(segments: segments, prints: [:], myPrint: nil)
        guard let split = await split(segments, audio: audio) else { return unchanged }
        var seconds: [String: Double] = [:]
        for (segment, voice) in zip(segments, split.voices) {
            seconds[voice, default: 0] += max(0, segment.end - segment.start)
        }
        let people = seconds.filter { $0.value >= personSeconds && split.prints[$0.key] != nil }.map(\.key)
        guard people.count > 1 else {
            // One voice: a clean sample of you, if there is enough of it.
            let only = people.first.flatMap { (seconds[$0] ?? 0) >= 60 ? split.prints[$0] : nil }
            return Mine(segments: segments, prints: [:], myPrint: only)
        }
        let mySamples = People.mine()
        guard !mySamples.isEmpty else { return unchanged }
        let closeness = people.map { voice -> (voice: String, distance: Float) in
            (voice, mySamples.map { VoiceBook.distance($0, split.prints[voice]!) }.min() ?? 2)
        }
        guard let me = closeness.min(by: { $0.distance < $1.distance }), me.distance < People.maybe else { return unchanged }

        // Everyone else: the same label as on the system track if it is the same voice
        // (speakers leaking into the microphone), otherwise the next free number.
        var next = (others.keys.compactMap { Int($0.split(separator: " ").last ?? "") }.max() ?? (others.isEmpty ? 0 : 1)) + 1
        var labels: [String: String] = [:]
        var prints: [String: [Float]] = [:]
        for voice in people.sorted(by: { (seconds[$0] ?? 0) > (seconds[$1] ?? 0) }) where voice != me.voice {
            let print = split.prints[voice]!
            if let same = others.min(by: { VoiceBook.distance($0.value, print) < VoiceBook.distance($1.value, print) }),
               VoiceBook.distance(same.value, print) < People.sameVoice {
                labels[voice] = same.key
            } else {
                let label = "\(Transcriber.them) \(next)"
                next += 1
                labels[voice] = label
                prints[label] = print
            }
        }
        let relabeled = zip(segments, split.voices).map { segment, voice -> Segment in
            var segment = segment
            if let label = labels[voice] { segment.speaker = label }
            return segment
        }
        return Mine(segments: relabeled, prints: prints, myPrint: nil)
    }

    /// When the diarizer gives no speaker database: the turns' prints, weighted by length.
    private static func averagePrint(of voice: String, in turns: [TimedSpeakerSegment]) -> [Float]? {
        let own = turns.filter { $0.speakerId == voice && !$0.embedding.isEmpty }
        guard let size = own.first?.embedding.count else { return nil }
        var sum = [Float](repeating: 0, count: size)
        for turn in own where turn.embedding.count == size {
            for index in 0..<size {
                sum[index] += turn.embedding[index] * max(turn.durationSeconds, 0.1)
            }
        }
        return sum
    }
}

/// The voice prints of one call (voices.json) and how far apart two prints are.
/// Who they belong to is decided in `People`.
enum VoiceBook {
    static func loadPrints(_ layout: Layout) -> [String: [Float]] {
        guard let data = try? Data(contentsOf: layout.voices) else { return [:] }
        return (try? JSONDecoder().decode([String: [Float]].self, from: data)) ?? [:]
    }

    static func save(_ prints: [String: [Float]], to layout: Layout) throws {
        try JSONEncoder().encode(prints).write(to: layout.voices, options: .atomic)
    }

    /// Cosine distance: 0 for the same direction, 1 for unrelated prints.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for index in 0..<min(a.count, b.count) {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 2 }
        return 1 - dot / (normA.squareRoot() * normB.squareRoot())
    }
}
