import Foundation
import Network
import Security

/// One TLS connection with one device.
///
/// The connection runs on the session's own serial queue: framing, JSON, and the base64 of large payloads (file
/// chunks, video, sound) never touch the main thread. Callbacks arrive on the main queue in the order the messages
/// came, and `deviceId`, `hello`, and the callbacks belong to the main thread.
///
/// Sending has two lanes. Live messages (input, sound, screen, pings, pairing, everything else) go out at once.
/// Bulk messages (`file.*` and `clipboard.history`) wait in their own queue and only go out while little bulk data
/// is on its way, so a large file never holds up the pointer, sound, or picture. The amount on its way is measured
/// with the ordinary `ping`/`pong`: a ping follows every few chunks, and its pong says the other side has read
/// everything before it. Every DyskLink answers ping; one that doesn't answer within a few seconds just gets the
/// bulk data without that limit.
final class PeerSession: @unchecked Sendable {
    let connection: NWConnection
    /// Main thread only. Set just before `onReady`.
    private(set) var deviceId: String?
    /// Main thread only.
    var hello: Hello?

    var onReady: ((PeerSession) -> Void)?
    /// The message, and for `file.chunk`, `screen.frame`, `camera.frame`, and `audio.frame` its payload already
    /// decoded from base64 (the base64 field is then cleared). The payload is nil when the base64 was invalid.
    var onMessage: ((PeerSession, Envelope, Data?) -> Void)?
    var onClose: ((PeerSession) -> Void)?

    /// Set on connections this Mac dials, before `start`: `.waiting` (no route, refused) counts as failed, so it can
    /// dial again.
    var failsWhenWaiting = false
    /// Main thread only: `onClose` already ran.
    private var reportedClose = false

    // Everything below belongs to `queue`.
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var closed = false
    private var bulk: [(frame: Data, handed: (Bool) -> Void)] = []
    /// Bulk frames given to the connection that it hasn't taken yet.
    private var bulkInFlight = 0
    /// Bulk bytes sent, bytes the other side confirmed with a pong, and where the last ping was sent.
    private var bulkSent = 0
    private var bulkAcked = 0
    private var bulkMarked = 0
    /// Pings sent and not answered yet, oldest first. `mark` is the bulk byte count it confirms.
    private var pings: [(at: DispatchTime, mark: Int?, answer: ((Double) -> Void)?)] = []
    /// The other side didn't answer a ping in time, so bulk data goes out without waiting for pongs.
    private var windowOff = false
    private var windowCheckScheduled = false
    /// Bulk bytes a second the other side confirmed, smoothed; sets how long a pong may take.
    private var ackRate: Double = 0
    private var lastAck: (at: DispatchTime, mark: Int)?
    /// Bytes of messages handed to the main thread that it hasn't handled yet. Reading stops above
    /// `receiveHighWater` and goes on once they are handled, so a fast sender can't fill memory.
    private var deliveredPending = 0
    private var receivePaused = false
    static let receiveHighWater = 8 * 1024 * 1024
    #if DEBUG
    private let readMegabytesPerSecond = TestEnv.value("PHONELINK_TEST_READ_MBPS").flatMap(Double.init) ?? 0
    #endif

    static let bulkTypes: Set<String> = [
        MessageType.fileOffer, MessageType.fileChunk, MessageType.fileDone, MessageType.fileCancel, MessageType.clipboardHistory,
    ]
    static let maxBulkInFlight = 2
    /// At most this many bulk bytes sent and not yet confirmed by a pong.
    static let bulkWindow = 512 * 1024
    /// A ping goes out after this many bulk bytes.
    static let bulkMarkEvery = 128 * 1024
    /// Seconds without a pong before the window is given up for this connection, at the least; a slow link that
    /// still confirms data gets as long as a window takes at its measured speed, up to `maxPongTimeout`.
    static let pongTimeout = 3.0
    static let maxPongTimeout = 30.0

