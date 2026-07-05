import AVFoundation
import Foundation

/// Plays audio that arrives as a sequence of same-format chunk files,
/// starting playback as soon as the first chunk is appended while later
/// chunks are still being synthesized.
@MainActor
final class ChunkedAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var buffers: [AVAudioPCMBuffer] = []
    /// Cumulative end time of each buffer, in seconds.
    private var bufferEndTimes: [TimeInterval] = []
    /// Time position represented by the start of the current node schedule.
    private var scheduleBase: TimeInterval = 0

    private(set) var totalDuration: TimeInterval = 0
    private(set) var isFinalized = false
    private(set) var isPaused = false

    var currentTime: TimeInterval {
        guard let format else { return 0 }
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return min(scheduleBase, totalDuration)
        }
        let elapsed = scheduleBase + Double(playerTime.sampleTime) / format.sampleRate
        return min(max(elapsed, 0), totalDuration)
    }

    func appendChunk(at url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(
                domain: "Mockingbird",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio buffer."]
            )
        }
        try file.read(into: buffer)

        if format == nil {
            format = file.processingFormat
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            try engine.start()
        }

        buffers.append(buffer)
        totalDuration += Double(buffer.frameLength) / file.processingFormat.sampleRate
        bufferEndTimes.append(totalDuration)

        node.scheduleBuffer(buffer, completionHandler: nil)
        if !isPaused, !node.isPlaying {
            node.play()
        }
    }

    func finalize() {
        isFinalized = true
    }

    func pause() {
        guard !isPaused else { return }
        // Capture position before pausing; playerTime is unreliable afterwards.
        scheduleBase = currentTime
        isPaused = true
        node.pause()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
        buffers = []
        bufferEndTimes = []
        format = nil
        totalDuration = 0
        scheduleBase = 0
        isFinalized = true
    }

    func seek(to target: TimeInterval) {
        guard let format, !buffers.isEmpty else { return }
        let clamped = min(max(target, 0), totalDuration)

        node.stop()

        var index = bufferEndTimes.firstIndex { $0 > clamped } ?? (buffers.count - 1)
        var offsetSeconds = clamped - (index > 0 ? bufferEndTimes[index - 1] : 0)
        if offsetSeconds < 0 { offsetSeconds = 0 }

        let sampleRate = format.sampleRate
        var isFirst = true
        while index < buffers.count {
            let buffer = buffers[index]
            if isFirst {
                let offsetFrames = AVAudioFramePosition(offsetSeconds * sampleRate)
                if let tail = Self.slice(buffer, from: offsetFrames, format: format) {
                    node.scheduleBuffer(tail, completionHandler: nil)
                }
            } else {
                node.scheduleBuffer(buffer, completionHandler: nil)
            }
            isFirst = false
            index += 1
        }

        scheduleBase = clamped
        if !isPaused {
            node.play()
        }
    }

    private static func slice(
        _ buffer: AVAudioPCMBuffer,
        from offsetFrames: AVAudioFramePosition,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let total = AVAudioFramePosition(buffer.frameLength)
        let start = min(max(offsetFrames, 0), total)
        let remaining = AVAudioFrameCount(total - start)
        guard remaining > 0 else { return nil }
        guard let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else { return nil }

        let channels = Int(format.channelCount)
        if let source = buffer.floatChannelData, let destination = tail.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(
                    from: source[channel] + Int(start),
                    count: Int(remaining)
                )
            }
        }
        tail.frameLength = remaining
        return tail
    }
}
