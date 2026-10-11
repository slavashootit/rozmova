import Foundation

/// What to do when a call starts.
enum AutoMode: String {
    case ask    // floating prompt with a "Record" button
    case auto   // start right away (known call apps only; unknown ones still ask)
    case off
}

/// Who turns speech into text.
enum SpeechEngine: String {
    case parakeet   // NVIDIA Parakeet on this Mac, free
    case groq       // Groq cloud API, needs a key
}

enum Prefs {
    private static let defaults = UserDefaults.standard

    static var autoMode: AutoMode {
        get { AutoMode(rawValue: defaults.string(forKey: "autoMode") ?? "") ?? .ask }
        set { defaults.set(newValue.rawValue, forKey: "autoMode") }
    }

    static var recordScreen: Bool {
        get { defaults.object(forKey: "recordScreen") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "recordScreen") }
    }

    /// Language code: "uk", "en" or "auto".
    static var language: String {
        get { defaults.string(forKey: "language") ?? "uk" }
        set { defaults.set(newValue, forKey: "language") }
    }

    /// Bundle IDs the user marked as "not a call" (dictation apps and the like).
    static var ignoredApps: [String] {
        get { defaults.stringArray(forKey: "ignoredApps") ?? [] }
        set { defaults.set(newValue, forKey: "ignoredApps") }
    }

    static var recordingsFolder: URL {
        get {
            if let path = defaults.string(forKey: "recordingsFolder") {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documents.appendingPathComponent("Calls", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: "recordingsFolder") }
    }

    /// Folder of the latest recording, for "Останній запис" in the menu.
    static var lastRecording: URL? {
        get { defaults.string(forKey: "lastRecording").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { defaults.set(newValue?.path, forKey: "lastRecording") }
    }

    static var appFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Rozmova", isDirectory: true)
    }

    /// Separate tracks and the silent screen video, one folder per call; cleaned after a while.
    static var rawFolder: URL { appFolder.appendingPathComponent("Raw", isDirectory: true) }

    /// Transcripts, meta and segments, one folder per call; kept forever (a few KB each).
    static var historyFolder: URL { appFolder.appendingPathComponent("History", isDirectory: true) }

    /// Raw files older than this are deleted; 0 keeps them forever.
    static var cleanupDays: Int {
        get { defaults.object(forKey: "cleanupDays") as? Int ?? 14 }
        set { defaults.set(newValue, forKey: "cleanupDays") }
    }

    /// Split the other side into Співрозмовник 1, 2… by voice.
    static var splitVoices: Bool {
        get { defaults.object(forKey: "splitVoices") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "splitVoices") }
    }

    static var engine: SpeechEngine {
        get { SpeechEngine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .parakeet }
        set { defaults.set(newValue.rawValue, forKey: "engine") }
    }

    /// Groq model: whisper-large-v3 (more accurate) or whisper-large-v3-turbo (cheaper).
    static var groqModel: String {
        get { defaults.string(forKey: "groqModel") ?? "whisper-large-v3" }
        set { defaults.set(newValue, forKey: "groqModel") }
    }
}
