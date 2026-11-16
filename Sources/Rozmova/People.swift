import Foundation

/// One stretch of a person's voice from one call: the voice print of the label you named.
struct VoiceSample: Codable {
    var call: String
    var label: String
    var print: [Float]
    /// How long that voice spoke in the call; short ones are too noisy to learn from.
    var seconds: Double
}

struct Person: Codable {
    var name: String
    var samples: [VoiceSample]
}

/// Who is who across calls: every person you named, with voice samples from several calls, in
/// ~/Library/Application Support/Rozmova/People/people.json. Only names you typed or confirmed
/// teach it; an automatic guess never does. A new voice is compared with all samples of each
/// person and gets a name only when one person is clearly the closest.
///
/// Distances are cosine distances between WeSpeaker prints. Measured on real calls: the same
/// person in different calls is 0.10–0.17 apart, different people 0.27 and more.
enum People {
    /// Below this, and clearly ahead of the next person: the name is set automatically.
    static let sure: Float = 0.22
    /// Below this the name is only offered ("Схоже на …?"); above it the voice stays unknown.
    static let maybe: Float = 0.32
    /// How much closer the best person must be than the second best to count as sure.
    static let margin: Float = 0.08
    /// Two prints of one voice in the same recording (after transcribing it again).
    static let sameVoice: Float = 0.25
    /// A sample of the same person further than this from their longest one is a wrong label.
    static let outlier: Float = 0.35
    /// Voices that spoke less than this do not become samples.
    static let minSeconds = 15.0

    struct Guess {
        let name: String
        let sure: Bool
        let distance: Float
    }

    private static let lock = NSLock()

    private static var file: URL {
        Prefs.appFolder.appendingPathComponent("People", isDirectory: true).appendingPathComponent("people.json")
    }

    // MARK: - Store

    /// The saved people; the first time, built from the names already typed in History.
    static func load() -> [Person] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private static func loadUnlocked() -> [Person] {
        if let data = try? Data(contentsOf: file), let people = try? JSONDecoder().decode([Person].self, from: data) {
            return people
        }
        let people = fromHistory()
        saveUnlocked(people)
        return people
    }

    private static func saveUnlocked(_ people: [Person]) {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(people).write(to: file, options: .atomic)
        } catch {
            Log.info("Saving people failed: \(error.localizedDescription)")
        }
    }

    /// The voice `label` of `call` now belongs to `name`; an empty name only forgets the sample.
    static func assign(call: String, label: String, print: [Float]?, seconds: Double, name: String) {
        lock.lock()
        defer { lock.unlock() }
        var people = loadUnlocked()
        for index in people.indices {
            people[index].samples.removeAll { $0.call == call && $0.label == label }
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let print, !print.isEmpty, seconds >= minSeconds {
            let sample = VoiceSample(call: call, label: label, print: print, seconds: seconds)
            if let index = people.firstIndex(where: { $0.name == name }) {
                people[index].samples.append(sample)
            } else {
                people.append(Person(name: name, samples: [sample]))
            }
        }
        people.removeAll { $0.samples.isEmpty }
        saveUnlocked(people)
    }

    /// Drops every sample taken from this call (before it is transcribed again).
    static func forget(call: String) {
        lock.lock()
        defer { lock.unlock() }
        var people = loadUnlocked()
        for index in people.indices {
            people[index].samples.removeAll { $0.call == call }
        }
        people.removeAll { $0.samples.isEmpty }
        saveUnlocked(people)
    }

    /// People from the names typed so far. Where one name sits on voices that do not sound
    /// alike (an old mix-up), only the samples close to the longest one are kept.
    private static func fromHistory() -> [Person] {
        var byName: [String: [VoiceSample]] = [:]
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: Prefs.historyFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for folder in folders {
            let layout = Layout(name: folder.lastPathComponent, mediaFolder: folder)
            guard let meta = try? SessionMeta.load(from: layout), let names = meta.speakerNames else { continue }
            let prints = VoiceBook.loadPrints(layout)
            guard !prints.isEmpty else { continue }
            let seconds = spoken(in: SegmentsFile.load(layout))
            for (label, name) in names where !name.isEmpty && !(meta.recognized ?? []).contains(label) {
                guard let print = prints[label], (seconds[label] ?? 0) >= minSeconds else { continue }
                byName[name, default: []].append(
                    VoiceSample(call: layout.name, label: label, print: print, seconds: seconds[label] ?? 0))
            }
        }
        return byName.map { name, samples in
            let anchor = samples.max { $0.seconds < $1.seconds }!
            return Person(name: name, samples: samples.filter {
                VoiceBook.distance($0.print, anchor.print) < outlier
            })
        }
        .sorted { $0.name < $1.name }
    }

    /// Seconds of speech per label.
    static func spoken(in pieces: [Segment]) -> [String: Double] {
        var seconds: [String: Double] = [:]
        for piece in pieces {
            seconds[piece.speaker, default: 0] += max(0, piece.end - piece.start)
        }
        return seconds
    }

    // MARK: - Matching

    /// Who each voice of a call sounds like. `taken` are names already set in this call: they
    /// are never offered to another voice. Two voices can come back with the same name only
    /// when both are sure: then one person was split in two and the caller merges them.
    static func recognize(_ prints: [String: [Float]], skipping call: String, taken: Set<String>) -> [String: Guess] {
        let people = load()
        var found: [(label: String, guess: Guess)] = []
        for (label, print) in prints {
            let scores = people.compactMap { person -> (name: String, distance: Float)? in
                guard !taken.contains(person.name) else { return nil }
                let distances = person.samples
                    .filter { $0.call != call && $0.print.count == print.count }
                    .map { VoiceBook.distance(print, $0.print) }
                    .sorted()
                guard let nearest = distances.first else { return nil }
                // With several samples one odd recording must not decide alone.
                return (person.name, distances.count > 2 ? (distances[0] + distances[1]) / 2 : nearest)
            }
            .sorted { $0.distance < $1.distance }
            guard let best = scores.first, best.distance < maybe else { continue }
            let gap = scores.count > 1 ? scores[1].distance - best.distance : 1
            found.append((label, Guess(name: best.name, sure: best.distance < sure && gap >= margin,
                                       distance: best.distance)))
        }
        var result: [String: Guess] = [:]
        for item in found.sorted(by: { $0.guess.distance < $1.guess.distance }) {
            let repeated = result.values.contains { $0.name == item.guess.name }
            // A weaker voice may share a name only as a sure split of the same person.
            if repeated, !(item.guess.sure && result.values.contains { $0.name == item.guess.name && $0.sure }) {
                continue
            }
            result[item.label] = item.guess
        }
        return result
    }

    /// After transcribing a call again the voices are numbered anew: which new label is which
    /// old one, by voice. One to one, closest first.
    static func carryOver(new: [String: [Float]], old: [String: [Float]]) -> [String: String] {
        var pairs: [(new: String, old: String, distance: Float)] = []
        for (newLabel, newPrint) in new {
            for (oldLabel, oldPrint) in old where oldPrint.count == newPrint.count {
                pairs.append((newLabel, oldLabel, VoiceBook.distance(newPrint, oldPrint)))
            }
        }
        var result: [String: String] = [:]
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) where pair.distance < sameVoice {
            guard result[pair.new] == nil, !result.values.contains(pair.old) else { continue }
            result[pair.new] = pair.old
        }
        return result
    }
}
