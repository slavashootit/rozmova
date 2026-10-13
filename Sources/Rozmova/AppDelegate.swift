import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let detector = CallDetector()
    private let notifier = Notifier()
    private let prompt = CallPrompt()
    private var session: RecordingSession?
    private var starting = false
    /// The call the "record?" prompt is about.
    private var pendingCall: CallApp?
    private var tick: Timer?
    /// Recordings are processed one at a time: speech recognition already uses the whole chip.
    private var processing: Task<Void, Never>?
    private var processingCount = 0
    private let settings = SettingsWindowController()
    private let cabinet = CabinetWindowController()
    private let updates = Updates()
    private var hotKey: HotKey?
    /// Online meetings already announced, so each gets one reminder.
    private var remindedMeetings: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Prefs.recordingsFolder, withIntermediateDirectories: true)
        setUpStatusItem()

        notifier.setUp()
        notifier.onOpen = { [weak self] url in self?.open(url) }
        cabinet.library.onReprocess = { [weak self] layout in self?.enqueue(layout) }
        Migration.run()
        prompt.onRecord = { [weak self] in self?.recordPendingCall() }
        prompt.onDismiss = { [weak self] in self?.pendingCall = nil }
        prompt.onNeverAsk = { [weak self] in self?.ignoreCall(self?.pendingCall) }

        detector.onCallStarted = { [weak self] call in self?.callStarted(call) }
        detector.onCallEnded = { [weak self] call in self?.callEnded(call) }
        detector.start()

        // Old technical files: now, then every 6 hours while the app sits in the menu bar.
        let days = Prefs.cleanupDays
        Task.detached(priority: .background) { Cleanup.run(olderThanDays: days) }
        let cleanupTimer = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            let days = Prefs.cleanupDays
            Task.detached(priority: .background) { Cleanup.run(olderThanDays: days) }
        }
        RunLoop.main.add(cleanupTimer, forMode: .common)

        if Prefs.engine == .parakeet {
            Task.detached(priority: .background) { await Parakeet.prefetch() }
        }

        applyHotKey()
        NotificationCenter.default.addObserver(forName: .rozmovaHotKeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHotKey() }
        }

        // A reminder shortly before online meetings from Calendar.
        let meetingTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.remindMeetings() }
        }
        RunLoop.main.add(meetingTimer, forMode: .common)

        // New releases: at launch, then once a day.
        updates.onFound = { [weak self] release in
            guard Prefs.announcedVersion != release.version else { return }
            Prefs.announcedVersion = release.version
            self?.notifier.post(title: "Вийшла Rozmova \(release.version)",
                                body: "У тебе \(Updates.current). Клікни, щоб відкрити сторінку завантаження.",
                                link: release.page)
        }
        Task { await updates.check() }
        let updateTimer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.updates.check() }
            }
        }
        RunLoop.main.add(updateTimer, forMode: .common)

        // `open -a Rozmova --args --demo-prompt` shows the prompt without a real call.
        if CommandLine.arguments.contains("--demo-prompt") {
            pendingCall = CallApp(bundleID: "us.zoom", name: "Zoom", known: true)
            prompt.show(call: pendingCall!, title: "Щотижневий синк команди")
        }

        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                Log.info("Microphone access denied")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        // Close the files properly, otherwise the last minutes of audio are lost.
        self.session = nil
        Task {
            await session.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Calls

    private func callStarted(_ call: CallApp) {
        updateStatus()
        guard session == nil, !starting else { return }
        switch Prefs.autoMode {
        case .off:
            return
        case .auto where call.known:
            startRecording(call: call)
        default:
            pendingCall = call
            prompt.show(call: call, title: CalendarEvents.shared.current()?.title ?? KnownApps.meetingTitle(for: call))
        }
    }

    private func callEnded(_ call: CallApp) {
        prompt.hide()
        pendingCall = nil
        if let session, session.autoStop {
            stopRecording()
        }
        updateStatus()
    }

    private func recordPendingCall() {
        startRecording(call: pendingCall ?? detector.current)
        pendingCall = nil
    }

    // MARK: - Recording

    /// `screen` nil follows the setting (and the prompt's checkbox, which changes it).
    private func startRecording(call: CallApp?, screen: Bool? = nil) {
        guard session == nil, !starting else { return }
        prompt.hide()
        starting = true
        updateStatus()
        let title = call.flatMap { KnownApps.meetingTitle(for: $0) }
        let newSession: RecordingSession
        do {
            // Started during a detected call: stop when that call ends. Otherwise only by hand.
            newSession = try RecordingSession(app: call?.name ?? "Запис", bundleID: call?.bundleID, title: title,
                                              screen: screen ?? Prefs.recordScreen, autoStop: call != nil)
        } catch {
            starting = false
            updateStatus()
            showError("Не вдалося створити теку для запису", error)
            return
        }
        newSession.onSystemCaptureFailure = { [weak self] error in
            self?.notifier.post(title: "Звук співрозмовника більше не пишеться",
                                body: "\(error.localizedDescription) Мікрофон пишеться далі.")
        }
        Task {
            do {
                try await newSession.start()
                session = newSession
                Log.info("Recording: \(newSession.folder.path)")
            } catch {
                try? FileManager.default.removeItem(at: newSession.folder)
                showError("Запис не почався", error, hint: """
                    Перевір дозволи в System Settings → Privacy & Security: «Microphone» і \
                    «Screen & System Audio Recording» мають бути увімкнені для Rozmova. \
                    Після зміни дозволу перезапусти програму.
                    """)
            }
            starting = false
            updateStatus()
        }
    }

    private func stopRecording() {
        guard let session else { return }
        self.session = nil
        updateStatus()
        Task {
            let meta = await session.stop()
            Log.info("Stopped after \(Int(meta.duration)) s")
            Prefs.lastRecording = session.folder
            // Seconds even for an hour: no re-encoding. Done before the "saved" notice, so the
            // folder it opens already has the .m4a and the .mp4 with sound.
            var body = "\(session.folder.lastPathComponent)\nРозшифровка прийде окремим сповіщенням."
            do {
                try await Mixdown.run(session.layout)
            } catch {
                Log.info("Mixdown failed: \(error.localizedDescription)")
                body += "\nСпільний аудіофайл не зібрався; окремі доріжки лежать у прихованій теці .raw."
            }
            notifier.post(title: "Запис збережено", body: body, file: session.folder)
            enqueue(session.layout)
        }
    }

    /// A transcript (it lives in History) opens in the dashboard; anything else in Finder.
    private func open(_ url: URL) {
        if url.path.hasPrefix(Prefs.historyFolder.path) {
            cabinet.show(callID: url.deletingLastPathComponent().lastPathComponent)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func enqueue(_ layout: Layout) {
        let previous = processing
        processingCount += 1
        updateStatus()
        processing = Task {
            await previous?.value
            do {
                let result = try await Pipeline.process(layout)
                let body = [layout.name, result.note].compactMap { $0 }.joined(separator: "\n")
                notifier.post(title: "Розшифровка готова", body: body, file: result.file)
            } catch {
                notifier.post(title: "Обробка не вдалася",
                              body: "\(layout.name): \(error.localizedDescription)", file: layout.mediaFolder)
            }
            cabinet.refresh()
            processingCount -= 1
            updateStatus()
        }
    }

    // MARK: - Shortcut, meetings

    private func applyHotKey() {
        hotKey?.unregister()
        hotKey = nil
        guard Prefs.hotKey else { return }
        hotKey = HotKey.record { [weak self] in self?.toggleRecording() }
    }

    private func toggleRecording() {
        if session != nil {
            stopRecording()
        } else {
            recordPendingCall()
        }
    }

    private func remindMeetings() {
        let calendar = CalendarEvents.shared
        guard Prefs.remindMeetings, session == nil, calendar.hasAccess else { return }
        for event in calendar.onlineStarting(within: 70) where !remindedMeetings.contains(event.id) {
            remindedMeetings.insert(event.id)
            let time = DateFormatter.localizedString(from: event.start, dateStyle: .none, timeStyle: .short)
            notifier.post(title: "Скоро: \(event.title)",
                          body: "Онлайн-зустріч о \(time). Клік — приєднатися; запис Rozmova запропонує, щойно почнеться дзвінок.",
                          link: event.onlineLink)
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatus()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if let session {
            symbol = "record.circle.fill"
            button.contentTintColor = .systemRed
            button.title = " " + Timecode.short(session.elapsed)
        } else {
            symbol = processingCount > 0 ? "text.bubble" : "waveform"
            button.contentTintColor = nil
            button.title = ""
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Rozmova")
        button.imagePosition = .imageLeading
    }

    private func statusLine() -> String {
        if let session {
            return "Запис · \(session.meta.app) · \(Timecode.short(session.elapsed))"
        }
        if starting { return "Починаю запис…" }
        if processingCount > 0 { return "Обробляю записів: \(processingCount)" }
        if let call = detector.current { return "Дзвінок: \(call.name)" }
        return "Чекаю на дзвінок"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: statusLine(), action: nil, keyEquivalent: ""))
        if let release = updates.available {
            add(to: menu, "⬆︎ Нова версія \(release.version) — завантажити", #selector(openUpdate))
        }
        if Prefs.engine == .groq, Groq.apiKey() == nil {
            add(to: menu, "⚠︎ Немає ключа Groq — відкрити налаштування", #selector(openSettings))
        }
        // The shortcut is shown next to what it does; it works system-wide through HotKey.
        let record: NSMenuItem
        if session != nil {
            record = add(to: menu, "Зупинити запис", #selector(stopClicked))
        } else {
            let audio = add(to: menu, "Записати звук", #selector(startAudioClicked))
            let screen = add(to: menu, "Записати звук і екран", #selector(startScreenClicked))
            record = Prefs.recordScreen ? screen : audio
        }
        if Prefs.hotKey {
            record.keyEquivalent = "r"
            record.keyEquivalentModifierMask = [.control, .option]
        }
        if let call = detector.current, session == nil {
            add(to: menu, "\(call.name) — не дзвінок, ігнорувати", #selector(ignoreClicked))
        }

        menu.addItem(.separator())
        if let last = Prefs.lastRecording, FileManager.default.fileExists(atPath: last.path) {
            add(to: menu, "Останній запис: \(last.lastPathComponent)", #selector(openLastRecording))
        }
        let dashboard = add(to: menu, "Мої дзвінки", #selector(openCabinet))
        dashboard.keyEquivalent = "d"
        add(to: menu, "Усі записи у Finder", #selector(openRecordings))
        add(to: menu, "Обробити запис заново…", #selector(reprocess))

        menu.addItem(.separator())
        let settingsItem = add(to: menu, "Налаштування…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        let quit = NSMenuItem(title: "Вийти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    @discardableResult
    private func add(to menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func startAudioClicked() {
        startRecording(call: detector.current, screen: false)
    }

    @objc private func startScreenClicked() {
        startRecording(call: detector.current, screen: true)
    }

    @objc private func stopClicked() {
        stopRecording()
    }

    @objc private func ignoreClicked() {
        ignoreCall(detector.current)
    }

    private func ignoreCall(_ call: CallApp?) {
        guard let call else { return }
        Prefs.ignoredApps = Prefs.ignoredApps + [call.bundleID]
        prompt.hide()
        pendingCall = nil
        detector.reset()
        updateStatus()
    }

    @objc private func openLastRecording() {
        guard let folder = Prefs.lastRecording else { return }
        NSWorkspace.shared.open(folder)
    }

    @objc private func openRecordings() {
        try? FileManager.default.createDirectory(at: Prefs.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Prefs.recordingsFolder)
    }

    @objc private func openUpdate() {
        if let page = updates.available?.page {
            NSWorkspace.shared.open(page)
        }
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func openCabinet() {
        cabinet.show()
    }

    @objc private func reprocess() {
        let panel = NSOpenPanel()
        panel.message = "Обери теку запису"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Prefs.recordingsFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let layout = Layout(mediaFolder: folder)
        guard layout.hasTracks else {
            showError("Не можу обробити цей запис", CocoaError(.fileNoSuchFile),
                      hint: "Обери теку конкретного дзвінка, наприклад «Call_2026-10-11_21-15». Якщо тека правильна, її технічні файли вже очищені, і розшифрувати заново не вийде.")
            return
        }
        enqueue(layout)
    }

    private func showError(_ title: String, _ error: Error, hint: String? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = [error.localizedDescription, hint].compactMap { $0 }.joined(separator: "\n\n")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
