import FluidAudio
import Foundation

/// Splits "everyone else" into Співрозмовник 1, 2… by voice: FluidAudio's offline pipeline
/// (pyannote segmentation, WeSpeaker voice prints, VBx clustering) on this Mac. It is a guess:
/// similar voices can merge, one voice can split. With a single voice the label stays plain.
enum Voices {
    static func label(_ segments: [Segment], audio: URL) async -> [Segment] {
        guard !segments.isEmpty else { return segments }
        let turns: [TimedSpeakerSegment]
        do {
            let manager = OfflineDiarizerManager()
            try await manager.prepareModels()
            turns = try await manager.process(audio).segments
        } catch {
            Log.info("Voice split failed: \(error.localizedDescription)")
            return segments
        }
        guard !turns.isEmpty else { return segments }

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
        guard numbers.count > 1 else { return segments }
        return zip(segments, voices).map { segment, voice in
            var labeled = segment
            labeled.speaker = "\(segment.speaker) \(numbers[voice] ?? 0)"
            return labeled
        }
    }
}
