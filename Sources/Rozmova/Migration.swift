import Foundation

/// Moves calls recorded by 0.7 to the current layout: their meta.json and .txt go to History,
/// the separate tracks to Raw. Runs at launch; does nothing once the old folder is gone.
enum Migration {
    static func run() {
        let fm = FileManager.default
        let old = Prefs.appFolder.appendingPathComponent("Calls", isDirectory: true)
        guard let calls = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }

        for oldRaw in calls {
            let name = oldRaw.lastPathComponent
            let mediaFolder = Prefs.recordingsFolder.appendingPathComponent(name, isDirectory: true)
            let layout = Layout(name: name, mediaFolder: mediaFolder)
            do {
                try fm.createDirectory(at: layout.history, withIntermediateDirectories: true)
                let oldMeta = oldRaw.appendingPathComponent("meta.json")
                if fm.fileExists(atPath: oldMeta.path), !fm.fileExists(atPath: layout.meta.path) {
                    try fm.moveItem(at: oldMeta, to: layout.meta)
                    if var meta = try? SessionMeta.load(from: layout), meta.mediaFolder == nil {
                        meta.mediaFolder = mediaFolder.path
                        try meta.save(to: layout)
                    }
                }
                let oldText = mediaFolder.appendingPathComponent("\(name).txt")
                if fm.fileExists(atPath: oldText.path), !fm.fileExists(atPath: layout.transcript.path) {
                    try fm.moveItem(at: oldText, to: layout.transcript)
                }
                try fm.createDirectory(at: Prefs.rawFolder, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: layout.raw.path) {
                    try fm.moveItem(at: oldRaw, to: layout.raw)
                }
            } catch {
                Log.info("Migration of \(name) failed: \(error.localizedDescription)")
            }
        }
        if (try? fm.contentsOfDirectory(atPath: old.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
            try? fm.removeItem(at: old)
        }
    }
}