    /// How long a pong may take when the other side confirms `rate` bulk bytes a second.
    static func pongTimeout(rate: Double) -> Double {
        guard rate > 0 else { return pongTimeout }
        return min(maxPongTimeout, max(pongTimeout, 2 * Double(bulkWindow) / rate + 1))
    }
    private static let pingFrame = PeerSession.rawFrame(Data(#"{"type":"ping"}"#.utf8))

    init(connection: NWConnection) {
        self.connection = connection
        queue = DispatchQueue(label: "dysklink.peer", qos: .userInitiated)
    }

    /// Connections from this Mac itself come through `adb reverse`, which means a USB cable.
    var isLoopback: Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || "\(address)".hasSuffix("127.0.0.1")
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    /// Call on the main thread.
    func start() {
        let failsWhenWaiting = failsWhenWaiting
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let id = self.peerFingerprint() else { return self.closeOnQueue() }
                DispatchQueue.main.async {
                    guard !self.reportedClose else { return }
                    self.deviceId = id
                    self.onReady?(self)
                }
                self.receiveHeader()
            case .failed, .cancelled:
                self.closeOnQueue()
            case .waiting:
                if failsWhenWaiting { self.closeOnQueue() }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Sending

    /// The length-prefixed frame, or nil when it's larger than the other side accepts. Such a frame would make the
    /// receiver close the connection, so it's dropped here and the connection stays up.
    private func frame(_ envelope: Envelope) -> Data? {
        guard let payload = try? encoder.encode(envelope) else { return nil }
        return Self.checked(Self.rawFrame(payload), type: envelope.type)
    }

    private static func rawFrame(_ payload: Data) -> Data {
        var frame = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private static func checked(_ frame: Data, type: String) -> Data? {
        let size = frame.count - 4
        guard size <= PhoneLinkProtocol.maxFrameBytes else {
            print("Dropped a \(type) message of \(size) bytes, over the \(PhoneLinkProtocol.maxFrameBytes)-byte limit")
            return nil
        }
        return frame
    }

    /// `{"type":<type>,<fields>"<base64>"<after>}` built straight into the frame, without a JSON pass over the
    /// base64 text. The same JSON the encoder makes, apart from `/` not being escaped, which JSON doesn't require.
    static func base64Frame(type: String, fields: String, data: Data, after: String = "") -> Data? {
        let open = Data(#"{"type":\#(jsonString(type)),\#(fields)""#.utf8)
        let close = Data(("\"" + after + "}").utf8)
        let size = open.count + (data.count + 2) / 3 * 4 + close.count
        var frame = Data(capacity: size + 4)
        var length = UInt32(size).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(open)
        frame.append(data.base64EncodedData())
        frame.append(close)
        return checked(frame, type: type)
    }

    /// A JSON string literal, escaped as the encoder would.
    static func jsonString(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }) {
            return "\"" + text + "\""
        }
        return (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// Sends from any thread. `completion`, if given, runs on the main queue once the network took the data (for a
    /// bulk message, once it went out of the bulk queue), so senders can tell when it falls behind.
    func send(_ envelope: Envelope, completion: ((Bool) -> Void)? = nil) {
        let done = completion.map { completion in { (ok: Bool) in DispatchQueue.main.async { completion(ok) } } }
        queue.async { [self] in
            guard !closed, let frame = frame(envelope) else { done?(false); return }
            enqueue(frame, bulk: Self.bulkTypes.contains(envelope.type), done: done)
        }
    }

    /// A message with one large base64 field, made from `data` on the session queue: `macscreen.frame` with
    /// `video`, or `audio.frame` with `audio`. `after` is more JSON after it, such as `,"keyFrame":true`.
    /// `completion` runs on the main queue.
    func sendBase64(type: String, field: String, data: Data, after: String = "", completion: ((Bool) -> Void)? = nil) {
        let done = completion.map { completion in { (ok: Bool) in DispatchQueue.main.async { completion(ok) } } }
        queue.async { [self] in
            guard !closed, let frame = Self.base64Frame(type: type, fields: "\(Self.jsonString(field)):", data: data, after: after)
            else { done?(false); return }
            enqueue(frame, bulk: Self.bulkTypes.contains(type), done: done)
        }
    }

    /// Waits until the message went out, so large files don't pile up in memory. A bulk message counts as gone once
    /// it left the bulk queue.
    func sendAndWait(_ envelope: Envelope) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed, let frame = frame(envelope) else { return continuation.resume(returning: false) }
                enqueue(frame, bulk: Self.bulkTypes.contains(envelope.type)) { continuation.resume(returning: $0) }
            }
        }
    }

    /// One `file.chunk`. The base64 and JSON are made on the caller's thread, then it waits its turn in the bulk lane.
    func sendChunk(id: String, data: Data) async -> Bool {
        guard let frame = Self.base64Frame(type: MessageType.fileChunk, fields: #""file":{"id":\#(Self.jsonString(id)),"data":"#,
                                           data: data, after: "}") else { return false }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed else { return continuation.resume(returning: false) }
                enqueue(frame, bulk: true) { continuation.resume(returning: $0) }
            }
        }
    }

