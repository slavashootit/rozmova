import Foundation

/// Numbers for one call, computed from the speech pieces. No AI: timing and counting only.
struct CallStats {
    struct Share: Identifiable {
        let id: String
        let seconds: Double
        let fraction: Double
    }

    struct PacePoint: Identifiable {
        let id: Int
        let minute: Int
        let wpm: Double
    }

    /// Comfortable conversational pace; outside it a minute is flagged.
    static let paceRange = 110.0...170.0

    let shares: [Share]
    let myPace: Int?
    let pace: [PacePoint]
    let questionsMine: Int
    let questionsTheirs: Int
    let longest: (speaker: String, seconds: Double, start: Double)?
    let interruptedByMe: Int
    let interruptedMe: Int
    let responsePause: Double?
    let fillers: [(word: String, count: Int)]

    init(pieces: [Segment]) {
        let me = Transcriber.me
        let mine = pieces.filter { $0.speaker == me }

        var seconds: [String: Double] = [:]
        for piece in pieces {
            seconds[piece.speaker, default: 0] += max(0, piece.end - piece.start)
        }
        let total = max(seconds.values.reduce(0, +), 1)
        shares = seconds.map { Share(id: $0.key, seconds: $0.value, fraction: $0.value / total) }
            .sorted { $0.seconds > $1.seconds }

        let myWords = mine.reduce(0) { $0 + Self.words($1.text).count }
        let mySeconds = seconds[me] ?? 0
        myPace = mySeconds >= 20 ? Int((Double(myWords) / mySeconds * 60).rounded()) : nil

        // Per minute of the call, only minutes where you spoke for at least 10 seconds.
        var minuteWords: [Int: Int] = [:]
        var minuteSeconds: [Int: Double] = [:]
        for piece in mine {
            let minute = Int(piece.start / 60)
            minuteWords[minute, default: 0] += Self.words(piece.text).count
            minuteSeconds[minute, default: 0] += max(0, piece.end - piece.start)
        }
        pace = minuteSeconds.keys.sorted().compactMap { minute in
            guard let spoken = minuteSeconds[minute], spoken >= 10 else { return nil }
            return PacePoint(id: minute, minute: minute, wpm: Double(minuteWords[minute] ?? 0) / spoken * 60)
        }

        questionsMine = mine.reduce(0) { $0 + $1.text.filter { $0 == "?" }.count }
        questionsTheirs = pieces.filter { $0.speaker != me }.reduce(0) { $0 + $1.text.filter { $0 == "?" }.count }

        let turns = Transcriber.merge(pieces)
        longest = turns.max { ($0.end - $0.start) < ($1.end - $1.start) }
            .map { ($0.speaker, $0.end - $0.start, $0.start) }

        // Someone starts while another speaker still has at least half a second to go.
        var byMe = 0
        var ofMe = 0
        let ordered = pieces.sorted { $0.start < $1.start }
        // Latest end so far per speaker: one pass instead of comparing every pair.
        var lastEnd: [String: Double] = [:]
        for piece in ordered {
            let othersTalking = lastEnd.contains { $0.key != piece.speaker && $0.value - piece.start > 0.5 }
            if othersTalking {
                if piece.speaker == me {
                    byMe += 1
                } else if let myEnd = lastEnd[me], myEnd - piece.start > 0.5 {
                    ofMe += 1
                }
            }
            lastEnd[piece.speaker] = max(lastEnd[piece.speaker] ?? 0, piece.end)
        }
        interruptedByMe = byMe
        interruptedMe = ofMe

        // How long you wait after someone else stops before you answer (gaps up to 10 s).
        var pauses: [Double] = []
        for (previous, next) in zip(ordered, ordered.dropFirst())
        where previous.speaker != me && next.speaker == me {
            let gap = next.start - previous.end
            if gap >= 0, gap <= 10 {
                pauses.append(gap)
            }
        }
        responsePause = pauses.isEmpty ? nil : pauses.reduce(0, +) / Double(pauses.count)

        let myText = " " + mine.map { Self.words($0.text).joined(separator: " ") }.joined(separator: " ") + " "
        fillers = Self.fillerWords.compactMap { word in
            let count = myText.components(separatedBy: " \(word) ").count - 1
            return count > 0 ? (word: word, count: count) : nil
        }
        .sorted { $0.count > $1.count }
    }

    /// Ukrainian filler words and sounds, matched as whole words in your speech.
    private static let fillerWords = [
        "ну", "типу", "короче", "коротше", "як би", "ніби", "значить", "в принципі", "так би мовити",
        "загалом", "е", "ее", "еее", "ем", "емм", "мм", "ммм",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’-")).inverted)
            .filter { !$0.isEmpty }
    }
}

/// What the overview needs from one call.
struct CallSummary {
    let started: Date
    let duration: Double
    let app: String
    let stats: CallStats?
    /// "Співрозмовник 1" → "Роман"
    let names: [String: String]
}

