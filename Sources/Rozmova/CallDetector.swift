import AppKit
import CoreAudio

/// An app that holds the microphone. `bundleID` is the matched prefix for known apps, so helper
/// processes (Chrome Helper, WebKit GPU) count as their browser.
struct CallApp: Equatable {
    let bundleID: String
    let name: String
    let known: Bool
}

/// Treats "another app keeps the mic open" as a call. Works for any app (Zoom, Meet in a browser,
/// Slack, Telegram...) because it asks Core Audio which processes are capturing input right now.
@MainActor
final class CallDetector {
    var onCallStarted: ((CallApp) -> Void)?
    var onCallEnded: ((CallApp) -> Void)?
    private(set) var current: CallApp?

    /// The mic has to stay busy this long before it counts (skips quick voice searches).
    private let startDelay: TimeInterval = 5
    /// And free this long before the call is over (survives a headset switch).
    private let endGrace: TimeInterval = 10

    private var timer: Timer?
    private var firstSeen: [String: Date] = [:]
    private var lastSeen = Date()

    func start() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    /// Forget the current call without firing `onCallEnded` (used after "not a call").
    func reset() {
        current = nil
        firstSeen = [:]
    }

    private func poll() {
        let users = MicUsers.current()
        let now = Date()

        if let call = current {
            if users.contains(where: { $0.bundleID == call.bundleID }) {
                lastSeen = now
            } else if now.timeIntervalSince(lastSeen) >= endGrace {
                current = nil
                firstSeen = [:]
                Log.info("Call ended: \(call.name)")
                onCallEnded?(call)
            }
            return
        }

        let active = Set(users.map(\.bundleID))
        firstSeen = firstSeen.filter { active.contains($0.key) }
        for user in users {
            let since = firstSeen[user.bundleID] ?? now
            firstSeen[user.bundleID] = since
            if now.timeIntervalSince(since) >= startDelay {
                current = user
                lastSeen = now
                Log.info("Call started: \(user.name) (\(user.bundleID))")
                onCallStarted?(user)
                return
            }
        }
    }
}

/// Core Audio process objects (macOS 14+) tell which processes are capturing audio input.
enum MicUsers {
    static func current() -> [CallApp] {
        let me = getpid()
        let ignored = Prefs.ignoredApps
        var result: [CallApp] = []
        for object in processObjects() {
            guard read(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1 else { continue }
            let pid = read(object, kAudioProcessPropertyPID, pid_t(-1)) ?? -1
            guard pid != me else { continue }
            let bundleID = bundleIdentifier(object) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            guard let app = KnownApps.resolve(bundleID: bundleID, pid: pid),
                  !ignored.contains(app.bundleID),
                  !result.contains(where: { $0.bundleID == app.bundleID }) else { continue }
            result.append(app)
        }
        return result
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    private static func bundleIdentifier(_ object: AudioObjectID) -> String? {
        // Core Audio hands out a retained CFString.
        guard let unmanaged = read(object, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.none) ?? nil else {
            return nil
        }
        let string = unmanaged.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}

enum KnownApps {
    /// Bundle ID prefix -> name. A prefix also covers helper processes.
    private static let names: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"),
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("company.thebrowser", "Arc"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("com.operasoftware", "Opera"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("org.telegram", "Telegram"),
        ("com.microsoft.teams", "Teams"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.viber", "Viber"),
        ("com.cisco", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.skype", "Skype"),
    ]

    /// System processes that open the mic for something other than a call.
    private static let ignored = [
        "com.apple.corespeech", "com.apple.siri", "com.apple.assistant", "com.apple.speech",
        "com.apple.SpeechRecognitionCore", "com.apple.dictation", "com.apple.VoiceMemos",
        "com.apple.controlcenter", "com.apple.accessibility", "com.apple.audio",
    ]

    /// Dictation and voice-typing apps (Superwhisper, MacWhisper, Wispr Flow, VoiceInk...),
    /// matched by bundle ID or app name: they hold the mic, but they are not calls.
    private static let dictationHints = ["whisper", "wispr", "voiceink", "dictat", "diktat", "spokenly", "aqua voice"]

    /// nil means "not a call".
    static func resolve(bundleID: String, pid: pid_t) -> CallApp? {
        let lower = bundleID.lowercased()
        if ignored.contains(where: { lower.hasPrefix($0.lowercased()) }) { return nil }
        if let match = names.first(where: { lower.hasPrefix($0.prefix.lowercased()) }) {
            return CallApp(bundleID: match.prefix, name: match.name, known: true)
        }
        let running = NSRunningApplication(processIdentifier: pid)
        let name = running?.localizedName ?? ""
        let haystack = (lower + " " + name).lowercased()
        if dictationHints.contains(where: { haystack.contains($0) }) { return nil }
        let id = bundleID.isEmpty ? "pid.\(pid)" : bundleID
        return CallApp(bundleID: id, name: name.isEmpty ? id : name, known: false)
    }

    private static let browsers: Set<String> = ["Chrome", "Safari", "Arc", "Firefox", "Edge", "Brave", "Opera"]
    private static let meetingHints = ["meet", "zoom", "teams", "huddle", "call", "дзвінок", "jitsi", "whereby", "webex"]

    /// Best guess at the meeting name from the app's window titles (needs Screen Recording permission).
    /// For browsers only a tab that looks like a meeting counts, otherwise we'd name the call "Gmail".
    static func meetingTitle(for call: CallApp) -> String? {
        let prefix = call.bundleID.lowercased()
        let pids = Set(NSWorkspace.shared.runningApplications
            .filter { ($0.bundleIdentifier ?? "").lowercased().hasPrefix(prefix) }
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let titles = windows
            .filter { pids.contains(($0[kCGWindowOwnerPID as String] as? pid_t) ?? -1) }
            .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowName as String] as? String }
            .filter { !$0.isEmpty }
        let meeting = titles.first { title in
            meetingHints.contains { title.lowercased().contains($0) }
        }
        if browsers.contains(call.name) { return meeting }
        return meeting ?? titles.first
    }
}
