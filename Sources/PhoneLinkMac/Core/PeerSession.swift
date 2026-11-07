import Foundation
import Network
import Security

/// One TLS connection with one phone. All callbacks run on the main queue.
final class PeerSession {
    let connection: NWConnection
    private(set) var deviceId: String?
    var hello: Hello?

    var onReady: ((PeerSession) -> Void)?
    var onMessage: ((PeerSession, Envelope) -> Void)?
    var onClose: ((PeerSession) -> Void)?

    private var closed = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.deviceId = self.peerFingerprint()
                guard self.deviceId != nil else { return self.close() }
                self.onReady?(self)
                self.receiveHeader()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    func send(_ envelope: Envelope) {
        guard !closed, let payload = try? encoder.encode(envelope) else { return }
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    /** Waits for the network to take the data, so large files don't pile up in memory. */
    func sendAndWait(_ envelope: Envelope) async -> Bool {
        guard !closed, let payload = try? encoder.encode(envelope) else { return false }
        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return await withCheckedContinuation { continuation in
            connection.send(content: frame, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    func close() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
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

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 4 else {
                if isComplete || error != nil { self.close() }
                return
            }
            let length = data.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= PhoneLinkProtocol.maxFrameBytes else { return self.close() }
            self.receiveBody(length: length)
        }
    }

    private func receiveBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else { return self.close() }
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
                self.onMessage?(self, envelope)
            }
            self.receiveHeader()
        }
    }
}
