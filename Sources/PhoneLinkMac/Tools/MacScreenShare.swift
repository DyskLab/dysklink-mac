import AppKit
import CoreMedia
import VirtualDisplay
import ScreenCaptureKit
import VideoToolbox

/// Records one display and encodes it as H.264 for a phone. Frames come out as Annex B, with SPS and PPS on key frames.
final class MacScreenEncoder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Config {
        /// The longer side is scaled down to this many pixels, which phones decode easily and Wi-Fi carries.
        var maxSide = 1600
        var fps = 30
        var bitrate = 5_000_000
    }

    /// Changes the bitrate while recording, for a slower or faster network.
    func setBitrate(_ bitrate: Int) {
        queue.async {
            guard let session = self.session else { return }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        }
    }

    /// Size of the encoded picture and the display's frame in screen points, for mapping touches.
    struct Started {
        var width: Int
        var height: Int
        var displayFrame: CGRect
        var displayName: String
    }

    /// Runs on a background queue.
    var onFrame: ((Data, Bool) -> Void)?
    var onStopped: ((String?) -> Void)?

    private let config: Config
    private let queue = DispatchQueue(label: "dysklink.macscreen")
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var forceKey = true
    private var stopped = false

    init(config: Config = Config()) {
        self.config = config
    }

    static func size(for display: CGSize, maxSide: Int) -> (Int, Int) {
        let scale = min(1, CGFloat(maxSide) / max(display.width, display.height))
        // H.264 wants even sizes.
        func even(_ value: CGFloat) -> Int { max(2, Int((value * scale).rounded()) & ~1) }
        return (even(display.width), even(display.height))
    }

    /// Starts recording the display with this ID, or the main display.
    func start(displayID: CGDirectDisplayID? = nil) async throws -> Started {
        let wanted = displayID ?? CGMainDisplayID()
        var found: SCDisplay?
        // A display that was just created takes a moment to show up.
        for attempt in 0..<15 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            found = content.displays.first { $0.displayID == wanted } ?? (displayID == nil ? content.displays.first : nil)
            if found != nil || attempt == 14 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let display = found
        else { throw NSError(domain: "DyskLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to share"]) }
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }
        let points = CGSize(width: display.width, height: display.height)
        // Retina displays have twice the pixels, which keeps text sharp before scaling down.
        let pixels = CGSize(width: points.width * (screen?.backingScaleFactor ?? 2), height: points.height * (screen?.backingScaleFactor ?? 2))
        let (width, height) = Self.size(for: pixels, maxSide: config.maxSide)

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfig.showsCursor = true
        streamConfig.queueDepth = 4
        streamConfig.capturesAudio = false
        // DyskLink's own windows stay in the picture; nothing is hidden from the phone.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        try makeEncoder(width: width, height: height)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        return Started(width: width, height: height, displayFrame: CGDisplayBounds(display.displayID),
                       displayName: screen?.localizedName ?? "Display")
    }

    func requestKeyFrame() { queue.async { self.forceKey = true } }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            let stream = self.stream
            self.stream = nil
            Task { try? await stream?.stopCapture() }
            if let session = self.session {
                VTCompressionSessionInvalidate(session)
                self.session = nil
            }
        }
    }

    private func makeEncoder(width: Int, height: Int) throws {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let session = created else {
            throw NSError(domain: "DyskLink", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "The video encoder didn't start"])
        }
        let settings: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: config.bitrate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_ExpectedFrameRate: config.fps,
        ]
        for (key, value) in settings { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, let session, let image = sampleBuffer.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        var properties: CFDictionary?
        if forceKey {
            forceKey = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                                        duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self else { return }
            if let (data, key) = Self.annexB(encoded) { self.onFrame?(data, key) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.onStopped?(error.localizedDescription)
        }
    }

    /// Turns the encoder's length-prefixed NAL units into start-code ones, with SPS and PPS before key frames.
    static func annexB(_ sample: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = sample.dataBuffer else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if key, let format = sample.formatDescription {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        guard length > 0, CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        var offset = 0
        while offset + 4 <= length {
            let size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard size > 0, offset + size <= length else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: bytes[offset..<offset + size])
            offset += size
        }
        return out.isEmpty ? nil : (out, key)
    }
}

