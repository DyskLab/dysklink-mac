import Foundation

/// Binary frames, for media and file data between two apps that both list `bin1` in `hello.caps`:
///
///     [UInt32 BE: 0x80000000 | length][UInt16 BE: header length][header: UTF-8 JSON envelope][raw payload]
///
/// `length` counts everything after the first word and is at most `PhoneLinkProtocol.maxFrameBytes`. The header is
/// the message without its base64 field (`video`, `audio`, or `file.data`), and the payload is that field's raw
/// bytes. Older apps (1.1.x and before) close the connection on a length word over 1 MiB, so they only ever get JSON:
/// a side sends binary only after the other side's first hello listed `bin1`, and only when its own hello did too.
/// Someone in the middle can only remove `bin1`, which falls back to JSON.
enum BinaryFrame {
    static let capability = "bin1"
    static let flag: UInt32 = 0x8000_0000
    static let headerLengthBytes = 2
    /// The messages that go binary. Everything else stays JSON.
    static let types: Set<String> = [
        MessageType.screenFrame, MessageType.cameraFrame, MessageType.macScreenFrame, MessageType.audioFrame, MessageType.fileChunk,
    ]

    /// What this Mac lists in `hello.caps`. Tests can turn it off to act like an older app.
    static var localCaps: [String]? {
        TestEnv.value("PHONELINK_TEST_NO_CAPS") == "1" ? nil : [capability]
    }

    static func supports(_ hello: Hello?) -> Bool { hello?.caps?.contains(capability) == true }

    /// `{"type":<type>}` or `{"type":<type>,"keyFrame":true}`: the same bytes the Kotlin encoder makes, which leaves
    /// a false or missing key frame out.
    static func header(type: String, keyFrame: Bool? = nil) -> Data {
        Data(("{\"type\":" + PeerSession.jsonString(type) + (keyFrame == true ? ",\"keyFrame\":true}" : "}")).utf8)
    }

    /// `{"type":"file.chunk","file":{"id":<id>}}`.
    static func chunkHeader(id: String) -> Data {
        Data(("{\"type\":\"\(MessageType.fileChunk)\",\"file\":{\"id\":" + PeerSession.jsonString(id) + "}}").utf8)
    }

    /// The whole frame, length word included, or nil when it's over the limit (or the header over 64 KiB).
    /// The payload is copied once, into the frame.
    static func frame(header: Data, payload: Data) -> Data? {
        let length = headerLengthBytes + header.count + payload.count
        guard !header.isEmpty, header.count <= 0xFFFF, length <= PhoneLinkProtocol.maxFrameBytes else { return nil }
        var frame = Data(capacity: 4 + length)
        var word = (flag | UInt32(length)).bigEndian
        withUnsafeBytes(of: &word) { frame.append(contentsOf: $0) }
        var headerLength = UInt16(header.count).bigEndian
        withUnsafeBytes(of: &headerLength) { frame.append(contentsOf: $0) }
        frame.append(header)
        frame.append(payload)
        return frame
    }

    /// The first word of a frame: whether it's binary, and the length after it. Nil when the length is out of range,
    /// which closes the connection.
    static func length(word: UInt32) -> (binary: Bool, length: Int)? {
        let binary = word & flag != 0
        let length = Int(word & ~flag)
        guard length >= (binary ? headerLengthBytes + 1 : 1), length <= PhoneLinkProtocol.maxFrameBytes else { return nil }
        return (binary, length)
    }

    /// The message and payload of a binary frame's body (everything after the length word). Nil when it's malformed:
    /// a header length of 0 or past the end, or a header that isn't a message. Such a frame closes the connection.
    static func parse(_ body: Data, decoder: JSONDecoder = JSONDecoder()) -> (Envelope, Data)? {
        guard body.count >= headerLengthBytes + 1 else { return nil }
        let start = body.startIndex
        let headerLength = Int(body[start]) << 8 | Int(body[start + 1])
        guard headerLength > 0, headerLength <= body.count - headerLengthBytes else { return nil }
        let headerEnd = start + headerLengthBytes + headerLength
        guard var envelope = try? decoder.decode(Envelope.self, from: body[(start + headerLengthBytes)..<headerEnd]) else { return nil }
        // The payload is the only copy of the data the handlers get; any base64 field in the header is ignored.
        envelope.video = nil
        envelope.audio = nil
        envelope.file?.data = nil
        return (envelope, body.subdata(in: headerEnd..<body.endIndex))
    }
}

/// Whether one connection uses binary frames: both hellos listed `bin1`. Only the first hello each way counts.
struct BinaryNegotiation {
    private(set) var local = false
    private(set) var peer = false
    private var sentHello = false
    private var receivedHello = false

    var binary: Bool { local && peer }

    mutating func sent(_ envelope: Envelope) {
        guard envelope.type == MessageType.hello, !sentHello else { return }
        sentHello = true
        local = BinaryFrame.supports(envelope.hello)
    }

    mutating func received(_ envelope: Envelope) {
        guard envelope.type == MessageType.hello, !receivedHello else { return }
        receivedHello = true
        peer = BinaryFrame.supports(envelope.hello)
    }
}

/// Decides which 40 ms sound chunks are worth sending to a `bin1` peer. A chunk is digitally silent when no sample is
/// louder than `threshold` (about -72 dBFS). The first `holdChunks` silent chunks in a row (200 ms) still go out, then
/// silence is held back until sound comes again. Receivers play silence by themselves when their queue runs dry, and
/// new ones put a little silence before the first chunk after a gap. Older receivers keep getting every chunk.
/// The same rule as `SilenceGate` in the Kotlin core.
struct SilenceGate {
    static let holdChunks = 5
    static let threshold: Int16 = 8
    private(set) var silentRun = 0

    /// `silent` from `isSilent`. True when the chunk should be sent.
    mutating func shouldSend(silent: Bool) -> Bool {
        guard silent else { silentRun = 0; return true }
        silentRun += 1
        return silentRun <= Self.holdChunks
    }

    /// 16-bit little-endian PCM with no sample past the threshold.
    static func isSilent(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { raw in
            let count = raw.count / 2
            for i in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                if sample > threshold || sample < -threshold { return false }
            }
            return true
        }
    }
}
