import AppKit
import AVKit
import Charts
import SwiftUI

/// "Мої дзвінки": every call with its transcript, player and statistics.
/// No @State anywhere: the Command Line Tools lack the SwiftUI macro plugin it needs.
@MainActor
final class CabinetWindowController {
    let library = CallLibrary()
    let player = PlayerModel()
    private var window: NSWindow?

    func show(callID: String? = nil) {
        library.reload()
        if let callID {
            library.selection = callID
        }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Мої дзвінки"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("Cabinet")
            window.contentView = NSHostingView(rootView: CabinetView(library: library, player: player))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// After a new transcript: refresh if the window is open.
    func refresh() {
        if window?.isVisible == true {
            library.reload()
        }
    }
}

enum CabinetTab: Hashable {
    case transcript, stats, people
}

/// One AVPlayer for the selected call; clicking a line seeks it.
@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var tab = CabinetTab.transcript
    @Published private(set) var url: URL?

    func load(_ url: URL?) {
        guard url != self.url else { return }
        player.pause()
        self.url = url
        player.replaceCurrentItem(with: url.map { AVPlayerItem(url: $0) })
    }

    /// Moves to a moment without starting playback (a search match).
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func play(from seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player.play()
    }
}

struct CabinetView: View {
    @ObservedObject var library: CallLibrary
    @ObservedObject var player: PlayerModel