/// The phone as an extra display: its size in points, from what the phone asked for.
enum SecondDisplay {
    /// macOS only offers sharp (2×) desktops whose short side is at least 600 points, so smaller requests grow to that,
    /// keeping the shape. Both landscape and portrait work.
    static let minShortSide = 600

    /// Larger text: a 1× desktop this small, which makes everything bigger on the phone but less sharp.
    static let minLargeShortSide = 360

    static func size(requested: ScreenInfo?, large: Bool = false) -> (width: Int, height: Int)? {
        guard let requested, requested.width > 0, requested.height > 0 else { return nil }
        let portrait = requested.height > requested.width
        let long = Double(max(requested.width, requested.height))
        let short = Double(min(requested.width, requested.height))
        let aspect = long / short
        guard aspect <= 4 else { return nil }
        let newShort = min(max(Int(short), large ? minLargeShortSide : minShortSide), 1200)
        let newLong = Int((Double(newShort) * aspect).rounded())
        guard newLong <= 2560 else { return nil }
        let (a, b) = (newLong & ~1, newShort & ~1)
        return portrait ? (b, a) : (a, b)
    }

    static func make(name: String, width: Int, height: Int, serial: UInt32, sharp: Bool = true) -> DLVirtualDisplay? {
        guard let display = DLVirtualDisplay(name: name, width: UInt(width), height: UInt(height), hiDPI: sharp, serial: serial)
        else { return nil }
        if sharp { useSharpMode(display.displayID, width: width, height: height) }
        return display
    }

    /// macOS picks the full pixel size at 1×, which makes text tiny on a phone. The 2× mode keeps it readable and sharp.
    static func useSharpMode(_ id: CGDirectDisplayID, width: Int, height: Int, attempt: Int = 0) {
        // A new display needs a moment before it takes a mode, so this tries again a few times.
        if attempt > 0, Int(CGDisplayBounds(id).width) == width { return }
        if attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { useSharpMode(id, width: width, height: height, attempt: attempt + 1) }
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        guard let sharp = modes.first(where: { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }) else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, id, sharp, nil)
        CGCompleteDisplayConfiguration(config, .forSession)
    }
}

/// One phone viewing this Mac's screen.
@MainActor
final class MacScreenViewer {
    static let maxInFlight = 3
    let encoder: MacScreenEncoder
    /// Set when the phone is an extra display rather than a view of this one. Releasing it removes the display.
    var extraDisplay: DLVirtualDisplay?
    /// The extra display's size in points, so a turned phone can ask for a new one.
    var extraSize: (width: Int, height: Int)?
    /// The extra display is the larger-text 1× kind.
    var extraLarge = false
    /// The display being shown, when the phone picked one.
    var displayID: CGDirectDisplayID?
    /// The bitrate now, which follows how many frames the network takes.
    var bitrate = MacScreenEncoder.Config().bitrate
    var maxBitrate = MacScreenEncoder.Config().bitrate
    var windowSent = 0
    var windowDropped = 0

    static let minBitrate = 1_000_000
    static let adaptEvery = 45

    /// After a frame couldn't be sent: about two thirds of the bitrate, not below `minBitrate`.
    func lowerBitrate() {
        let next = Swift.max(Self.minBitrate, bitrate * 2 / 3)
        guard next != bitrate else { return }
        bitrate = next
        encoder.setBitrate(next)
    }

    /// Lower when more than one frame in ten was dropped, higher again when none were.
    static func nextBitrate(current: Int, sent: Int, dropped: Int, max limit: Int) -> Int {
        let total = sent + dropped
        guard total > 0 else { return current }
        if dropped * 10 > total { return Swift.max(minBitrate, current * 7 / 10) }
        if dropped == 0 { return Swift.min(limit, current * 115 / 100) }
        return current
    }

    /// This Mac's displays, without extra displays DyskLink made for phones.
    @MainActor static func displays() -> [DisplayChoice] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  !screen.localizedName.contains("(DyskLink)") else { return nil }
            return DisplayChoice(id: id, name: screen.localizedName, main: id == CGMainDisplayID())
        }
    }
    var width = 0
    var height = 0
    var displayFrame = CGRect.zero
    var displayName = ""
    /// Frames the network hasn't taken yet.
    var inFlight = 0
    var waitsForKey = false
    var sent = 0
    var dropped = 0

    init(encoder: MacScreenEncoder) {
        self.encoder = encoder
    }
}
