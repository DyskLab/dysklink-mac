#if DEBUG
import Foundation

/// Binary frames (`bin1`): round trips against the JSON path, malformed frames, negotiation, fixed vectors shared
/// with the Kotlin core (FrameWriterTest.binaryFramesMatchTheMac), and the silence gate.
@MainActor
enum BinaryFrameSelfTest {
    /// Shared with the Kotlin core. `file.chunk` id "abc" with 00 01 02 ff; `macscreen.frame` key frame with
    /// 00 00 00 01 65; `audio.frame` with 01 00 ff ff.
    static let vectorChunk = "8000002f0029" + "7b2274797065223a2266696c652e6368756e6b222c2266696c65223a7b226964223a22616263227d7d" + "000102ff"
    static let vectorVideo = "80000031002a" + "7b2274797065223a226d616373637265656e2e6672616d65222c226b65794672616d65223a747275657d" + "0000000165"
    static let vectorAudio = "8000001c0016" + "7b2274797065223a22617564696f2e6672616d65227d" + "0100ffff"

    private static func hex(_ data: Data?) -> String { data.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "nil" }

    /// Reads one whole frame like the session does: the length word, then binary or JSON.
    private static func read(_ frame: Data?) -> (envelope: Envelope, payload: Data?, binary: Bool)? {
        guard let frame, frame.count >= 4 else { return nil }
        let word = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let (binary, length) = BinaryFrame.length(word: word), length == frame.count - 4 else { return nil }
        let body = frame.dropFirst(4)
        if binary {
            guard let (envelope, payload) = BinaryFrame.parse(Data(body)) else { return nil }
            return (envelope, payload, true)
        }
        guard var envelope = try? JSONDecoder().decode(Envelope.self, from: body) else { return nil }
        var payload: Data?
        switch envelope.type {
        case MessageType.fileChunk: payload = envelope.file?.data.flatMap { Data(base64Encoded: $0) }; envelope.file?.data = nil
        case MessageType.audioFrame: payload = envelope.audio.flatMap { Data(base64Encoded: $0) }; envelope.audio = nil
        default: payload = envelope.video.flatMap { Data(base64Encoded: $0) }; envelope.video = nil
        }
        return (envelope, payload, false)
    }

    /// The length word an app before bin1 accepts: 1 to 1 MiB, top bit clear.
    private static func oldAppAccepts(_ frame: Data?) -> Bool {
        guard let frame, frame.count >= 4 else { return false }
        let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return length > 0 && length <= PhoneLinkProtocol.maxFrameBytes && length == frame.count - 4
    }

