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
        if let window { DockPresence.show(window) }
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

    /// Counts playbacks, so a short sample does not pause something started after it.
    private var playback = 0

    func play(from seconds: Double) {
        playback += 1
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player.play()
    }

    /// A few seconds of a voice, to hear who it is.
    func sample(from seconds: Double) {
        play(from: seconds)
        let mine = playback
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.playback == mine else { return }
            self.player.pause()
        }
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
                } else if library.selection == CallLibrary.peopleID {
                    PeoplePage(library: library, player: player)
                } else {
                    OverviewView(library: library)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 960, minHeight: 600)
        .tint(Theme.accent)
    }
}

// MARK: - Sidebar

private struct CallList: View {
    @ObservedObject var library: CallLibrary

    var body: some View {
        List(selection: $library.selection) {
            if library.processing > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Розшифровую запис…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            Label("Огляд", systemImage: "chart.bar.xaxis")
                .tag(CallLibrary.overviewID)
            Label("Календар", systemImage: "calendar")
                .tag(CallLibrary.calendarID)
            Label("Люди", systemImage: "person.2")
                .tag(CallLibrary.peopleID)
            ForEach(library.weeks) { week in
                Section(week.id) {
                    ForEach(week.calls) { call in
                        CallRow(call: call, snippet: library.snippet(for: call))
                    }
                }
            }
            if library.query.trimmingCharacters(in: .whitespaces).isEmpty, !library.shortCalls.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $library.showShort) {
                        ForEach(library.shortCalls) { call in
                            CallRow(call: call, snippet: nil)
                        }
                    } label: {
                        Text("Короткі записи · \(library.shortCalls.count)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
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

/// Fades and lifts a block in when the page opens, one after another. Reduce Motion: no movement.
private struct Appear: ViewModifier {
    let shown: Bool
    let order: Int
    let reduce: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduce ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 14)
            .animation(reduce ? nil : .spring(response: 0.55, dampingFraction: 0.86).delay(Double(order) * 0.07), value: shown)
    }
}

@MainActor
private final class RevealModel: ObservableObject {
    @Published var shown = false
}

private struct OverviewView: View {
    @ObservedObject var library: CallLibrary
    @StateObject private var reveal = RevealModel()
    @Environment(\.accessibilityReduceMotion) private var reduce

    private func appear(_ order: Int) -> Appear {
        Appear(shown: reveal.shown, order: order, reduce: reduce)
    }

    /// 0 until the page has opened, then 1: bars grow from the baseline.
    private var grow: Double { reveal.shown || reduce ? 1 : 0 }

    /// Changes when the bars should move: the page opened, or another period was picked.
    private var motionKey: String { "\(reveal.shown)-\(library.period.rawValue)" }
    private var motion: Animation? { reduce ? nil : .smooth(duration: 0.6) }

    var body: some View {
        let overview = library.overview
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Огляд").font(.largeTitle.bold())
                        if let note = library.historyNote {
                            Text(note).font(.callout).foregroundStyle(.secondary)
                        }
                    }
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
                .modifier(appear(0))

                if overview.calls == 0 {
                    ContentUnavailableView("За цей період дзвінків немає", systemImage: "phone",
                                           description: Text("Обери довший період або запиши дзвінок."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    hero(overview).modifier(appear(1))
                    stats(overview).modifier(appear(2))
                    people(overview).modifier(appear(3))
                    HStack(alignment: .top, spacing: 16) {
                        Card("Програми", subtitle: "години") { apps(overview) }
                        Card("Дні тижня", subtitle: "кількість дзвінків") { weekdays(overview) }
                    }
                    .modifier(appear(4))
                    if overview.trend.count > 1 {
                        HStack(alignment: .top, spacing: 16) {
                            Card("Твій темп", subtitle: "слів за хвилину, по дзвінках") { pace(overview) }
                            Card("Твоя частка розмови", subtitle: "%, по дзвінках") { share(overview) }
                        }
                        .modifier(appear(5))
                    }
                }
            }
            .padding(28)
        }
        .onAppear { reveal.shown = true }
    }

    // MARK: Blocks

    /// One big number, and the activity that makes it.
    private func hero(_ overview: Overview) -> some View {
        let hours = String(format: "%.1f", overview.hours).replacingOccurrences(of: ".", with: ",")
        let note = "\(Format.calls(overview.calls)) · в середньому \(Int(overview.averageMinutes.rounded())) хв"
        return HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("У розмовах").font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hours)
                        .font(.system(size: 60, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("год").font(.title3).foregroundStyle(.secondary)
                }
                .animation(reduce ? nil : .snappy, value: hours)
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(reduce ? nil : .snappy, value: note)
            }
            .frame(width: 230, alignment: .leading)
            activity(overview)
        }
        .padding(22)
        .modifier(Surface(radius: 18))
    }

    private func activity(_ overview: Overview) -> some View {
        Chart(overview.buckets) { bucket in
            BarMark(x: .value("Період", bucket.id, unit: overview.bucketUnit),
                    y: .value("Години", bucket.hours * grow))
                .foregroundStyle(Theme.accent.gradient)
                .cornerRadius(4)
        }
        .chartYAxis(.hidden)
        .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
        .frame(height: 150)
        .animation(motion, value: motionKey)
    }

    /// The rest of the numbers: plain text on the page, no boxes.
    private func stats(_ overview: Overview) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24, alignment: .topLeading), count: 4),
                  alignment: .leading, spacing: 18) {
            Stat(title: "Твоя частка розмови",
                 value: overview.myShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                 note: "від усього сказаного", animated: !reduce)
            Stat(title: "Твій темп",
                 value: overview.myPace.map { "\($0) сл/хв" } ?? "—",
                 note: "комфортно \(Int(CallStats.paceRange.lowerBound))–\(Int(CallStats.paceRange.upperBound))", animated: !reduce)
            Stat(title: "Твоїх запитань", value: "\(overview.questionsAsked)", note: "", animated: !reduce)
            Stat(title: "Ти перебив", value: "\(overview.interruptions)", note: "разів", animated: !reduce)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func people(_ overview: Overview) -> some View {
        Card("Люди", subtitle: "з ким найчастіше говориш") {
            if overview.people.isEmpty {
                Text("Тут з'являться люди, щойно ти впишеш їхні імена в дзвінку на вкладці «Учасники».")
                    .foregroundStyle(.secondary)
            } else {
                let top = max(overview.people.map(\.minutes).max() ?? 1, 1)
                VStack(spacing: 10) {
                    ForEach(overview.people.prefix(8)) { person in
                        HStack(spacing: 12) {
                            Avatar(name: person.id, color: Theme.color(for: person.id), size: 28)
                            Text(person.id).frame(width: 110, alignment: .leading).lineLimit(1)
                            GeometryReader { box in
                                Capsule()
                                    .fill(Theme.color(for: person.id).gradient.opacity(0.85))
                                    .frame(width: max(6, box.size.width * CGFloat(person.minutes / top) * grow))
                                    .frame(maxHeight: .infinity, alignment: .center)
                                    .animation(motion, value: motionKey)
                            }
                            .frame(height: 10)
                            Text("\(person.calls) дзв. · \(Format.minutes(person.minutes * 60))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 150, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { library.selection = CallLibrary.peopleID }
                        .help("Відкрити «Люди»")
                    }
                }
            }
        }
    }

    private func apps(_ overview: Overview) -> some View {
        Chart(overview.apps) { app in
            BarMark(x: .value("Години", app.hours * grow), y: .value("Програма", app.id))
                .foregroundStyle(AppStyle.color(app.id).gradient)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text("\(app.calls)").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartXAxis(.hidden)
        .frame(height: max(80, CGFloat(overview.apps.count) * 34))
        .animation(motion, value: motionKey)
    }

    private func weekdays(_ overview: Overview) -> some View {
        Chart(overview.weekdays) { day in
            BarMark(x: .value("День", day.label), y: .value("Дзвінків", Double(day.calls) * grow))
                .foregroundStyle(Theme.accent.opacity(0.75).gradient)
                .cornerRadius(4)
        }
        .chartYAxis(.hidden)
        .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
        .frame(height: 160)
        .animation(motion, value: motionKey)
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
        .foregroundStyle(Theme.accent)
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
        .foregroundStyle(Theme.accent)
        .chartYScale(domain: 0.0...100.0)
        .frame(height: 180)
    }
}

/// A number with a caption, no box.
private struct Stat: View {
    let title: String
    let value: String
    let note: String
    let animated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(animated ? .snappy : nil, value: value)
            Text(note.isEmpty ? " " : note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            if !call.pieces.isEmpty {
                TalkStrip(call: call, player: player, canSeek: media != nil)
            }
            if let media {
                PlayerView(player: player.player)
                    .frame(height: media.isVideo ? 300 : 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            } else {
                Label(call.meta.mediaDeleted == true
                        ? "Запис видалено. Розшифровка, статистика й учасники збережені."
                        : "Запису немає на місці (переміщено або видалено). Розшифровка, статистика й учасники збережені.",
                      systemImage: "checkmark.circle")
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
            case .people: PeopleView(call: call, library: library, player: player)
            }
        }
        .padding(24)
        .task(id: call.id) {
            player.load(media?.url)
        }
        .confirmationDialog("Видалити запис цього дзвінка?", isPresented: $library.askDeleteMedia) {
            Button("Видалити запис", role: .destructive) {
                player.load(nil)
                library.deleteMedia(of: call.id)
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("Відео й аудіо потраплять у Смітник. Розшифровка, статистика й учасники залишаться.")
        }
        .confirmationDialog("Видалити дзвінок повністю?", isPresented: $library.askDeleteCall) {
            Button("Видалити все", role: .destructive) {
                player.load(nil)
                library.deleteCall(call.id)
            }
            Button("Скасувати", role: .cancel) {}
        } message: {
            Text("У Смітник потраплять і запис, і розшифровка зі статистикою: дзвінок зникне з «Огляду».")
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
                        Button { player.tab = .people } label: {
                            HStack(spacing: -7) {
                                ForEach(call.speakers.prefix(5), id: \.self) { speaker in
                                    Avatar(name: call.name(of: speaker),
                                           color: Palette.color(for: speaker, in: call.speakers), size: 22)
                                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                                }
                            }
                            .padding(.leading, 4)
                        }
                        .buttonStyle(.plain)
                        .help(call.speakers.map { call.name(of: $0) }.joined(separator: ", "))
                    }
                    if let calendar = call.meta.event?.calendar {
                        Chip(icon: "calendar.badge.checkmark", text: calendar)
                            .help("Назва дзвінка — з події в Календарі macOS")
                    }
                }
            }
            Spacer()
            Menu {
                if media != nil {
                    Button("Відео й аудіо у Finder") { NSWorkspace.shared.open(call.layout.mediaFolder) }
                }
                Button("Відкрити .txt") { NSWorkspace.shared.open(call.layout.transcript) }
                if !call.pieces.isEmpty {
                    Button("Скопіювати розшифровку") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(call.clipboardText, forType: .string)
                    }
                }
                if call.layout.hasTracks {
                    Divider()
                    Button("Розшифрувати заново") { library.onReprocess(call.layout) }
                }
                Divider()
                if media != nil || call.layout.hasTracks {
                    Button("Видалити запис (відео й аудіо)…") { library.askDeleteMedia = true }
                }
                Button("Видалити дзвінок повністю…", role: .destructive) { library.askDeleteCall = true }
            } label: {
                Label("Дії", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// Who spoke when, across the whole call. A click jumps the recording there (when it exists).
private struct TalkStrip: View {
    let call: CallRecord
    @ObservedObject var player: PlayerModel
    let canSeek: Bool

    var body: some View {
        let total = max(call.meta.duration, call.turns.last?.end ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                    ForEach(Array(call.turns.enumerated()), id: \.offset) { _, turn in
                        Rectangle()
                            .fill(Palette.color(for: turn.speaker, in: call.speakers))
                            .frame(width: max(1.5, box.size.width * (turn.end - turn.start) / total))
                            .offset(x: box.size.width * turn.start / total)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { point in
                    guard canSeek else { return }
                    player.play(from: total * Double(point.x / max(box.size.width, 1)))
                }
            }
            .frame(height: 12)
            HStack(spacing: 14) {
                ForEach(call.speakers, id: \.self) { speaker in
                    HStack(spacing: 5) {
                        Circle().fill(Palette.color(for: speaker, in: call.speakers)).frame(width: 7, height: 7)
                        Text(call.name(of: speaker)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
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
    @ObservedObject var player: PlayerModel

    /// Where this voice speaks longest: the best few seconds to recognize it by.
    private func longest(of speaker: String) -> Double? {
        call.turns.filter { $0.speaker == speaker }.max { ($0.end - $0.start) < ($1.end - $1.start) }?.start
    }

    /// An earlier voice of this call that already carries the same name.
    private func twin(of speaker: String) -> String? {
        let name = call.meta.speakerNames?[speaker] ?? ""
        guard !name.isEmpty, speaker != Transcriber.me else { return nil }
        return call.speakers.prefix { $0 != speaker }
            .first { $0 != Transcriber.me && call.meta.speakerNames?[$0] == name }
    }

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
                        if player.url != nil, let start = longest(of: speaker) {
                            Button { player.sample(from: start) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless)
                                .help("Послухати кілька секунд цього голосу")
                        }
                        if speaker != Transcriber.me, (call.meta.speakerNames?[speaker] ?? "").isEmpty {
                            let ideas = library.nameIdeas(for: call)
                            if !ideas.isEmpty {
                                Menu {
                                    ForEach(ideas, id: \.self) { name in
                                        Button(name) { library.rename(speaker, to: name, in: call.id) }
                                    }
                                } label: {
                                    Image(systemName: "person.crop.circle.badge.plus")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Обрати з учасників зустрічі та вже знайомих людей")
                            }
                        }
                        if let twin = twin(of: speaker) {
                            Button("Це одна людина — об'єднати") { library.merge(speaker, into: twin, in: call.id) }
                                .help("Усе сказане цим голосом перейде до «\(call.name(of: twin))» вище: одна людина, один рядок.")
                        } else if (call.meta.recognized ?? []).contains(speaker) {
                            Text("впізнано за голосом")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Так") { library.confirm(speaker, in: call.id) }
                                .help("Підтвердити: цей запис голосу допоможе впізнавати людину надалі. Якщо не так — просто виправ ім'я.")
                        } else if let guess = call.meta.suggested?[speaker],
                                  (call.meta.speakerNames?[speaker] ?? "").isEmpty {
                            Text("не впевнений")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Схоже на «\(guess)»?") { library.confirm(speaker, in: call.id) }
                                .help("Голос схожий, але не настільки, щоб підписати самому. Натисни, якщо це справді ця людина.")
                        }
                    }
                }
            } footer: {
                Text("Імена потрапляють у розшифровку цього дзвінка, у .txt і в «Огляд» → «Люди». Rozmova запам'ятовує голоси, які ти назвав або підтвердив, і підписує їх у наступних дзвінках лише тоді, коли певна. Якщо голос лише схожий — запропонує ім'я, а незнайомий лишить без імені.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - People

/// Everyone Rozmova knows by voice: which recordings taught it, with a way to fix mistakes.
private struct PeoplePage: View {
    @ObservedObject var library: CallLibrary
    @ObservedObject var player: PlayerModel

    private func askName(for person: Person) {
        let alert = NSAlert()
        alert.messageText = "Як називати «\(person.name)»?"
        alert.informativeText = "Ім'я зміниться в усіх дзвінках. Якщо вписати ім'я людини, яка вже є в списку, вони стануть однією."
        let field = NSTextField(string: person.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Зберегти")
        alert.addButton(withTitle: "Скасувати")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            library.renamePerson(person.name, to: field.stringValue)
        }
    }

    var body: some View {
        let others = library.people.filter { $0.name != Transcriber.me }
            .sorted { $0.samples.count == $1.samples.count ? $0.name < $1.name : $0.samples.count > $1.samples.count }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Люди").font(.largeTitle.bold())
                    Text("Голоси, які ти назвав або підтвердив. За ними Rozmova підписує учасників у нових дзвінках.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if others.isEmpty {
                    ContentUnavailableView("Ще нікого", systemImage: "person.2",
                                           description: Text("Назви співрозмовника у вкладці «Учасники» будь-якого дзвінка."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
                ForEach(others, id: \.name) { person in
                    Card(person.name, subtitle: "\(person.samples.count) зап. голосу") {
                        let samples = person.samples.sorted { $0.call > $1.call }
                        let open = library.openSamples.contains(person.name)
                        ForEach(open ? samples : Array(samples.prefix(3)), id: \.key) { sample in
                            sampleRow(sample)
                        }
                        if samples.count > 3 {
                            Button(open ? "Згорнути" : "Показати всі \(samples.count)") {
                                if open { library.openSamples.remove(person.name) } else { library.openSamples.insert(person.name) }
                            }
                            .buttonStyle(.link)
                        }
                        let together = library.calls(with: person.name)
                        if !together.isEmpty {
                            Divider().padding(.vertical, 2)
                            Text("Розмови · \(together.count)").font(.callout).foregroundStyle(.secondary)
                            ForEach(together.prefix(6)) { call in
                                Button {
                                    library.selection = call.id
                                } label: {
                                    HStack {
                                        Text(call.title).lineLimit(1)
                                        Spacer()
                                        Text(Format.dayTime(call.meta.started) + " · " + Format.minutes(call.meta.duration))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if together.count > 6 {
                                Text("і ще \(together.count - 6)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("Перейменувати…") { askName(for: person) }
                            if others.count > 1 {
                                Menu("Це та сама людина, що й…") {
                                    ForEach(others.filter { $0.name != person.name }, id: \.name) { other in
                                        Button(other.name) { library.renamePerson(person.name, to: other.name) }
                                    }
                                }
                                .fixedSize()
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                if let me = library.people.first(where: { $0.name == Transcriber.me }) {
                    Card("Мій голос", subtitle: "\(me.samples.count) зап.") {
                        Text("Зразки з дзвінків у навушниках. За ними Rozmova відрізняє тебе від людей, які сидять поруч і говорять у той самий мікрофон.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
    }

    private func sampleRow(_ sample: VoiceSample) -> some View {
        let call = library.calls.first { $0.id == sample.call }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(call?.title ?? "Дзвінок видалено")
                Text((call.map { Format.dayTime($0.meta.started) + " · " } ?? "") + "говорив(ла) " + Format.minutes(sample.seconds))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if call != nil {
                Button("Відкрити") {
                    player.tab = .people
                    library.selection = sample.call
                }
                .help("Відкрити дзвінок на вкладці «Учасники»: там голос можна послухати")
            }
            Button { library.removeSample(sample) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Не вчитися на цьому записі: якщо тут підписано не ту людину")
        }
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Surface(radius: 16))
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
        .modifier(Surface(radius: 14))
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

/// One accent (the teal of the icon) and a calm surface: blocks are told apart by tone and
/// air, not by outlines.
enum Theme {
    static let accent = Color(red: 0.13, green: 0.66, blue: 0.53)
    private static let people: [Color] = [
        Color(red: 0.13, green: 0.66, blue: 0.53), .orange, .indigo, .pink, .cyan, .yellow, .purple, .mint,
    ]

    /// The same person always gets the same colour.
    static func color(for name: String) -> Color {
        // FNV-1a: close names (Артем, Таня) still land on different colours.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return people[Int(hash % UInt64(people.count))]
    }
}

/// A block tone one step off the window background; no border.
struct Surface: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.045)))
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

    static func shortDay(_ date: Date) -> String {
        formatter("d MMM yyyy").string(from: date)
    }

    /// 1 дзвінок, 2 дзвінки, 5 дзвінків, 21 дзвінок.
    static func calls(_ count: Int) -> String {
        let word: String
        switch (count % 10, count % 100) {
        case (_, 11...14): word = "дзвінків"
        case (1, _): word = "дзвінок"
        case (2...4, _): word = "дзвінки"
        default: word = "дзвінків"
        }
        return "\(count) \(word)"
    }

    static func minutes(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds)) с" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) хв" : "\(minutes / 60) год \(minutes % 60) хв"
    }
}
