import CoreMedia
import Foundation
import VideoToolbox

/// Decodes Annex B H.264 from the Android encoder. SPS and PPS come with every key frame.
final class VideoDecoder {
    var onFrame: ((CVPixelBuffer) -> Void)?

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
        let units = Self.nalUnits(data)
        var slices = Data()
        var newSps: Data?
        var newPps: Data?
        for unit in units {
            guard let header = unit.first else { continue }
            switch header & 0x1F {
            case 7: newSps = unit
            case 8: newPps = unit
            default:
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { slices.append(contentsOf: $0) }
                slices.append(unit)
            }
        }
        if let newSps, let newPps, newSps != sps || newPps != pps {
            guard makeSession(sps: newSps, pps: newPps) else { return false }
        }
        guard !slices.isEmpty else { return session != nil }
        guard let session, let format, let sample = Self.sampleBuffer(slices, format: format) else { return false }
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

    private static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    /// Splits NAL units on the `00 00 01` or `00 00 00 01` start codes.
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start {
                    var end = index
                    while end > start, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Data(bytes[start..<end]))
                }
                start = index + 3
                index += 3
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }
}
