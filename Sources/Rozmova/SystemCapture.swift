import AVFoundation
import QuartzCore
import ScreenCaptureKit

/// Everything the Mac plays (the other side of the call, from any app) plus, optionally, the main
/// display. One ScreenCaptureKit stream gives both, behind one permission:
/// Screen & System Audio Recording.
final class SystemCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on a background queue if macOS stops the stream mid-recording.
    var onFailure: (@Sendable (Error) -> Void)?

    private let audio: TrackWriter
    private let layout: Layout?
    private let origin: Double
    private let audioQueue = DispatchQueue(label: "com.slava.rozmova.audio")
    private let videoQueue = DispatchQueue(label: "com.slava.rozmova.video")
    private var stream: SCStream?
    private var screen: ScreenWriter?

    /// `screen` nil means audio only.
    init(audio: TrackWriter, screen: Layout?, origin: Double) {
        self.audio = audio
        self.layout = screen
        self.origin = origin
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { throw RecorderError.noDisplay }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if let layout {
            let size = ScreenWriter.size(forDisplayWidth: display.width, height: display.height)
            config.width = size.width
            config.height = size.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: ScreenWriter.fps)
            config.queueDepth = 8
            config.showsCursor = true
            screen = try ScreenWriter(video: layout.silentScreen, width: size.width, height: size.height,
                                      origin: origin, queue: videoQueue)
        } else {
            // The stream always has video; keep it tiny and rare when only audio is wanted.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // Added even for audio-only, otherwise ScreenCaptureKit floods the log with dropped frames.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        await screen?.finish(at: CACurrentMediaTime())
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio:
            guard let buffer = Self.pcmBuffer(sampleBuffer) else { return }
            audio.append(buffer, at: sampleBuffer.presentationTimeStamp.seconds)
        case .screen:
            screen?.append(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("System capture stopped: \(error.localizedDescription)")
        onFailure?(error)
    }

    private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

/// Screen recording for watching later: 30 fps, at most 1920×1200, H.264 at ~3 Mbit/s (still
/// slides cost far less), about 1.4 GB an hour at most.
final class ScreenWriter: @unchecked Sendable {
    static let fps: Int32 = 30

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let origin: Double
    private let queue: DispatchQueue
    private var started = false
    private var failed = false


    /// Fit the display's Retina pixel size into 1920×1200, even numbers for H.264.
    static func size(forDisplayWidth width: Int, height: Int) -> (width: Int, height: Int) {
        let pixelWidth = Double(width * 2)
        let pixelHeight = Double(height * 2)
        let scale = min(1, 1920 / pixelWidth, 1200 / pixelHeight)
        func even(_ value: Double) -> Int { max(2, Int(value * scale) / 2 * 2) }
        return (even(pixelWidth), even(pixelHeight))
    }

    init(video: URL, width: Int, height: Int, origin: Double, queue: DispatchQueue) throws {
        writer = try AVAssetWriter(outputURL: video, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoExpectedSourceFrameRateKey: Int(Self.fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        self.origin = origin
        self.queue = queue
    }

    /// On `queue`, for every frame.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard !failed, Self.isComplete(sampleBuffer), sampleBuffer.imageBuffer != nil else { return }
        if !started {
            guard writer.startWriting() else {
                failed = true
                Log.info("Screen writer failed: \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            // Same origin as the audio tracks, so the video lines up with them.
            writer.startSession(atSourceTime: CMTime(seconds: origin, preferredTimescale: 600))
            started = true
        }
        if writer.status == .writing, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    func finish(at time: Double) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                guard self.started, self.writer.status == .writing else {
                    done.resume()
                    return
                }
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
                self.writer.finishWriting {
                    done.resume()
                }
            }
        }
    }

    /// Only "complete" frames carry new pixels; idle and blank ones are skipped.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
