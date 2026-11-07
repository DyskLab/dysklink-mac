#if DEBUG
import CoreMedia
import Foundation
import VideoToolbox

/// `PhoneLinkMac --video-selftest`: creates Annex B H.264 like the Android encoder output, then
/// runs it through the real decoder and checks the picture size and color.
enum VideoSelfTest {
    private static let width = 720
    private static let height = 1280
    private static let frameCount = 30

    static func run() -> Bool {
        guard let packets = encode(), packets.count == frameCount else {
            print("VIDEO_SELFTEST failed: encoder")
            return false
        }
        let decoder = VideoDecoder()
        if decoder.decode(Data([0, 0, 0, 1, 0x41, 1, 2, 3])) {
            print("VIDEO_SELFTEST failed: frame without SPS accepted")
            return false
        }
        let lock = NSLock()
        var decoded = 0
        var size = (0, 0)
        var color: (UInt8, UInt8, UInt8) = (0, 0, 0)
        decoder.onFrame = { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let center = pixels + row * height / 2 + width * 2
            lock.lock()
            decoded += 1
            size = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
            color = (center[0], center[1], center[2])
            lock.unlock()
        }
        for packet in packets where !decoder.decode(packet) {
            print("VIDEO_SELFTEST failed: frame rejected")
            return false
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            lock.lock()
            let done = decoded
            lock.unlock()
            if done >= frameCount { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock()
        defer { lock.unlock() }
        let near = { (a: UInt8, b: Int) in abs(Int(a) - b) < 30 }
        guard decoded == frameCount, size == (width, height), near(color.0, 40), near(color.1, 200), near(color.2, 120) else {
            print("VIDEO_SELFTEST failed: \(decoded) frames, size \(size), color \(color)")
            return false
        }
        print("VIDEO_SELFTEST ok \(decoded) frames \(size.0)x\(size.1)")
        return true
    }

    private static func encode() -> [Data]? {
        var created: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created
        ) == noErr, let session = created else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 10 as CFNumber)

        var image: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &image)
        guard let image else { return nil }
        CVPixelBufferLockBaseAddress(image, [])
        let row = CVPixelBufferGetBytesPerRow(image)
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * row + x * 4
                pixel[0] = 40
                pixel[1] = 200
                pixel[2] = 120
                pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])

        let lock = NSLock()
        var packets: [Data] = []
        for index in 0..<frameCount {
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: image, presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample, let packet = annexB(sample, index: index) else { return }
                lock.lock()
                packets.append(packet)
                lock.unlock()
            }
            guard status == noErr else { return nil }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock()
        defer { lock.unlock() }
        return packets
    }

    /// Key frames get SPS and PPS in front, as ScreenStreamer does on Android.
    private static func annexB(_ sample: CMSampleBuffer, index: Int) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        // Some encoders use a 3-byte start code, so both are tested.
        let startCode = index % 2 == 0 ? Data([0, 0, 0, 1]) : Data([0, 0, 1])
        var output = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        if isKey {
            for parameter in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: parameter, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                ) == noErr, let pointer else { return nil }
                output.append(startCode)
                output.append(pointer, count: size)
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
        ) == noErr, let pointer else { return nil }
        let bytes = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= bytes.count {
            let size = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard offset + size <= bytes.count else { return nil }
            output.append(startCode)
            output.append(bytes[offset..<offset + size])
            offset += size
        }
        return output
    }
}
#endif
