import AVFoundation
import Foundation

/// Groq's hosted Whisper (whisper-large-v3 by default). Fast and cheap, but a request takes at
/// most 25 MB on the free tier, so tracks are cut into 5-minute pieces at the quietest moment.
/// Pieces with no sound at all (your mic while the others talk) are not sent.
enum Groq {
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private static let chunkSeconds = 300.0

    static func apiKey() -> String? {
        if let key = Keychain.get(Keychain.groqKey), !key.isEmpty { return key }
        return ProcessInfo.processInfo.environment["GROQ_API_KEY"]
    }

    static func transcribe(_ url: URL, language: String) async throws -> [Segment] {
        guard let key = apiKey() else { throw GroqError.noKey }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rozmova-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var result: [Segment] = []
        for chunk in try split(url, into: work) {
            result += try await request(chunk.url, offset: chunk.offset, language: language, apiKey: key)
        }
        return result
    }

    // MARK: - Request

    private struct Response: Decodable {
        struct Item: Decodable {
            let start: Double
            let end: Double
            let text: String
            let no_speech_prob: Double?
        }
        let segments: [Item]?
    }

    private static func request(_ file: URL, offset: Double, language: String, apiKey: String) async throws -> [Segment] {
        let boundary = "rozmova-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", Prefs.groqModel)
        field("response_format", "verbose_json")
        field("temperature", "0")
        if language != "auto" {
            field("language", language)
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        // Rate limits (429) and hiccups (5xx) are retried with a pause.
        for attempt in 1...5 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 200 {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                return (decoded.segments ?? [])
                    .filter { ($0.no_speech_prob ?? 0) < 0.6 }
                    .map { Segment(start: $0.start + offset, end: $0.end + offset, speaker: "", text: $0.text) }
            }
            if (status == 429 || status >= 500), attempt < 5 {
                let wait = http?.value(forHTTPHeaderField: "retry-after").flatMap { Double($0) } ?? Double(attempt * 10)
                Log.info("Groq \(status), retrying in \(Int(wait)) s")
                try await Task.sleep(nanoseconds: UInt64(min(wait, 120) * 1_000_000_000))
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw GroqError.api(status, message)
        }
        throw GroqError.api(429, "rate limit")
    }

    // MARK: - Chunks

    private static func split(_ url: URL, into folder: URL) throws -> [(url: URL, offset: Double)] {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let rate = format.sampleRate
        let chunkFrames = AVAudioFramePosition(chunkSeconds * rate)
        var chunks: [(url: URL, offset: Double)] = []
        var position: AVAudioFramePosition = 0

        while position < source.length {
            source.framePosition = position
            let want = AVAudioFrameCount(min(chunkFrames, source.length - position))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: want) else { break }
            try source.read(into: buffer, frameCount: want)
            guard buffer.frameLength > 0 else { break }

            let isLast = position + AVAudioFramePosition(buffer.frameLength) >= source.length
            if !isLast {
                buffer.frameLength = quietestCut(buffer, searchSeconds: 15)
            }
            if !isSilent(buffer) {
                let chunkURL = folder.appendingPathComponent("chunk-\(chunks.count).m4a")
                try write(buffer, to: chunkURL)
                chunks.append((chunkURL, Double(position) / rate))
            }
            position += AVAudioFramePosition(buffer.frameLength)
        }
        return chunks
    }

    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let format = buffer.format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ]
        // The file is finalized when `file` goes out of scope.
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try file.write(from: buffer)
    }

    /// 100 ms loudness levels of the first channel.
    private static func levels(_ buffer: AVAudioPCMBuffer, from start: Int = 0) -> [(frame: Int, rms: Float)] {
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        let window = max(1, Int(buffer.format.sampleRate / 10))
        let count = Int(buffer.frameLength)
        return stride(from: start, to: count - window + 1, by: window).map { offset in
            var sum: Float = 0
            for i in offset..<(offset + window) {
                sum += samples[i] * samples[i]
            }
            return (offset, (sum / Float(window)).squareRoot())
        }
    }

    /// Frame count to keep: ends in the quietest 100 ms of the last `searchSeconds`, so a cut
    /// doesn't split a word.
    private static func quietestCut(_ buffer: AVAudioPCMBuffer, searchSeconds: Double) -> AVAudioFrameCount {
        let count = Int(buffer.frameLength)
        let start = max(0, count - Int(searchSeconds * buffer.format.sampleRate))
        guard let quietest = levels(buffer, from: start).min(by: { $0.rms < $1.rms }) else { return buffer.frameLength }
        let window = Int(buffer.format.sampleRate / 10)
        return AVAudioFrameCount(max(window, quietest.frame + window / 2))
    }

    /// No 100 ms window above about -46 dBFS: nothing worth sending.
    private static func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        (levels(buffer).map(\.rms).max() ?? 0) < 0.005
    }
}

enum GroqError: LocalizedError {
    case noKey
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "Немає ключа Groq API (меню → «Ключ Groq API…»)."
        case .api(let status, let message): return "Groq \(status): \(message)"
        }
    }
}
