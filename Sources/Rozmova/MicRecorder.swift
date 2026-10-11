import AVFoundation
import QuartzCore

/// Captures the default input device. If the device changes mid-call (AirPods connected),
/// AVAudioEngine stops; we restart it on the new device and TrackWriter fills the gap.
@MainActor
final class MicRecorder {
    private let engine = AVAudioEngine()
    private let writer: TrackWriter
    private var observer: NSObjectProtocol?

    init(writer: TrackWriter) {
        self.writer = writer
    }

    func start() throws {
        try startEngine()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info("Microphone changed, restarting capture")
                do {
                    try self?.startEngine()
                } catch {
                    Log.info("Microphone restart failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func startEngine() throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(writer))
        engine.prepare()
        try engine.start()
    }

    /// Built outside the main actor: the tap runs on an audio thread, and a closure formed in
    /// MainActor code would trip Swift's actor-isolation check there.
    nonisolated private static func tap(_ writer: TrackWriter) -> AVAudioNodeTapBlock {
        { buffer, when in
            let time = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : CACurrentMediaTime()
            writer.append(buffer, at: time)
        }
    }
}
