import AVFoundation

enum MixdownError: LocalizedError {
    case cannotExport

    var errorDescription: String? { "Не вдалося зібрати файл розмови." }
}

/// Right after a call: both sides mixed into one .m4a (to upload anywhere) and the screen video
/// with that sound as the .mp4. The separate tracks stay in .raw/. All tracks start at the same
/// moment, so they are simply laid on top of each other from zero.
enum Mixdown {
    static func run(_ layout: Layout) async throws {
        try await mixAudio(layout)
        if FileManager.default.fileExists(atPath: layout.silentScreen.path) {
            try await addSound(layout)
        }
    }

    private static func mixAudio(_ layout: Layout) async throws {
        let composition = AVMutableComposition()
        for url in [layout.mic, layout.system] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try await append(.audio, from: url, to: composition)
            } catch {
                // One empty side (a mic that never started) should not cost the other.
                Log.info("Mixdown skipped \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // Without an audio mix the export sums all audio tracks into one.
        try await export(composition, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: layout.audio)
    }

    private static func addSound(_ layout: Layout) async throws {
        let composition = AVMutableComposition()
        try await append(.video, from: layout.silentScreen, to: composition)
        try await append(.audio, from: layout.audio, to: composition)
        // Passthrough: no re-encoding, takes seconds even for an hour of video.
        try await export(composition, preset: AVAssetExportPresetPassthrough, type: .mp4, to: layout.video)
        try FileManager.default.removeItem(at: layout.silentScreen)
    }

    private static func append(_ type: AVMediaType, from url: URL, to composition: AVMutableComposition) async throws {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: type).first,
              let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }
        let duration = try await asset.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
    }

    /// Writes next to the target first, so a failed export never leaves half a file behind.
    private static func export(_ asset: AVAsset, preset: String, type: AVFileType, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw MixdownError.cannotExport }
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".rozmova-\(UUID().uuidString).\(url.pathExtension)")
        if #available(macOS 15, *) {
            try await session.export(to: temp, as: type)
        } else {
            session.outputURL = temp
            session.outputFileType = type
            await session.export()
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: temp)
                throw session.error ?? MixdownError.cannotExport
            }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: temp, to: url)
    }
}
