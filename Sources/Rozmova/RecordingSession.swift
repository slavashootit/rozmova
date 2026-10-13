import Foundation
import QuartzCore

enum RecorderError: LocalizedError {
    case noMicrophone
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "Не знайшов мікрофон."
        case .noDisplay: return "Не знайшов дисплей для запису."
        }
    }
}

/// One recorded call, laid out as described in `Layout`: you, everyone else, optionally the
/// screen. All tracks start at the same `origin`.
@MainActor
final class RecordingSession {
    let folder: URL
    var layout: Layout { Layout(mediaFolder: folder) }
    /// Stop by itself when the detected call ends.
    let autoStop: Bool
    var onSystemCaptureFailure: ((Error) -> Void)?
    private(set) var meta: SessionMeta
    private var origin = CACurrentMediaTime()
    private var mic: MicRecorder?
    private var system: SystemCapture?
    private var writers: [TrackWriter] = []

    var elapsed: Double { CACurrentMediaTime() - origin }

    /// The call app, for recording its window.
    private let appBundleID: String?

    init(app: String, bundleID: String? = nil, title: String?, screen: Bool, autoStop: Bool) throws {
        appBundleID = bundleID
        let now = Date()
        folder = try Self.makeFolder(date: now)
        meta = SessionMeta(app: app, title: title, started: now, duration: 0,
                           language: Prefs.language, hasScreen: screen,
                           mediaFolder: folder.path, speakerNames: nil)
        self.autoStop = autoStop
    }

    func start() async throws {
        origin = CACurrentMediaTime()
        let micWriter = try TrackWriter(url: layout.mic, origin: origin)
        let systemWriter = try TrackWriter(url: layout.system, origin: origin)
        writers = [micWriter, systemWriter]

        let system = SystemCapture(audio: systemWriter, screen: meta.hasScreen ? layout : nil, origin: origin,
                                   source: Prefs.captureSource, appBundleID: appBundleID)
        system.onFailure = { [weak self] error in
            Task { @MainActor in self?.onSystemCaptureFailure?(error) }
        }
        try await system.start()
        self.system = system

        let mic = MicRecorder(writer: micWriter)
        do {
            try mic.start()
        } catch {
            await system.stop()
            throw error
        }
        self.mic = mic
        try meta.save(to: layout)
    }

    @discardableResult
    func stop() async -> SessionMeta {
        mic?.stop()
        mic = nil
        await system?.stop()
        writers.forEach { $0.close() }
        meta.duration = elapsed
        system = nil
        do {
            try meta.save(to: layout)
        } catch {
            Log.info("meta.json save failed: \(error.localizedDescription)")
        }
        return meta
    }

    /// <recordings>/Call_2026-10-11_21-15, with _2, _3... if that minute is taken anywhere.
    private static func makeFolder(date: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let base = "Call_\(formatter.string(from: date))"
        let fm = FileManager.default
        func taken(_ url: URL) -> Bool {
            let layout = Layout(mediaFolder: url)
            return [url, layout.raw, layout.history].contains { fm.fileExists(atPath: $0.path) }
        }
        var url = Prefs.recordingsFolder.appendingPathComponent(base, isDirectory: true)
        var index = 2
        while taken(url) {
            url = Prefs.recordingsFolder.appendingPathComponent("\(base)_\(index)", isDirectory: true)
            index += 1
        }
        let layout = Layout(mediaFolder: url)
        for folder in [url, layout.raw, layout.history] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return url
    }
}
