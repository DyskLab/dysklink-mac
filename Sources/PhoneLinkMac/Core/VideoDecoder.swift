import CoreMedia
import Foundation
import VideoToolbox

/// Holds only the newest decoded picture for the main thread. The decoder may finish frames faster than the main
/// thread shows them; older pictures are then skipped instead of queueing up behind each other.
final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var scheduled = false
    private let show: @MainActor (CVPixelBuffer) -> Void

    init(show: @escaping @MainActor (CVPixelBuffer) -> Void) {
        self.show = show
    }

    /// From any thread.
    func push(_ buffer: CVPixelBuffer) {
        lock.lock()
        frame = buffer
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let next = frame
            frame = nil
            scheduled = false
            lock.unlock()
            if let next { MainActor.assumeIsolated { show(next) } }
        }
    }
}

/// Decodes Annex B H.264 from the Android encoder. SPS and PPS come with every key frame.
/// `decode` and `reset` are called from one thread at a time; `onFrame` runs on VideoToolbox's thread.
final class VideoDecoder {
    private let callbackLock = NSLock()
    private var frameCallback: ((CVPixelBuffer) -> Void)?
    var onFrame: ((CVPixelBuffer) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return frameCallback }
        set { callbackLock.lock(); frameCallback = newValue; callbackLock.unlock() }
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        sps = nil
        pps = nil
    }

    deinit { reset() }

    /// Returns false if the frame can't be decoded and a new key frame is needed.
    func decode(_ data: Data) -> Bool {
        // The NAL units are found in place; only SPS and PPS are copied out, and the slices are copied once,
        // straight into the sample's memory with 4-byte lengths in front.
        let units = Self.nalRanges(data)
        var newSps: Data?
        var newPps: Data?
        var slices: [Range<Int>] = []
        var slicesLength = 0
        for range in units {
            switch data[range.lowerBound] & 0x1F {
            case 7: newSps = data.subdata(in: range)
            case 8: newPps = data.subdata(in: range)
            default:
                slices.append(range)
                slicesLength += 4 + range.count
            }
        }
        if let newSps, let newPps, newSps != sps || newPps != pps {
            guard makeSession(sps: newSps, pps: newPps) else { return false }
        }
        guard !slices.isEmpty else { return session != nil }
        guard let session, let format,
              let sample = Self.sampleBuffer(data, slices: slices, length: slicesLength, format: format) else { return false }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.onFrame?(image)
        }
        return status == noErr
    }

    private func makeSession(sps newSps: Data, pps newPps: Data) -> Bool {
        reset()
        var description: CMFormatDescription?
        let status = newSps.withUnsafeBytes { (spsBytes: UnsafeRawBufferPointer) -> OSStatus in
            newPps.withUnsafeBytes { (ppsBytes: UnsafeRawBufferPointer) -> OSStatus in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [newSps.count, newPps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { return false }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var created: VTDecompressionSession?
        let result = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created
        )
        guard result == noErr, let created else { return false }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        format = description
        sps = newSps
        pps = newPps
        return true
    }

    private static func sampleBuffer(_ data: Data, slices: [Range<Int>], length: Int,
                                     format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            for range in slices {
                var size = UInt32(range.count).bigEndian
                let wroteLength = withUnsafeBytes(of: &size) {
                    CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: offset, dataLength: 4)
                }
                // Ranges are relative to data.startIndex, which isn't always 0.
                let start = base + (range.lowerBound - data.startIndex)
                guard wroteLength == noErr, CMBlockBufferReplaceDataBytes(
                    with: start, blockBuffer: block, offsetIntoDestination: offset + 4, dataLength: range.count
                ) == noErr else { return false }
                offset += 4 + range.count
            }
            return true
        }
        guard copied else { return nil }
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    /// Splits NAL units on the `00 00 01` or `00 00 00 01` start codes.
    static func nalUnits(_ data: Data) -> [Data] {
        nalRanges(data).map { data.subdata(in: $0) }
    }

    /// Where each NAL unit is in `data` (indices of `data`), found without copying. Units are never empty.
    static func nalRanges(_ data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Int>] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            let shift = data.startIndex
            var units: [Range<Int>] = []
            var start: Int?
            var index = 0
            while index + 2 < count {
                if bytes[index + 2] > 1 {
                    // No start code can begin at index, index + 1, or index + 2.
                    index += 3
                } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                    if let start {
                        var end = index
                        while end > start, bytes[end - 1] == 0 { end -= 1 }
                        if end > start { units.append((start + shift)..<(end + shift)) }
                    }
                    start = index + 3
                    index += 3
                } else {
                    index += 1
                }
            }
            if let start, start < count { units.append((start + shift)..<(count + shift)) }
            return units
        }
    }
}
