import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Audio goes between the Mac and a phone as plain 16-bit stereo PCM at 48 kHz, in 40 ms chunks.
/// Plain PCM needs no codec on either side and is about 1.5 Mbit/s, which a home Wi-Fi carries easily.
enum AudioPCM {
    static let rate = 48_000
    static let channels = 2
    static let chunkFrames = 1_920
    static var chunkBytes: Int { chunkFrames * channels * 2 }

    /// Float samples, one array per channel, to interleaved little-endian 16-bit stereo. Mono is copied to both sides.
    static func int16(channels input: [[Float]]) -> Data {
        guard let left = input.first else { return Data() }
        let right = input.count > 1 ? input[1] : left
        let frames = min(left.count, right.count)
        var out = Data(count: frames * 4)
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                samples[i * 2] = Int16(max(-1, min(1, left[i])) * 32_767).littleEndian
                samples[i * 2 + 1] = Int16(max(-1, min(1, right[i])) * 32_767).littleEndian
            }
        }
        return out
    }

    /// Interleaved 16-bit samples back to one float array per channel.
    static func floats(_ data: Data, channels: Int) -> [[Float]] {
        let count = channels > 0 ? data.count / 2 / channels : 0
        var result = Array(repeating: [Float](repeating: 0, count: count), count: max(channels, 0))
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<count {
                for channel in 0..<channels {
                    result[channel][frame] = Float(Int16(littleEndian: samples[frame * channels + channel])) / 32_768
                }
            }
        }
        return result
    }

    /// The samples of a ScreenCaptureKit audio buffer, one array per channel.
    static func channels(of sampleBuffer: CMSampleBuffer) -> [[Float]]? {
        guard let description = sampleBuffer.formatDescription,
              let format = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleBuffer.numSamples)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(sampleBuffer.numSamples),
                                                           into: buffer.mutableAudioBufferList) == noErr,
              let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength), count = Int(format.channelCount)
        if format.isInterleaved {
            let all = data[0]
            return (0..<count).map { channel in (0..<frames).map { all[$0 * count + channel] } }
        }
        return (0..<count).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    }
}

/// Records what this Mac plays, without DyskLink's own sounds, and hands out 40 ms chunks.
final class MacAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dysklink.audio-capture", qos: .userInteractive)
    private var stream: SCStream?
    private var pending = Data()
    private var tone: DispatchSourceTimer?
    private var phase = 0.0
    /// Called on the capture queue with each chunk.
    var onChunk: ((Data) -> Void)?
    var onStop: ((String?) -> Void)?

    func start() async throws {
        if TestEnv.isDryRun { return startTone() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw NSError(domain: "DyskLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to record from"]) }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = AudioPCM.rate
        config.channelCount = AudioPCM.channels
        // Audio comes with a display stream; the picture is kept as small and rare as allowed.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        tone?.cancel()
        tone = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil
        queue.async { self.pending = Data() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let channels = AudioPCM.channels(of: sampleBuffer) else { return }
        append(AudioPCM.int16(channels: channels))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error.localizedDescription)
    }

    private func append(_ data: Data) {
        pending.append(data)
        while pending.count >= AudioPCM.chunkBytes {
            onChunk?(pending.prefix(AudioPCM.chunkBytes))
            pending.removeFirst(AudioPCM.chunkBytes)
        }
    }

    /// Tests have no sound to record, so a quiet 440 Hz tone stands in.
    private func startTone() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let samples: [Float] = (0..<AudioPCM.chunkFrames).map { _ in
                self.phase += 2 * .pi * 440 / Double(AudioPCM.rate)
                return Float(sin(self.phase) * 0.1)
            }
            self.append(AudioPCM.int16(channels: [samples, samples]))
        }
        timer.resume()
        tone = timer
    }
}

/// Plays audio sent by a phone. A short buffer smooths out Wi-Fi; when it grows too long, chunks are dropped to catch up.
@MainActor
final class PhoneAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var channels = 2
    private var queued = 0
    /// Bumped on every stop, so buffers finishing after a restart don't count against the new queue.
    private var generation = 0
    private var started = false
    private(set) var played = 0

    static let startAfter = 3
    static let maxQueued = 15
    /// Beside the phone's screen the buffer is shorter, so sound stays close to the picture.
    static let tightQueued = 5
    private var limit = maxQueued

    var muted = false {
        didSet { node.volume = muted ? 0 : 1 }
    }

    func start(rate: Int, channels: Int, tight: Bool = false) {
        stop()
        limit = tight ? Self.tightQueued : Self.maxQueued
        muted = false
        self.channels = max(1, min(channels, 2))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(self.channels)) else { return }
        self.format = format
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if !TestEnv.isDryRun { try? engine.start() }
    }

    func feed(_ data: Data) {
        guard let format else { return }
        // Too far behind: this chunk is dropped so the sound stays close to the phone.
        guard queued < limit else { return }
        let samples = AudioPCM.floats(data, channels: channels)
        let frames = samples.first?.count ?? 0
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels { samples[channel].withUnsafeBufferPointer { out[channel].update(from: $0.baseAddress!, count: frames) } }
        played += 1
        if TestEnv.isDryRun { return }
        queued += 1
        let generation = generation
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.queued = max(0, self.queued - 1)
            }
        }
        if !started, queued >= (limit == Self.tightQueued ? 2 : Self.startAfter) {
            started = true
            node.play()
        }
    }

    func stop() {
        node.stop()
        if engine.isRunning { engine.stop() }
        if engine.attachedNodes.contains(node) { engine.detach(node) }
        format = nil
        generation += 1
        queued = 0
        started = false
    }
}