    var body: some View {
        NavigationSplitView {
            CallList(library: library)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            Group {
                if let call = library.selected {
                    CallDetail(call: call, library: library, player: player)
                } else if library.selection == CallLibrary.calendarID {
                    CalendarView(library: library, events: CalendarEvents.shared)
                } else {
                    OverviewView(library: library)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 960, minHeight: 600)
    }
}

// MARK: - Sidebar

private struct CallList: View {
    @ObservedObject var library: CallLibrary

    var body: some View {
        List(selection: $library.selection) {
            Label("Огляд", systemImage: "chart.bar.xaxis")
                .tag(CallLibrary.overviewID)
            Label("Календар", systemImage: "calendar")
                .tag(CallLibrary.calendarID)
            ForEach(library.weeks) { week in
                Section(week.id) {
                    ForEach(week.calls) { call in
                        CallRow(call: call, snippet: library.snippet(for: call))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $library.query, placement: .sidebar, prompt: "Пошук у розмовах")
    }
}

private struct CallRow: View {
    let call: CallRecord
    /// The matching words while searching, shown instead of the date.
    var snippet: String?

    var body: some View {
        HStack(spacing: 10) {
            AppBadge(app: call.meta.app, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.title).fontWeight(.medium).lineLimit(1)
                Text(snippet ?? Format.dayTime(call.meta.started))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(Format.minutes(call.meta.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Overview

private struct OverviewView: View {
    @ObservedObject var library: CallLibrary

    var body: some View {
        let overview = library.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Огляд").font(.largeTitle.bold())
                    Spacer()
                    Picker("", selection: $library.period) {
                        ForEach(Period.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 440)
                }

                if overview.calls == 0 {
                    ContentUnavailableView("За цей період дзвінків немає", systemImage: "phone",
                                           description: Text("Обери довший період або запиши дзвінок."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    kpis(overview)
                    Card("Активність", subtitle: "години в дзвінках") {
                        activity(overview)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        Card("Програми", subtitle: "години") { apps(overview) }
                        Card("Дні тижня", subtitle: "кількість дзвінків") { weekdays(overview) }
                    }
                    if overview.trend.count > 1 {
                        HStack(alignment: .top, spacing: 16) {
                            Card("Твій темп", subtitle: "слів за хвилину, по дзвінках") { pace(overview) }
                            Card("Твоя частка розмови", subtitle: "%, по дзвінках") { share(overview) }
                        }
                    }
                    people(overview)
                }
            }
            .padding(24)
        }
    }

    private func kpis(_ overview: Overview) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            Tile(icon: "phone.fill", tint: .blue, title: "Дзвінків", value: "\(overview.calls)", note: "")
            Tile(icon: "clock.fill", tint: .indigo, title: "Годин", value: String(format: "%.1f", overview.hours),
                 note: "в середньому \(Int(overview.averageMinutes.rounded())) хв")
            Tile(icon: "person.wave.2.fill", tint: .teal, title: "Твоя частка розмови",
                 value: overview.myShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", note: "від усього сказаного")
            Tile(icon: "speedometer", tint: .orange, title: "Твій темп",
                 value: overview.myPace.map { "\($0) сл/хв" } ?? "—",
                 note: "комфортно \(Int(CallStats.paceRange.lowerBound))–\(Int(CallStats.paceRange.upperBound))")
            Tile(icon: "questionmark.bubble.fill", tint: .green, title: "Твоїх запитань",
                 value: "\(overview.questionsAsked)", note: "")
            Tile(icon: "bolt.horizontal.fill", tint: .pink, title: "Ти перебив",
                 value: "\(overview.interruptions)", note: "разів")
        }
    }

    private func activity(_ overview: Overview) -> some View {
        Chart(overview.buckets) { bucket in
            BarMark(x: .value("Період", bucket.id, unit: library.period.bucket),
                    y: .value("Години", bucket.hours))
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
        }
        .frame(height: 200)
    }

    private func apps(_ overview: Overview) -> some View {
        Chart(overview.apps) { app in
            BarMark(x: .value("Години", app.hours), y: .value("Програма", app.id))
                .foregroundStyle(AppStyle.color(app.id).gradient)
                .cornerRadius(3)
                .annotation(position: .trailing) {
                    Text("\(app.calls)").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .frame(height: max(80, CGFloat(overview.apps.count) * 34))
    }

    private func weekdays(_ overview: Overview) -> some View {
        Chart(overview.weekdays) { day in
            BarMark(x: .value("День", day.label), y: .value("Дзвінків", day.calls))
                .foregroundStyle(Color.purple.gradient)
                .cornerRadius(3)
        }
        .frame(height: 160)
    }

    private func pace(_ overview: Overview) -> some View {
        Chart {
            ForEach(overview.trend.filter { $0.pace != nil }) { point in
                LineMark(x: .value("Дата", point.id), y: .value("Слів/хв", point.pace ?? 0))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Дата", point.id), y: .value("Слів/хв", point.pace ?? 0))
            }
            RuleMark(y: .value("Нижня межа", CallStats.paceRange.lowerBound))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("Верхня межа", CallStats.paceRange.upperBound))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .foregroundStyle(.orange)
        .frame(height: 180)
    }

    private func share(_ overview: Overview) -> some View {
        Chart {
            ForEach(overview.trend.filter { $0.share != nil }) { point in
                LineMark(x: .value("Дата", point.id), y: .value("%", (point.share ?? 0) * 100))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Дата", point.id), y: .value("%", (point.share ?? 0) * 100))
            }
            RuleMark(y: .value("Порівну", 50))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .foregroundStyle(.teal)
        .chartYScale(domain: 0.0...100.0)
        .frame(height: 180)
    }

    @ViewBuilder
    private func people(_ overview: Overview) -> some View {
        Card("Люди", subtitle: "з ким найчастіше говориш") {
            if overview.people.isEmpty {
                Text("Тут з'являться люди, щойно ти впишеш їхні імена в дзвінку на вкладці «Учасники».")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(overview.people.prefix(10)) { person in
                        HStack(spacing: 10) {
                            Avatar(name: person.id, color: .orange, size: 26)
                            Text(person.id)
                            Spacer()
                            Text("\(person.calls) дзв. · \(Format.minutes(person.minutes * 60))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Call

private struct CallDetail: View {
    let call: CallRecord
    @ObservedObject var library: CallLibrary
    @ObservedObject var player: PlayerModel

    private var media: (url: URL, isVideo: Bool)? {
        let fm = FileManager.default
        if fm.fileExists(atPath: call.layout.video.path) { return (call.layout.video, true) }
        if fm.fileExists(atPath: call.layout.audio.path) { return (call.layout.audio, false) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let media {
                PlayerView(player: player.player)
                    .frame(height: media.isVideo ? 300 : 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            } else {
                Label("Відео й аудіо не знайдено: їх перемістили або видалили.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("", selection: $player.tab) {
                Text("Розшифровка").tag(CabinetTab.transcript)
                Text("Статистика").tag(CabinetTab.stats)
                Text("Учасники").tag(CabinetTab.people)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            switch player.tab {
            case .transcript: TranscriptView(call: call, player: player, query: library.query)
            case .stats: StatsView(call: call)
            case .people: PeopleView(call: call, library: library)
            }
        }
        .padding(24)
        .task(id: call.id) {
            player.load(media?.url)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AppBadge(app: call.meta.app, size: 46)
            VStack(alignment: .leading, spacing: 6) {
                Text(call.title).font(.title2.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Chip(icon: "calendar", text: Format.day(call.meta.started))
                    Chip(icon: "clock", text: Format.timeRange(call.meta.started, call.meta.duration))
                    Chip(icon: "timer", text: Format.minutes(call.meta.duration))
                    if call.speakers.count > 1 {
                        Chip(icon: "person.2", text: "\(call.speakers.count) учасн.")
                    }
                    if let calendar = call.meta.event?.calendar {
                        Chip(icon: "calendar.badge.checkmark", text: calendar)
                            .help("Назва дзвінка — з події в Календарі macOS")
                    }
                }
            }
            Spacer()
            Menu {
                Button("Відео й аудіо у Finder") { NSWorkspace.shared.open(call.layout.mediaFolder) }
                Button("Відкрити .txt") { NSWorkspace.shared.open(call.layout.transcript) }
                if call.layout.hasTracks {
                    Divider()
                    Button("Розшифрувати заново") { library.onReprocess(call.layout) }
                }
            } label: {
                Label("Дії", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private struct Turn: Identifiable {
    let id: Int
    let segment: Segment
}

private struct TranscriptView: View {
    let call: CallRecord
    @ObservedObject var player: PlayerModel
    /// The sidebar search: matches are highlighted and the first one is scrolled to.
    let query: String

    var body: some View {
        if call.pieces.isEmpty {
            // Calls transcribed before segments were kept: show the plain text.
            ScrollView {
                Text((try? String(contentsOf: call.layout.transcript, encoding: .utf8)) ?? "Розшифровки ще немає.")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            let turns = call.turns.enumerated().map { Turn(id: $0.offset, segment: $0.element) }
            let needle = query.trimmingCharacters(in: .whitespaces)
            let firstMatch = needle.isEmpty ? nil : turns.first(where: {
                $0.segment.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            })
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(turns) { item in
                            let turn = item.segment
                            let name = call.name(of: turn.speaker)
                            let color = Palette.color(for: turn.speaker, in: call.speakers)
                            HStack(alignment: .top, spacing: 12) {
                                Avatar(name: name, color: color, size: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                                        Button {
                                            player.play(from: turn.start)
                                        } label: {
                                            Label(Timecode.string(turn.start), systemImage: "play.fill")
                                                .font(.caption.monospacedDigit())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .help("Слухати з цього місця")
                                    }
                                    Text(Self.highlight(turn.text, needle))
                                        .textSelection(.enabled)
                                        .lineSpacing(2)
                                        .frame(maxWidth: 760, alignment: .leading)
                                }
                            }
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Opened from a search: straight to the first match, player cued there.
                .task(id: "\(call.id)|\(needle)") {
                    guard let firstMatch else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo(firstMatch.id, anchor: .center) }
                    player.seek(to: firstMatch.segment.start)
                }
            }
        }
    }

    private static func highlight(_ text: String, _ needle: String) -> AttributedString {
        var result = AttributedString(text)
        guard !needle.isEmpty else { return result }
        var from = result.startIndex
        while from < result.endIndex,
              let range = result[from...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = Color.yellow.opacity(0.35)
            from = range.upperBound
        }
        return result
    }
}

private struct StatsView: View {
    let call: CallRecord

    var body: some View {
        if let stats = call.stats {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card("Хто скільки говорив", subtitle: nil) { shares(stats) }
                    tiles(stats)
                    if stats.pace.count > 1 {
                        Card("Твій темп по хвилинах", subtitle: "слів за хвилину") { pace(stats) }
                    }
                }
                .padding(.vertical, 4)
            }
        } else {
            Text("Статистика є лише для дзвінків, розшифрованих новою версією. Меню «Дії» → «Розшифрувати заново», поки технічні файли ще не очищені.")
                .foregroundStyle(.secondary)
        }
    }

    private func shares(_ stats: CallStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(stats.shares) { share in
                        Rectangle()
                            .fill(Palette.color(for: share.id, in: call.speakers))
                            .frame(width: max(2, (geometry.size.width - CGFloat(stats.shares.count) * 2) * CGFloat(share.fraction)))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            ForEach(stats.shares) { share in
                HStack(spacing: 8) {
                    Circle().fill(Palette.color(for: share.id, in: call.speakers)).frame(width: 9, height: 9)
                    Text(call.name(of: share.id))
                    Spacer()
                    Text("\(Int((share.fraction * 100).rounded()))% · \(Format.minutes(share.seconds))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tiles(_ stats: CallStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            Tile(icon: "speedometer", tint: .orange, title: "Твій темп",
                 value: stats.myPace.map { "\($0) сл/хв" } ?? "—",
                 note: "комфортно \(Int(CallStats.paceRange.lowerBound))–\(Int(CallStats.paceRange.upperBound))")
            Tile(icon: "questionmark.bubble.fill", tint: .green, title: "Запитання",
                 value: "\(stats.questionsMine) / \(stats.questionsTheirs)", note: "ти поставив / тобі")
            Tile(icon: "bolt.horizontal.fill", tint: .pink, title: "Перебивання",
                 value: "\(stats.interruptedByMe) / \(stats.interruptedMe)", note: "ти перебив / тебе")
            Tile(icon: "hourglass", tint: .indigo, title: "Пауза перед відповіддю",
                 value: stats.responsePause.map { String(format: "%.1f с", $0) } ?? "—", note: "в середньому")
            Tile(icon: "text.bubble.fill", tint: .blue, title: "Найдовший монолог",
                 value: stats.longest.map { Format.minutes($0.seconds) } ?? "—",
                 note: stats.longest.map { "\(call.name(of: $0.speaker)), з \(Timecode.string($0.start))" } ?? "")
            Tile(icon: "exclamationmark.bubble.fill", tint: .red, title: "Слова-паразити",
                 value: "\(stats.fillers.reduce(0) { $0 + $1.count })",
                 note: stats.fillers.prefix(3).map { "«\($0.word)» \($0.count)" }.joined(separator: ", "))
        }
    }

    private func pace(_ stats: CallStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(stats.pace) { point in
                    LineMark(x: .value("Хвилина", point.minute), y: .value("Слів за хвилину", point.wpm))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.orange)
                    PointMark(x: .value("Хвилина", point.minute), y: .value("Слів за хвилину", point.wpm))
                        .foregroundStyle(CallStats.paceRange.contains(point.wpm) ? Color.orange : Color.red)
                }
                RuleMark(y: .value("Нижня межа", CallStats.paceRange.lowerBound))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                RuleMark(y: .value("Верхня межа", CallStats.paceRange.upperBound))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartXAxisLabel("хвилина дзвінка")
            .frame(height: 200)
            let outside = stats.pace.filter { !CallStats.paceRange.contains($0.wpm) }
            if !outside.isEmpty {
                Text("Поза комфортним темпом: " + outside.prefix(12)
                    .map { "\($0.minute) хв — \(Int($0.wpm))" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PeopleView: View {
    let call: CallRecord
    @ObservedObject var library: CallLibrary

    var body: some View {
        Form {
            Section {
                ForEach(call.speakers, id: \.self) { speaker in
                    HStack(spacing: 10) {
                        Avatar(name: call.name(of: speaker), color: Palette.color(for: speaker, in: call.speakers), size: 26)
                        TextField(speaker, text: Binding(
                            get: { call.meta.speakerNames?[speaker] ?? "" },
                            set: { library.rename(speaker, to: $0, in: call.id) }
                        ), prompt: Text("Ім'я"))
                        if (call.meta.recognized ?? []).contains(speaker) {
                            Text("впізнано за голосом")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Ім'я з попередніх дзвінків, де ти назвав цей голос. Виправ, якщо не так.")
                        }
                    }
                }
            } footer: {
                Text("Імена потрапляють у розшифровку цього дзвінка, у .txt і в «Огляд» → «Люди». «Співрозмовник 1, 2…» — здогадка за голосом. Rozmova запам'ятовує названі голоси й сама підписує їх у наступних дзвінках.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct Tile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint.gradient))
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct Chip: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct Avatar: View {
    let name: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color.gradient))
    }
}

/// A colored rounded square with a symbol for the call app.
struct AppBadge: View {
    let app: String
    let size: CGFloat

    var body: some View {
        Image(systemName: AppStyle.symbol(app))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27).fill(AppStyle.color(app).gradient))
    }
}

enum AppStyle {
    static func symbol(_ app: String) -> String {
        switch app {
        case "Zoom", "FaceTime", "Webex": return "video.fill"
        case "Chrome", "Safari", "Arc", "Firefox", "Edge", "Brave", "Opera": return "globe"
        case "Telegram": return "paperplane.fill"
        case "Slack": return "number"
        case "Teams": return "person.3.fill"
        case "Discord": return "gamecontroller.fill"
        case "WhatsApp", "Viber", "Skype": return "phone.fill"
        default: return "waveform"
        }
    }

    static func color(_ app: String) -> Color {
        switch app {
        case "Zoom", "Webex": return .blue
        case "FaceTime", "WhatsApp": return .green
        case "Chrome", "Safari", "Arc", "Firefox", "Edge", "Brave", "Opera": return .teal
        case "Telegram", "Skype": return .cyan
        case "Slack": return .purple
        case "Teams", "Viber": return .indigo
        case "Discord": return .indigo
        default: return .gray
        }
    }
}

// MARK: - Helpers

/// The system AVPlayerView with its usual controls. SwiftUI's VideoPlayer wraps the same class
/// but crashes in an app built with `swift build`.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

enum Palette {
    private static let others: [Color] = [.orange, .green, .purple, .pink, .teal, .brown]

    static func color(for speaker: String, in speakers: [String]) -> Color {
        if speaker == Transcriber.me { return .blue }
        let index = speakers.filter { $0 != Transcriber.me }.firstIndex(of: speaker) ?? 0
        return others[index % others.count]
    }
}

enum Format {
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "uk_UA")
        formatter.dateFormat = format
        return formatter
    }

    static func dayTime(_ date: Date) -> String {
        formatter("EEE, d MMM, HH:mm").string(from: date)
    }

    static func day(_ date: Date) -> String {
        formatter("EEEE, d MMMM yyyy").string(from: date)
    }

    static func timeRange(_ start: Date, _ duration: Double) -> String {
        let time = formatter("HH:mm")
        return "\(time.string(from: start)) – \(time.string(from: start.addingTimeInterval(duration)))"
    }

    static func minutes(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) с" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) хв" : "\(minutes / 60) год \(minutes % 60) хв"
    }
}
