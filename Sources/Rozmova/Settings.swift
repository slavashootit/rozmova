import AppKit
import ServiceManagement
import SwiftUI

/// State behind the settings window; every change is written to Prefs (or Keychain) right away.
/// No @State anywhere: the Command Line Tools lack the SwiftUI macro plugin it needs.
@MainActor
final class SettingsModel: ObservableObject {
    /// True while reload() copies Prefs in, so side effects do not fire.
    private var loading = false

    @Published var folderPath = ""
    @Published var hasLastRecording = false
    @Published var recordScreen = true { didSet { if !loading { Prefs.recordScreen = recordScreen } } }
    @Published var cleanupDays = 14 {
        didSet {
            guard !loading else { return }
            Prefs.cleanupDays = cleanupDays
            Cleanup.run(olderThanDays: cleanupDays)
            refreshUsage()
        }
    }
    @Published var technicalUsage = ""
    @Published var splitVoices = true { didSet { if !loading { Prefs.splitVoices = splitVoices } } }
    @Published var autoMode = AutoMode.ask { didSet { if !loading { Prefs.autoMode = autoMode } } }
    @Published var ignoredApps: [String] = [] { didSet { if !loading { Prefs.ignoredApps = ignoredApps } } }
    @Published var launchAtLogin = false {
        didSet {
            guard !loading, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.info("launch at login failed: \(error)")
            }
        }
    }
    @Published var engine = SpeechEngine.parakeet {
        didSet {
            guard !loading else { return }
            Prefs.engine = engine
            if engine == .parakeet {
                Task.detached(priority: .background) { await Parakeet.prefetch() }
            }
        }
    }
    @Published var language = "uk" { didSet { if !loading { Prefs.language = language } } }
    @Published var groqModel = "" { didSet { if !loading { Prefs.groqModel = groqModel } } }
    @Published var groqKey = "" {
        didSet { if !loading { Keychain.set(groqKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.groqKey) } }
    }

    func reload() {
        loading = true
        defer { loading = false }
        folderPath = (Prefs.recordingsFolder.path as NSString).abbreviatingWithTildeInPath
        hasLastRecording = Prefs.lastRecording.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        recordScreen = Prefs.recordScreen
        cleanupDays = Prefs.cleanupDays
        splitVoices = Prefs.splitVoices
        refreshUsage()
        autoMode = Prefs.autoMode
        ignoredApps = Prefs.ignoredApps
        launchAtLogin = SMAppService.mainApp.status == .enabled
        engine = Prefs.engine
        language = Prefs.language
        groqModel = Prefs.groqModel
        groqKey = Keychain.get(Keychain.groqKey) ?? ""
    }

    func refreshUsage() {
        let usage = Cleanup.usage()
        let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
        technicalUsage = usage.calls == 0 ? "Порожньо" : "\(size), дзвінків: \(usage.calls)"
    }

    func cleanNow() {
        Cleanup.runNow()
        refreshUsage()
    }

    func showTechnicalFolder() {
        try? FileManager.default.createDirectory(at: Prefs.rawFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.rawFolder)
    }

    func showHistoryFolder() {
        try? FileManager.default.createDirectory(at: Prefs.historyFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.historyFolder)
    }

    func showRecordings() {
        try? FileManager.default.createDirectory(at: Prefs.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.recordingsFolder)
    }

    func showLastRecording() {
        guard let folder = Prefs.lastRecording else { return }
        NSWorkspace.shared.open(folder)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Куди складати записи. Можна обрати теку на зовнішньому диску."
        panel.prompt = "Обрати"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Prefs.recordingsFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Prefs.recordingsFolder = folder
        reload()
    }
}

@MainActor
final class SettingsWindowController {
    let model = SettingsModel()
    private var window: NSWindow?

    func show() {
        model.reload()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Налаштування Rozmova"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            RecordingsSettings(model: model)
                .tabItem { Label("Записи", systemImage: "folder") }
            CallSettings(model: model)
                .tabItem { Label("Дзвінки", systemImage: "phone") }
            SpeechSettings(model: model)
                .tabItem { Label("Розпізнавання", systemImage: "waveform") }
        }
        .padding(16)
        .frame(width: 560, height: 440)
    }
}

