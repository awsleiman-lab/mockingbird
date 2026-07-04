import AVFoundation
import Foundation

enum SystemSpeechSynthesizerError: LocalizedError {
    case noAudioProduced
    case fileWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioProduced:
            "The system voice did not produce audio."
        case let .fileWriteFailed(message):
            "Could not save system voice audio: \(message)"
        }
    }
}

enum SystemSpeechSynthesizer {
    struct Result {
        let path: String
        let duration: TimeInterval
    }

    static func availableVoices() -> [EngineVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                voice.language.hasPrefix("en") && voice.identifier.hasPrefix("com.apple.voice.")
            }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
            .map { voice in
                EngineVoice(id: voice.identifier, displayName: displayName(for: voice))
            }
    }

    static func defaultVoiceIdentifier() -> String {
        availableVoices().first?.id
            ?? AVSpeechSynthesisVoice(language: "en-US")?.identifier
            ?? ""
    }

    static func synthesize(text: String, voiceIdentifier: String, speed: Double) async throws -> Result {
        let utterance = AVSpeechUtterance(string: text)
        if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        let clampedSpeed = min(max(speed, 0.5), 2.0)
        let defaultRate = Double(AVSpeechUtteranceDefaultSpeechRate)
        utterance.rate = Float(
            min(
                max(defaultRate * clampedSpeed, Double(AVSpeechUtteranceMinimumSpeechRate)),
                Double(AVSpeechUtteranceMaximumSpeechRate)
            )
        )

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "mockingbird-system-\(UUID().uuidString).caf")

        return try await withCheckedThrowingContinuation { continuation in
            let synthesizer = AVSpeechSynthesizer()
            let writer = BufferWriter(outputURL: outputURL)

            synthesizer.write(utterance) { buffer in
                // Retain the synthesizer until the final (empty) buffer arrives.
                _ = synthesizer

                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    return
                }

                if pcmBuffer.frameLength == 0 {
                    writer.finish(continuation: continuation)
                } else {
                    writer.append(pcmBuffer)
                }
            }
        }
    }

    private static func displayName(for voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium:
            "\(voice.name) (Premium)"
        case .enhanced:
            "\(voice.name) (Enhanced)"
        default:
            voice.name
        }
    }
}

private final class BufferWriter: @unchecked Sendable {
    private let outputURL: URL
    private var file: AVAudioFile?
    private var totalFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var writeError: Error?
    private var isFinished = false
    private let lock = NSLock()

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, writeError == nil else { return }

        do {
            if file == nil {
                file = try AVAudioFile(forWriting: outputURL, settings: buffer.format.settings)
                sampleRate = buffer.format.sampleRate
            }
            try file?.write(from: buffer)
            totalFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            writeError = error
        }
    }

    func finish(continuation: CheckedContinuation<SystemSpeechSynthesizer.Result, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        file = nil

        if let writeError {
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: SystemSpeechSynthesizerError.fileWriteFailed(writeError.localizedDescription))
            return
        }

        guard totalFrames > 0, sampleRate > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            continuation.resume(throwing: SystemSpeechSynthesizerError.noAudioProduced)
            return
        }

        continuation.resume(returning: SystemSpeechSynthesizer.Result(
            path: outputURL.path,
            duration: Double(totalFrames) / sampleRate
        ))
    }
}
