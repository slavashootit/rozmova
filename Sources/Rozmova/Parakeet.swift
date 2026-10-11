import FluidAudio
import Foundation

/// NVIDIA Parakeet (the "ultra" post-train of TDT 0.6B v3) on the Neural Engine via FluidAudio.
/// Runs on this Mac, free, 25 European languages including Ukrainian. The model (~0.6 GB) is
/// downloaded once and cached by FluidAudio.
enum Parakeet {
    private static let version: AsrModelVersion = .ultra
    private static let loader = ParakeetLoader()

    /// Download the model in the background, so the first call doesn't wait for it.
    static func prefetch() async {
        do {
            _ = try await AsrModels.download(version: version)
        } catch {
            Log.info("Parakeet download failed: \(error.localizedDescription)")
        }
    }

    static func transcribe(_ url: URL, language: String) async throws -> [Segment] {
        let manager = try await loader.manager(version: version)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(url, decoderState: &state, language: Language(rawValue: language))
        return segments(from: buildWordTimings(from: result.tokenTimings ?? []))
    }

    /// Frees the model's memory; the app sits in the menu bar between calls.
    static func unload() async {
        await loader.unload()
    }

    /// Words into readable pieces: a new piece after a pause or a finished sentence.
    private static func segments(from words: [WordTiming]) -> [Segment] {
        var result: [Segment] = []
        var current: [WordTiming] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.word).joined(separator: " ")
            result.append(Segment(start: first.startTime, end: last.endTime, speaker: "", text: text))
            current = []
        }
        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 {
                flush()
            }
            current.append(word)
            if let end = word.word.last, ".?!…".contains(end), current.count >= 4 {
                flush()
            }
        }
        flush()
        return result
    }
}

/// Loads the model once per batch of recordings.
private actor ParakeetLoader {
    private var manager: AsrManager?

    func manager(version: AsrModelVersion) async throws -> AsrManager {
        if let manager { return manager }
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default, models: models)
        self.manager = manager
        return manager
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }
}
