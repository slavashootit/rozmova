import Foundation

/// Deletes old technical files (separate tracks, silent screen video) from
/// ~/Library/Application Support/Rozmova/Raw. Recordings, transcripts and statistics are never
/// touched; the only loss is that such a call can no longer be transcribed again.
enum Cleanup {
    /// Total size and number of calls with technical files.
    static func usage() -> (bytes: Int64, calls: Int) {
        let calls = callFolders()
        let bytes = calls.reduce(Int64(0)) { $0 + size(of: $1) }
        return (bytes, calls.count)
    }

    /// Removes call folders whose newest file is older than `days`. 0 days never removes.
    @discardableResult
    static func run(olderThanDays days: Int) -> Int {
        guard days > 0 else { return 0 }
        return remove(olderThan: Date().addingTimeInterval(-Double(days) * 86_400))
    }

    /// "Clear now": everything except the last hour, so a call that is still recording or
    /// waiting for its transcript keeps its files.
    @discardableResult
    static func runNow() -> Int {
        remove(olderThan: Date().addingTimeInterval(-3_600))
    }

    private static func remove(olderThan cutoff: Date) -> Int {
        var removed = 0
        for folder in callFolders() where newestChange(in: folder) < cutoff {
            do {
                try FileManager.default.removeItem(at: folder)
                removed += 1
            } catch {
                Log.info("Cleanup failed for \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            Log.info("Cleanup removed technical files of \(removed) call(s)")
        }
        return removed
    }

    private static func callFolders() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: Prefs.rawFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return (contents ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Files still being written (a recording in progress) count as fresh.
    private static func newestChange(in folder: URL) -> Date {
        files(in: folder).compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? .distantPast
    }

    private static func size(of folder: URL) -> Int64 {
        files(in: folder).reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func files(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }
}