    /// Sends a ping; `answer` gets the milliseconds until its pong, on the session queue.
    func ping(answer: @escaping (Double) -> Void) {
        let at = DispatchTime.now()
        queue.async { [self] in
            guard !closed else { return }
            pings.append((at, nil, answer))
            write(Self.pingFrame, done: nil)
        }
    }

    private func enqueue(_ frame: Data, bulk isBulk: Bool, done: ((Bool) -> Void)?) {
        guard isBulk else { return write(frame, done: done) }
        bulk.append((frame, done ?? { _ in }))
        pumpBulk()
    }

    private func write(_ frame: Data, done: ((Bool) -> Void)?) {
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.closeOnQueue() }
            done?(error == nil)
        })
    }

    private func pumpBulk() {
        while !closed, !bulk.isEmpty, bulkInFlight < Self.maxBulkInFlight,
              windowOff || bulkSent - bulkAcked < Self.bulkWindow {
            let item = bulk.removeFirst()
            bulkInFlight += 1
            bulkSent += item.frame.count
            connection.send(content: item.frame, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.bulkInFlight -= 1
                if error != nil { self.closeOnQueue() } else { self.pumpBulk() }
            })
            item.handed(true)
            // With the window off, one mark at a time stays out, so a pong that comes late can turn it back on.
            if bulkSent - bulkMarked >= Self.bulkMarkEvery, !windowOff || !pings.contains(where: { $0.mark != nil }) {
                sendMark()
            }
        }
        if !closed, !bulk.isEmpty, !windowOff, bulkSent - bulkAcked >= Self.bulkWindow { scheduleWindowCheck() }
    }

    private func sendMark() {
        bulkMarked = bulkSent
        pings.append((DispatchTime.now(), bulkSent, nil))
        write(Self.pingFrame, done: nil)
    }

    /// While bulk data waits for a pong, checks that pongs still come.
    private func scheduleWindowCheck() {
        guard !windowCheckScheduled else { return }
        windowCheckScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.windowCheckScheduled = false
            guard !self.closed else { return }
            if let oldest = self.pings.first(where: { $0.mark != nil }),
               Double(DispatchTime.now().uptimeNanoseconds - oldest.at.uptimeNanoseconds) / 1e9 > Self.pongTimeout(rate: self.ackRate) {
                print("No pong within \(Self.pongTimeout(rate: self.ackRate)) s; bulk data now goes out without waiting")
                self.windowOff = true
            }
            self.pumpBulk()
        }
    }

    private func pongArrived() {
        guard !pings.isEmpty else { return }
        let ping = pings.removeFirst()
        if let mark = ping.mark {
            let now = DispatchTime.now()
            if let lastAck, mark > lastAck.mark, now.uptimeNanoseconds > lastAck.at.uptimeNanoseconds {
                let rate = Double(mark - lastAck.mark) / (Double(now.uptimeNanoseconds - lastAck.at.uptimeNanoseconds) / 1e9)
                ackRate = ackRate == 0 ? rate : ackRate * 0.7 + rate * 0.3
            }
            lastAck = (now, mark)
            bulkAcked = max(bulkAcked, mark)
            if windowOff {
                // A late pong: the other side does answer, so the window comes back, starting from a fresh mark.
                print("A late pong came; bulk data waits for pongs again")
                windowOff = false
                if bulkSent > bulkAcked { sendMark() }
            }
        }
        ping.answer?(Double(DispatchTime.now().uptimeNanoseconds - ping.at.uptimeNanoseconds) / 1e6)
        pumpBulk()
    }

    // MARK: - Closing

    /// Call on the main thread. `onClose` runs before this returns, as it always did.
    func close() {
        dispatchPrecondition(condition: .onQueue(.main))
        connection.cancel()
        queue.async { [self] in markClosed() }
        reportClose()
    }

    private func closeOnQueue() {
        connection.cancel()
        guard markClosed() else { return }
        DispatchQueue.main.async { self.reportClose() }
    }

    /// Returns false when it was already closed.
    @discardableResult
    private func markClosed() -> Bool {
        guard !closed else { return false }
        closed = true
        let waiting = bulk
        bulk = []
        pings = []
        waiting.forEach { $0.handed(false) }
        return true
    }

    private func reportClose() {
        guard !reportedClose else { return }
        reportedClose = true
        onClose?(self)
    }

    private func peerFingerprint() -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        var leaf: SecCertificate?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if leaf == nil {
                leaf = sec_certificate_copy_ref(certificate).takeRetainedValue()
            }
        }
        return leaf.map { Hex.sha256(SecCertificateCopyData($0) as Data) }
    }

    // MARK: - Receiving

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 4 else {
                if isComplete || error != nil { self.closeOnQueue() }
                return
            }
            let length = data.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= PhoneLinkProtocol.maxFrameBytes else { return self.closeOnQueue() }
            self.receiveBody(length: length)
        }
    }

    private func receiveBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else { return self.closeOnQueue() }
            if let (envelope, payload) = self.decode(data) {
                if envelope.type == MessageType.pong { self.pongArrived() }
                self.deliveredPending += length
                DispatchQueue.main.async {
                    if !self.reportedClose { self.onMessage?(self, envelope, payload) }
                    self.queue.async { self.handled(length) }
                }
            }
            if self.deliveredPending > Self.receiveHighWater {
                self.receivePaused = true
                return
            }
            #if DEBUG
            // Tests only: reads no faster than this many megabytes a second, like a slow Wi-Fi network.
            if self.readMegabytesPerSecond > 0 {
                return self.queue.asyncAfter(deadline: .now() + Double(length + 4) / (self.readMegabytesPerSecond * 1_000_000)) {
                    self.receiveHeader()
                }
            }
            #endif
            self.receiveHeader()
        }
    }

    /// The main thread handled a message of `length` bytes; reading goes on once most of the backlog is gone.
    private func handled(_ length: Int) {
        deliveredPending -= length
        guard receivePaused, deliveredPending <= Self.receiveHighWater / 2, !closed else { return }
        receivePaused = false
        receiveHeader()
    }

    /// The message, with the large base64 payloads decoded here instead of on the main thread.
    private func decode(_ data: Data) -> (Envelope, Data?)? {
        guard var envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        var payload: Data?
        switch envelope.type {
        case MessageType.fileChunk:
            guard envelope.file != nil else { break }
            payload = Data(base64Encoded: envelope.file?.data ?? "")
            envelope.file?.data = nil
        case MessageType.screenFrame, MessageType.cameraFrame:
            guard let text = envelope.video else { break }
            payload = Data(base64Encoded: text)
            envelope.video = nil
        case MessageType.audioFrame:
            guard let text = envelope.audio else { break }
            payload = Data(base64Encoded: text)
            envelope.audio = nil
        default:
            break
        }
        return (envelope, payload)
    }
}