private struct Hint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecordingsSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Тека") {
                    Text(model.folderPath)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Показати у Finder") { model.showRecordings() }
                    Button("Змінити…") { model.chooseFolder() }
                    Spacer()
                    if model.hasLastRecording {
                        Button("Останній запис") { model.showLastRecording() }
                    }
                }
            } header: {
                Text("Де лежать записи")
            } footer: {
                Hint("""
                    Кожен дзвінок — тека «Call_2026-10-11_21-15» з двома файлами тієї ж назви: \
                    .mp4 — екран зі звуком, .m4a — аудіо обох сторін. Розшифровки й статистика \
                    живуть у програмі («Мої дзвінки»).
                    """)
            }
            Section {
                Toggle("Записувати екран", isOn: $model.recordScreen)
                Hint("30 кадрів/с, до 1920×1200, зі звуком розмови: до ~1,4 ГБ за годину, статичні слайди — менше.")
            }
            Section {
                LabeledContent("Зараз займають", value: model.technicalUsage)
                Picker("Видаляти старші за", selection: $model.cleanupDays) {
                    Text("1 тиждень").tag(7)
                    Text("2 тижні").tag(14)
                    Text("1 місяць").tag(30)
                    Text("Не видаляти").tag(0)
                }
                HStack {
                    Button("Показати у Finder") { model.showTechnicalFolder() }
                    Spacer()
                    Button("Очистити зараз") { model.cleanNow() }
                }
            } header: {
                Text("Технічні файли")
            } footer: {
                Hint("""
                    Окремі доріжки кожного дзвінка. Потрібні лише для «Розшифрувати заново». \
                    Відео, аудіо, розшифровки й статистику очищення не чіпає ніколи.
                    """)
            }
            Section {
                HStack {
                    Text("Зберігаються завжди, кілька КБ на дзвінок.")
                    Spacer()
                    Button("Показати у Finder") { model.showHistoryFolder() }
                }
            } header: {
                Text("Розшифровки (.txt) і статистика")
            }
        }
        .formStyle(.grouped)
    }
}

private struct CallSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Picker("Коли починається дзвінок", selection: $model.autoMode) {
                Text("Питати віконцем").tag(AutoMode.ask)
                Text("Записувати одразу").tag(AutoMode.auto)
                Text("Нічого не робити").tag(AutoMode.off)
            }
            Toggle("Запускати при вході в систему", isOn: $model.launchAtLogin)
            Section {
                if model.ignoredApps.isEmpty {
                    Hint("Порожньо. Програма потрапляє сюди кнопкою «Це не дзвінок» у віконці.")
                }
                ForEach(model.ignoredApps, id: \.self) { id in
                    HStack {
                        Text(Self.name(for: id))
                        Spacer()
                        Button {
                            model.ignoredApps.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Не вважати дзвінком")
            } footer: {
                Hint("Програми для диктування (Superwhisper, MacWhisper, Wispr Flow…) пропускаються завжди.")
            }
        }
        .formStyle(.grouped)
    }

    private static func name(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}

private struct SpeechSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Picker("Рушій", selection: $model.engine) {
                Text("Parakeet — на Маці, безкоштовно").tag(SpeechEngine.parakeet)
                Text("Groq — у хмарі").tag(SpeechEngine.groq)
            }
            Picker("Мова розмов", selection: $model.language) {
                Text("Українська").tag("uk")
                Text("English").tag("en")
                Text("Визначати автоматично").tag("auto")
            }
            Toggle("Розрізняти співрозмовників за голосом", isOn: $model.splitVoices)
            Hint("«Співрозмовник 1», «Співрозмовник 2»… Це здогадка: схожі голоси можуть злитися. «Я» — завжди точно.")
            if model.engine == .parakeet {
                Hint("NVIDIA Parakeet на Neural Engine. Модель ~0,6 ГБ качається один раз, далі працює без інтернету.")
            } else {
                Section {
                    SecureField("Ключ Groq API", text: $model.groqKey, prompt: Text("gsk_…"))
                    Picker("Модель", selection: $model.groqModel) {
                        Text("whisper-large-v3 (точніша)").tag("whisper-large-v3")
                        Text("whisper-large-v3-turbo (дешевша)").tag("whisper-large-v3-turbo")
                    }
                } footer: {
                    Hint("Ключ: console.groq.com → API Keys. Зберігається в Keychain.")
                }
            }
        }
        .formStyle(.grouped)
    }
}
