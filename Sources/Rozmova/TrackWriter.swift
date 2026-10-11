import AVFoundation
import QuartzCore

/// Writes one audio source (mic or system) into a mono 48 kHz AAC file that starts at the session
/// origin. Buffers carry host-clock times, so a late start, a muted source or a device switch are
/// filled with silence and every track stays on the same timeline: second N in mic.m4a is
/// second N in the other track and in the screen video.
final class TrackWriter: @unchecked Sendable {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    private let origin: Double
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var written: AVAudioFramePosition = 0
    /// Added to buffer times if the source clock turns out not to be the host clock.
    private var clockCorrection: Double?

    init(url: URL, origin: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.origin = origin
    }

    /// `time`: host-clock seconds of the buffer's first frame. Safe to call from any thread.
    func append(_ buffer: AVAudioPCMBuffer, at time: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, buffer.frameLength > 0, let converted = convert(buffer) else { return }

        if clockCorrection == nil {
            let now = CACurrentMediaTime()
            clockCorrection = abs(now - time) > 2 ? now - time : 0
            if clockCorrection != 0 {
                Log.info("Audio clock is not host time, correcting by \(clockCorrection!) s")
            }
        }
        let start = time + (clockCorrection ?? 0)
        let expected = origin + Double(written) / format.sampleRate
        if start - expected > 0.1 {
            writeSilence(seconds: start - expected, to: file)
        }
        do {
            try file.write(from: converted)
            written += AVAudioFramePosition(converted.frameLength)
        } catch {
            Log.info("Audio write failed: \(error.localizedDescription)")
        }
    }

    /// Finalizes the file. Later appends are ignored.
    func close() {
        lock.lock()
        file = nil
        converter = nil
        lock.unlock()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Log.info("Audio convert failed: \(error.localizedDescription)")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    private func writeSilence(seconds: Double, to file: AVAudioFile) {
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        let chunk: AVAudioFrameCount = 48_000
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        silence.floatChannelData![0].update(repeating: 0, count: Int(chunk))
        while remaining > 0 {
            silence.frameLength = min(chunk, remaining)
            do {
                try file.write(from: silence)
            } catch {
                return
            }
            written += AVAudioFramePosition(silence.frameLength)
            remaining -= silence.frameLength
        }
    }
}