enum Period: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "Тиждень"
        case .month: return "Місяць"
        case .quarter: return "3 місяці"
        case .year: return "Рік"
        case .all: return "Увесь час"
        }
    }

    /// Bars in the activity chart: days for short periods, weeks, then months.
    var bucket: Calendar.Component {
        switch self {
        case .week, .month: return .day
        case .quarter: return .weekOfYear
        case .year, .all: return .month
        }
    }

    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: now)
        case .year: return calendar.date(byAdding: .year, value: -1, to: now)
        case .all: return nil
        }
    }
}

/// Totals and trends over a period, from timings and counts only.
struct Overview {
    struct Bucket: Identifiable {
        let id: Date
        let hours: Double
        let calls: Int
    }

    struct AppTime: Identifiable {
        let id: String
        let hours: Double
        let calls: Int
    }

    struct Weekday: Identifiable {
        let id: Int
        let label: String
        let calls: Int
    }

    struct TrendPoint: Identifiable {
        let id: Date
        let pace: Int?
        let share: Double?
    }

    struct Person: Identifiable {
        let id: String
        let calls: Int
        let minutes: Double
    }

    let calls: Int
    let hours: Double
    let averageMinutes: Double
    /// Your share of the talking, weighted by call length.
    let myShare: Double?
    let myPace: Int?
    let questionsAsked: Int
    let interruptions: Int
    let buckets: [Bucket]
    let apps: [AppTime]
    let weekdays: [Weekday]
    let trend: [TrendPoint]
    let people: [Person]

    static let weekdayLabels = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Нд"]

    init(_ all: [CallSummary], period: Period, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let from = period.start(now: now, calendar: calendar)
        let list = all.filter { from == nil || $0.started >= from! }.sorted { $0.started < $1.started }
        let me = "Я"

        calls = list.count
        hours = list.reduce(0) { $0 + $1.duration } / 3600
        averageMinutes = list.isEmpty ? 0 : hours * 60 / Double(list.count)

        let withStats = list.compactMap { call in call.stats.map { (call, $0) } }
        var shareSum = 0.0
        var shareWeight = 0.0
        var paceSum = 0.0
        var paceWeight = 0.0
        for (call, stats) in withStats {
            if let mine = stats.shares.first(where: { $0.id == me }) {
                shareSum += mine.fraction * call.duration
                shareWeight += call.duration
            }
            if let pace = stats.myPace {
                paceSum += Double(pace) * call.duration
                paceWeight += call.duration
            }
        }
        myShare = shareWeight > 0 ? shareSum / shareWeight : nil
        myPace = paceWeight > 0 ? Int((paceSum / paceWeight).rounded()) : nil
        questionsAsked = withStats.reduce(0) { $0 + $1.1.questionsMine }
        interruptions = withStats.reduce(0) { $0 + $1.1.interruptedByMe }

        // Activity: every bucket from the period start (or first call) to now, empty ones too.
        var buckets: [Bucket] = []
        let component = period.bucket
        if let first = from ?? list.first?.started,
           var cursor = calendar.dateInterval(of: component, for: first)?.start {
            while cursor <= now {
                guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
                let inside = list.filter { $0.started >= cursor && $0.started < next }
                buckets.append(Bucket(id: cursor, hours: inside.reduce(0) { $0 + $1.duration } / 3600,
                                      calls: inside.count))
                cursor = next
            }
        }
        self.buckets = buckets

        var apps: [String: (hours: Double, calls: Int)] = [:]
        for call in list {
            apps[call.app, default: (0, 0)].hours += call.duration / 3600
            apps[call.app, default: (0, 0)].calls += 1
        }
        self.apps = apps.map { AppTime(id: $0.key, hours: $0.value.hours, calls: $0.value.calls) }
            .sorted { $0.hours > $1.hours }

        var days = Array(repeating: 0, count: 7)
        for call in list {
            // Calendar weekday: 1 = Sunday … 7 = Saturday; shift so Monday is 0.
            days[(calendar.component(.weekday, from: call.started) + 5) % 7] += 1
        }
        weekdays = days.enumerated().map { Weekday(id: $0.offset, label: Self.weekdayLabels[$0.offset], calls: $0.element) }

        trend = withStats.map { call, stats in
            TrendPoint(id: call.started, pace: stats.myPace, share: stats.shares.first { $0.id == me }?.fraction)
        }

        // Only people you named in the dashboard; the numbered labels mean nothing across calls.
        var people: [String: (calls: Int, minutes: Double)] = [:]
        for (call, stats) in withStats {
            for (label, name) in call.names where label != me && !name.isEmpty {
                people[name, default: (0, 0)].calls += 1
                people[name, default: (0, 0)].minutes += (stats.shares.first { $0.id == label }?.seconds ?? 0) / 60
            }
        }
        self.people = people.map { Person(id: $0.key, calls: $0.value.calls, minutes: $0.value.minutes) }
            .sorted { $0.calls == $1.calls ? $0.minutes > $1.minutes : $0.calls > $1.calls }
    }
}