    static func run(_ check: (String, Bool) -> Void) {
        let bytes = Data((0..<70_001).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

        // Each converted message reads back the same, binary or JSON.
        for type in [MessageType.macScreenFrame, MessageType.screenFrame, MessageType.cameraFrame, MessageType.audioFrame] {
            for key in [true, false] {
                let keyFrame: Bool? = type == MessageType.audioFrame ? nil : key
                let binary = read(PeerSession.mediaFrame(type: type, data: bytes, keyFrame: keyFrame, binary: true))
                let json = read(PeerSession.mediaFrame(type: type, data: bytes, keyFrame: keyFrame, binary: false))
                check("binary \(type) key=\(key) reads back like JSON",
                      binary?.binary == true && json?.binary == false && binary?.envelope.type == type && json?.envelope.type == type
                      && binary?.payload == bytes && json?.payload == bytes
                      && (binary?.envelope.keyFrame == true) == (json?.envelope.keyFrame == true))
            }
        }
        let id = "a\"b\\c/é-9f1c"
        let chunkBinary = read(PeerSession.chunkFrame(id: id, data: bytes, binary: true))
        let chunkJson = read(PeerSession.chunkFrame(id: id, data: bytes, binary: false))
        check("binary file.chunk reads back like JSON", chunkBinary?.binary == true && chunkBinary?.envelope.file?.id == id
              && chunkJson?.envelope.file?.id == id && chunkBinary?.payload == bytes && chunkJson?.payload == bytes
              && chunkBinary?.envelope.file?.data == nil)
        let emptyChunk = read(PeerSession.chunkFrame(id: "e", data: Data(), binary: true))
        check("binary empty payload", emptyChunk?.payload == Data() && emptyChunk?.envelope.file?.id == "e")
        let large = Data(count: 1000 * 1024)
        check("binary frame fits what base64 can't", PeerSession.mediaFrame(type: MessageType.macScreenFrame, data: large, keyFrame: true, binary: true) != nil
              && PeerSession.mediaFrame(type: MessageType.macScreenFrame, data: large, keyFrame: true, binary: false) == nil)
        check("binary frame over 1 MiB dropped",
              PeerSession.mediaFrame(type: MessageType.audioFrame, data: Data(count: PhoneLinkProtocol.maxFrameBytes), keyFrame: nil, binary: true) == nil)
        check("binary file chunk saves a quarter",
              (PeerSession.chunkFrame(id: "x", data: Data(count: PhoneLinkProtocol.chunkBytes), binary: true)?.count ?? 0) * 4
              < (PeerSession.chunkFrame(id: "x", data: Data(count: PhoneLinkProtocol.chunkBytes), binary: false)?.count ?? 0) * 3 + 400)

        // Fixed vectors, byte for byte the same as the Kotlin core.
        check("binary vector file.chunk", hex(PeerSession.chunkFrame(id: "abc", data: Data([0, 1, 2, 0xff]), binary: true)) == vectorChunk)
        check("binary vector macscreen.frame", hex(PeerSession.mediaFrame(type: MessageType.macScreenFrame, data: Data([0, 0, 0, 1, 0x65]),
                                                                       keyFrame: true, binary: true)) == vectorVideo)
        check("binary vector audio.frame", hex(PeerSession.mediaFrame(type: MessageType.audioFrame, data: Data([1, 0, 0xff, 0xff]),
                                                                   keyFrame: nil, binary: true)) == vectorAudio)

        // Malformed binary frames are refused, never read past their end.
        func body(_ headerLength: Int, _ header: String, _ payload: [UInt8] = []) -> Data {
            Data([UInt8(headerLength >> 8), UInt8(headerLength & 0xff)]) + Data(header.utf8) + Data(payload)
        }
        let good = #"{"type":"audio.frame"}"#
        check("binary parse ok", BinaryFrame.parse(body(good.utf8.count, good, [1, 2]))?.1 == Data([1, 2]))
        check("binary header length past the end refused", BinaryFrame.parse(body(good.utf8.count + 3, good, [1, 2])) == nil)
        check("binary header length 0 refused", BinaryFrame.parse(body(0, "", [1, 2, 3])) == nil)
        check("binary truncated header refused", BinaryFrame.parse(body(good.utf8.count, String(good.prefix(10)))) == nil)
        check("binary header not JSON refused", BinaryFrame.parse(body(5, "nope!", [1])) == nil)
        check("binary header not a message refused", BinaryFrame.parse(body(2, "{}", [1])) == nil)
        check("binary too short refused", BinaryFrame.parse(Data([0])) == nil && BinaryFrame.parse(Data()) == nil)
        check("binary slice parses", BinaryFrame.parse((Data([9, 9]) + body(good.utf8.count, good, [7])).dropFirst(2))?.1 == Data([7]))
        check("binary length over 1 MiB refused", BinaryFrame.length(word: BinaryFrame.flag | UInt32(PhoneLinkProtocol.maxFrameBytes + 1)) == nil)
        check("binary length too small refused", BinaryFrame.length(word: BinaryFrame.flag | 2) == nil && BinaryFrame.length(word: BinaryFrame.flag) == nil)
        check("binary length all ones refused", BinaryFrame.length(word: 0xFFFF_FFFF) == nil)
        check("JSON length still read", BinaryFrame.length(word: 10).map { !$0.binary && $0.length == 10 } == true
              && BinaryFrame.length(word: 0) == nil && BinaryFrame.length(word: UInt32(PhoneLinkProtocol.maxFrameBytes + 1)) == nil)

        // Negotiation: binary only after both hellos listed bin1; only the first hello each way counts.
        func hello(_ caps: [String]?) -> Envelope {
            Envelope(type: MessageType.hello, hello: Hello(name: "x", platform: "android", model: "m", protocolVersion: 3, paired: true, caps: caps))
        }
        var none = BinaryNegotiation()
        none.sent(hello(["bin1"]))
        none.received(hello(nil))
        check("negotiation: an older peer gets JSON", !none.binary)
        var both = BinaryNegotiation()
        check("negotiation: JSON before any hello", !both.binary)
        both.sent(hello(["bin1"]))
        check("negotiation: JSON until the peer's hello", !both.binary)
        both.received(hello(["future", "bin1"]))
        check("negotiation: binary once both listed it", both.binary)
        both.received(hello(nil))
        check("negotiation: a second hello changes nothing", both.binary)
        var quiet = BinaryNegotiation()
        quiet.sent(hello(nil))
        quiet.received(hello(["bin1"]))
        check("negotiation: caps off here sends JSON", !quiet.binary)
        var other = BinaryNegotiation()
        other.sent(hello(["bin1"]))
        other.received(hello(["bin2"]))
        check("negotiation: an unknown cap isn't bin1", !other.binary)
        // Older apps ignore caps; the hello still reads without it, and old frames stay what old apps accept.
        let oldHello = try? JSONDecoder().decode(Envelope.self, from: Data(#"{"type":"hello","hello":{"name":"a","platform":"android","model":"m","protocolVersion":2,"paired":false}}"#.utf8))
        check("negotiation: hello without caps reads", oldHello?.hello?.caps == nil && oldHello?.hello?.name == "a")
        let encodedHello = (try? JSONEncoder().encode(hello(["bin1"]))).flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }
        check("negotiation: caps go out in hello", BinaryFrame.supports(encodedHello?.hello))
        check("old apps accept every JSON media frame", oldAppAccepts(PeerSession.chunkFrame(id: "x", data: bytes, binary: false))
              && oldAppAccepts(PeerSession.mediaFrame(type: MessageType.macScreenFrame, data: bytes, keyFrame: false, binary: false))
              && !oldAppAccepts(PeerSession.mediaFrame(type: MessageType.macScreenFrame, data: bytes, keyFrame: false, binary: true)))

        // Silence: 200 ms of it still goes out, then nothing until sound comes back.
        let quietChunk = Data(count: 7680)
        var loud = Data(count: 7680)
        loud[101] = 0x01 // sample 50 = 256
        var tiny = Data(count: 7680)
        tiny[0] = 0xF8; tiny[1] = 0xFF // -8
        check("silence: zeros and -8 are silent, 256 isn't", SilenceGate.isSilent(quietChunk) && SilenceGate.isSilent(tiny) && !SilenceGate.isSilent(loud))
        var gate = SilenceGate()
        let pattern = [false] + Array(repeating: true, count: 8) + [false, true]
        let sent = pattern.map { gate.shouldSend(silent: $0) }
        check("silence: held after 200 ms, back with sound",
              sent == [true, true, true, true, true, true, false, false, false, true, true])
    }
}
#endif
