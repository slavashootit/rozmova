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

    static func label(_ segments: [Segment], audio: URL) async -> Labeled {
        guard !segments.isEmpty else { return Labeled(segments: segments, prints: [:]) }
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
            return Labeled(segments: segments, prints: [:])
        }
        guard !turns.isEmpty else { return Labeled(segments: segments, prints: [:]) }

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

        // Number voices in order of first appearance; ignore a split into just one voice.
        var numbers: [String: Int] = [:]
        for voice in voices where numbers[voice] == nil {
            numbers[voice] = numbers.count + 1
        }
        let prints = { (voice: String) -> [Float]? in database[voice] ?? averagePrint(of: voice, in: turns) }
        guard numbers.count > 1 else {
            let print = voices.first.flatMap(prints)
            return Labeled(segments: segments, prints: print.map { [Transcriber.them: $0] } ?? [:])
        }
        let labeled = zip(segments, voices).map { segment, voice in
            var labeled = segment
            labeled.speaker = "\(segment.speaker) \(numbers[voice] ?? 0)"
            return labeled
        }
        var byLabel: [String: [Float]] = [:]
        for (voice, number) in numbers {
            byLabel["\(Transcriber.them) \(number)"] = prints(voice)
        }
        return Labeled(segments: labeled, prints: byLabel)
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

/// Who is who across calls. When you name "Співрозмовник 2" in one call, that voice print is
/// remembered with the name, and a later call with a close enough voice gets the same name.
/// A guess like the voice split itself; a name you type always wins.
enum VoiceBook {
    /// Cosine distance below which two prints count as one person. Stricter than the diarizer's
    /// in-call 0.65, since microphones and rooms differ between calls.
    static let threshold: Float = 0.5

    static func loadPrints(_ layout: Layout) -> [String: [Float]] {
        guard let data = try? Data(contentsOf: layout.voices) else { return [:] }
        return (try? JSONDecoder().decode([String: [Float]].self, from: data)) ?? [:]
    }

    static func save(_ prints: [String: [Float]], to layout: Layout) throws {
        try JSONEncoder().encode(prints).write(to: layout.voices, options: .atomic)
    }

    /// Names for this call's voices, learned from every other call where you typed a name.
    static func recognize(_ prints: [String: [Float]], skipping call: String) -> [String: String] {
        guard !prints.isEmpty else { return [:] }
        var known: [(name: String, print: [Float])] = []
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Prefs.historyFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in folders where folder.lastPathComponent != call {
            let layout = Layout(name: folder.lastPathComponent, mediaFolder: folder)
            guard let meta = try? SessionMeta.load(from: layout), let names = meta.speakerNames else { continue }
            let saved = loadPrints(layout)
            // Only names you typed: an automatic guess must not teach the next guess.
            for (label, name) in names where !name.isEmpty && !(meta.recognized ?? []).contains(label) {
                if let print = saved[label] {
                    known.append((name, print))
                }
            }
        }

        var pairs: [(label: String, name: String, distance: Float)] = []
        for (label, print) in prints {
            for person in known where person.print.count == print.count {
                pairs.append((label, person.name, distance(print, person.print)))
            }
        }
        // Closest pairs first; one name per voice and one voice per name.
        var result: [String: String] = [:]
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) where pair.distance < threshold {
            guard result[pair.label] == nil, !result.values.contains(pair.name) else { continue }
            result[pair.label] = pair.name
        }
        return result
    }

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
