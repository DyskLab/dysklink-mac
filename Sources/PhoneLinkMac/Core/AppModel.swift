import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import UniformTypeIdentifiers
import ServiceManagement

struct PairedRecord: Codable, Equatable {
    var name: String
    var platform: String
    var model: String
    var pairedAt: Date
}

/// One device in the UI, from an active connection, pairing data, or both.
struct Peer: Identifiable, Equatable {
    let id: String
    var name: String
    var platform: String
    var model: String
    var isPaired: Bool
    var isConnected: Bool
    var info: DeviceInfo?
    var lastSeen: Date?
}

struct PairingPrompt: Identifiable, Equatable {
    var id: String { peerId }
    let peerId: String
    let peerName: String
    let code: String
    let startedByPeer: Bool
    var localAccepted = false
}

@MainActor
@Observable
final class AppModel {
    enum ServerState: Equatable {
        case starting
        case listening
        case failed(String)
    }

    private(set) var serverState: ServerState = .starting
    private(set) var peers: [Peer] = []
    private(set) var addresses: [String] = []
    var pairingPrompt: PairingPrompt?
    var selectedPeerId: String?
    var showsTools = false
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    private(set) var loginProblem: String?

    /// Called when a pairing needs the user, even if the window is closed.
    @ObservationIgnored var onNeedsAttention: (() -> Void)?

    var hasPairedDevices: Bool { !records.isEmpty }

    private(set) var transfers: [Transfer] = []
    private(set) var commands: [SavedCommand] = []
    private(set) var isInputTrusted = DeviceInput.isTrusted
    var newCommandName = ""
    var newCommandScript = ""
    var clipboardEnabled = UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(clipboardEnabled, forKey: "clipboardEnabled") }
    }

    /// Phone data is kept in memory only, and cleared when the phone turns the feature off or unpairs.
    private(set) var phoneData: [String: PhoneSnapshot] = [:]
    var peerTab: PeerTab = .overview
    var contactQuery = ""
    var smsThread: Int64?
    var smsAddress = ""
    var smsDraft = ""

    private(set) var screen: ScreenSession?
    private(set) var screenRequests: Set<String> = []
    private(set) var screenError: [String: String] = [:]

    var localName: String { LocalDevice.name }

    @ObservationIgnored private var identity: LocalIdentity?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sessions: [String: PeerSession] = [:]
    @ObservationIgnored private var retained: [ObjectIdentifier: PeerSession] = [:]
    @ObservationIgnored private var records: [String: PairedRecord] = [:]
    @ObservationIgnored private var infos: [String: DeviceInfo] = [:]
    @ObservationIgnored private var lastSeen: [String: Date] = [:]
    @ObservationIgnored private var remoteAccepted: Set<String> = []
    @ObservationIgnored private var networkName: String?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var infoTimer: Timer?
    @ObservationIgnored private var pairingTimeout: Task<Void, Never>?
    @ObservationIgnored private let clipboard = ClipboardWatcher()
    @ObservationIgnored private var incomingFiles: [String: IncomingFile] = [:]
    @ObservationIgnored private var cancelledSends: Set<String> = []
    @ObservationIgnored private var incomingContacts: [String: [ContactItem]] = [:]
    @ObservationIgnored private let notifier = MacNotifier()
    @ObservationIgnored private var didProbePhone = false
    @ObservationIgnored private let decoder = VideoDecoder()
    @ObservationIgnored private var lastSyncRequest = Date.distantPast
    @ObservationIgnored private var didShowTrustCard = false
    @ObservationIgnored private var trustTimer: Timer?

    private var directory: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PHONELINK_DATA_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneLink", isDirectory: true)
    }
    private var recordsURL: URL { directory.appendingPathComponent("paired.json") }
    private var commandsURL: URL { directory.appendingPathComponent("commands.json") }
    private var downloadFolder: URL {
        if let path = TestEnv.value("PHONELINK_DOWNLOAD_DIR") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DyskLink", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            loadRecords()
            loadCommands()
            let identity = try LocalIdentity.loadOrCreate(in: directory)
            self.identity = identity
            try startListener(identity: identity)
            startNetworkMonitor()
            startInfoTimer()
            clipboard.onChange = { [weak self] text in self?.shareClipboard(text) }
            clipboard.start()
            rebuildPeers()
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    private func startListener(identity: LocalIdentity) throws {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        guard let localIdentity = sec_identity_create(identity.identity) else {
            throw LocalIdentity.Failure.importFailed(errSecParam)
        }
        sec_protocol_options_set_local_identity(security, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(security, true)
        // Self-signed certificate. Trust comes from the fingerprint at pairing.
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, .main)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.noDelay = true

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        parameters.allowLocalEndpointReuse = true

        let testPort = TestEnv.value("PHONELINK_PORT").flatMap(UInt16.init)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: testPort ?? PhoneLinkProtocol.port)!)
        // Test instances aren't advertised, so real phones don't find them.
        if testPort == nil {
            listener.service = NWListener.Service(name: LocalDevice.name, type: PhoneLinkProtocol.serviceType)
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.serverState = .listening
                case .failed(let error): self?.serverState = .failed(error.localizedDescription)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.addresses = LocalDevice.ipv4Addresses()
                    if path.usesInterfaceType(.wifi) { self.networkName = "Wi-Fi" }
                    else if path.usesInterfaceType(.wiredEthernet) { self.networkName = "Ethernet" }
                    else { self.networkName = nil }
                    self.broadcastInfo()
                }
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    private func startInfoTimer() {
        infoTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcastInfo() }
        }
        // The permission can change in Settings at any time, and the phone needs to know quickly.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isInputTrusted != DeviceInput.isTrusted else { return }
                self.isInputTrusted = DeviceInput.isTrusted
                self.broadcastInfo()
            }
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let session = PeerSession(connection: connection)
        let key = ObjectIdentifier(session)
        retained[key] = session
        session.onReady = { [weak self] session in
            MainActor.assumeIsolated { self?.sessionReady(session) }
        }
        session.onMessage = { [weak self] session, envelope in
            MainActor.assumeIsolated { self?.handle(envelope, from: session) }
        }
        session.onClose = { [weak self] session in
            MainActor.assumeIsolated { self?.sessionClosed(session) }
        }
        session.start()
    }

    private func sessionReady(_ session: PeerSession) {
        guard let id = session.deviceId else { return session.close() }
        // A connection is registered when hello arrives, because the phone closes duplicates before hello.
        session.send(Envelope(type: MessageType.hello, hello: LocalDevice.hello(paired: records[id] != nil)))
    }

    private func sessionClosed(_ session: PeerSession) {
        retained[ObjectIdentifier(session)] = nil
        guard let id = session.deviceId, sessions[id] === session else { return }
        sessions[id] = nil
        lastSeen[id] = Date()
        cancelIncomingFiles(from: id)
        // The phone resends active notifications when it reconnects.
        phoneData[id]?.notifications = []
        phoneData[id]?.filesLoading = false
        screenRequests.remove(id)
        if screen?.peerId == id { endScreen() }
        for index in transfers.indices where transfers[index].peerId == id && transfers[index].status == .active {
            transfers[index].status = .failed
            transfers[index].detail = "Connection lost"
        }
        if pairingPrompt?.peerId == id { clearPairing() }
        rebuildPeers()
    }

    private func handle(_ envelope: Envelope, from session: PeerSession) {
        guard let id = session.deviceId else { return }
        // Every message except hello only applies to registered connections.
        guard envelope.type == MessageType.hello || sessions[id] === session else { return }
        switch envelope.type {
        case MessageType.hello:
            guard let hello = envelope.hello else { return }
            // The newest connection replaces the old one, which may be dead.
            if let old = sessions[id], old !== session { old.close() }
            sessions[id] = session
            session.hello = hello
            if records[id] != nil {
                if hello.paired {
                    records[id]?.name = hello.name
                    records[id]?.model = hello.model
                    saveRecords()
                    sendInitialState(to: session)
                } else {
                    removeRecord(id)
                }
            }
            rebuildPeers()
        case MessageType.pairRequest:
            guard records[id] == nil, session.hello != nil else { return }
            beginPairing(with: id, startedByPeer: true)
        case MessageType.pairAccept:
            guard pairingPrompt?.peerId == id else { return }
            remoteAccepted.insert(id)
            finishPairingIfReady(id)
        case MessageType.pairReject:
            if pairingPrompt?.peerId == id { clearPairing() }
        case MessageType.unpair:
            removeRecord(id)
            rebuildPeers()
        case MessageType.info:
            guard records[id] != nil, let info = envelope.info else { return }
            infos[id] = info
            #if DEBUG
            print("INFO \(hello(of: session)) battery=\(info.batteryPercent.map(String.init) ?? "-") os=\(info.osVersion ?? "-")")
            #endif
            rebuildPeers()
        case MessageType.ping:
            session.send(Envelope(type: MessageType.pong))
        case MessageType.clipboard:
            guard records[id] != nil else { return }
            var receipt = Envelope(type: MessageType.clipboardAck, key: envelope.key)
            if !clipboardEnabled {
                receipt.error = "Automatic clipboard is turned off on the Mac"
            } else if let text = envelope.text, !text.isEmpty, text.count <= PhoneLinkProtocol.maxClipboardChars {
                clipboard.set(text)
            } else {
                receipt.error = "Invalid clipboard text"
            }
            // Only the phone asks for a receipt, because its connection can die without warning.
            if envelope.key != nil { session.send(receipt) }
        case MessageType.media:
            guard records[id] != nil, let action = envelope.media else { return }
            showTrustCardIfNeeded()
            DeviceInput.media(action)
        case MessageType.input:
            guard records[id] != nil, let input = envelope.input else { return }
            showTrustCardIfNeeded()
            DeviceInput.handle(input)
        case MessageType.commandRun:
            guard records[id] != nil, let commandId = envelope.commandId else { return }
            runCommand(commandId, for: session)
        case MessageType.fileOffer, MessageType.fileChunk, MessageType.fileDone,
             MessageType.fileCancel, MessageType.fileResult:
            guard records[id] != nil, let file = envelope.file else { return }
            handleFile(type: envelope.type, file: file, from: id, session: session)
        case MessageType.screenStarted, MessageType.screenFrame, MessageType.screenStopped:
            guard records[id] != nil else { return }
            handleScreen(envelope, from: id, session: session)
        case MessageType.features, MessageType.notificationPosted, MessageType.notificationRemoved,
             MessageType.smsMessages, MessageType.smsNew, MessageType.smsResult, MessageType.call,
             MessageType.contacts, MessageType.fsListing:
            guard records[id] != nil else { return }
            handlePhone(envelope, from: id, session: session)
        default:
            break
        }
    }

    // MARK: - Pairing

    func requestPairing(with id: String) {
        guard records[id] == nil, let session = sessions[id] else { return }
        session.send(Envelope(type: MessageType.pairRequest))
        beginPairing(with: id, startedByPeer: false)
    }

    func acceptPairing() {
        guard var prompt = pairingPrompt, let session = sessions[prompt.peerId] else { return }
        prompt.localAccepted = true
        pairingPrompt = prompt
        session.send(Envelope(type: MessageType.pairAccept))
        finishPairingIfReady(prompt.peerId)
    }

    func rejectPairing() {
        guard let prompt = pairingPrompt else { return }
        sessions[prompt.peerId]?.send(Envelope(type: MessageType.pairReject))
        clearPairing()
    }

    func unpair(_ id: String) {
        sessions[id]?.send(Envelope(type: MessageType.unpair))
        removeRecord(id)
        rebuildPeers()
    }

    private func beginPairing(with id: String, startedByPeer: Bool) {
        guard let identity, let hello = sessions[id]?.hello else { return }
        // Only one request is active. Others are refused.
        if let current = pairingPrompt, current.peerId != id {
            sessions[id]?.send(Envelope(type: MessageType.pairReject))
            return
        }
        if pairingPrompt?.peerId == id { return }
        remoteAccepted.remove(id)
        pairingPrompt = PairingPrompt(
            peerId: id, peerName: hello.name,
            code: Pairing.code(identity.deviceId, id), startedByPeer: startedByPeer
        )
        onNeedsAttention?()
        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PhoneLinkProtocol.pairingTimeout))
            guard !Task.isCancelled else { return }
            self?.rejectPairing()
        }
        #if DEBUG
        // For automated tests only. Not in release builds.
        if ProcessInfo.processInfo.environment["PHONELINK_TEST_AUTO_ACCEPT"] == "1" {
            print("PAIRING_CODE \(pairingPrompt?.code ?? "")")
            acceptPairing()
        }
        #endif
    }

    private func finishPairingIfReady(_ id: String) {
        guard let prompt = pairingPrompt, prompt.peerId == id, prompt.localAccepted,
              remoteAccepted.contains(id), let session = sessions[id], let hello = session.hello
        else { return }
        records[id] = PairedRecord(name: hello.name, platform: hello.platform, model: hello.model, pairedAt: Date())
        saveRecords()
        clearPairing()
        selectedPeerId = id
        #if DEBUG
        print("PAIRING_DONE \(hello.name)")
        #endif
        sendInitialState(to: session)
        rebuildPeers()
    }

    private func clearPairing() {
        pairingTimeout?.cancel()
        pairingTimeout = nil
        if let id = pairingPrompt?.peerId { remoteAccepted.remove(id) }
        pairingPrompt = nil
    }

    // MARK: - Features

    private func sendInitialState(to session: PeerSession) {
        session.send(Envelope(type: MessageType.info, info: currentInfo()))
        sendCommandList(to: session)
        #if DEBUG
        if let path = TestEnv.value("PHONELINK_TEST_SEND_FILE"), let id = session.deviceId {
            sendFile(URL(fileURLWithPath: path), to: id)
        }
        #endif
    }

    private func shareClipboard(_ text: String) {
        guard clipboardEnabled else { return }
        for (id, session) in sessions where records[id] != nil {
            session.send(Envelope(type: MessageType.clipboard, text: text))
        }
    }

    func sendMedia(_ action: String, to id: String) {
        guard records[id] != nil else { return }
        sessions[id]?.send(Envelope(type: MessageType.media, media: action))
    }

    private func sendCommandList(to session: PeerSession) {
        // Script contents are deliberately not sent to the phone.
        let items = commands.map { CommandItem(id: $0.id, name: $0.name) }
        session.send(Envelope(type: MessageType.commandsList, commands: items))
    }

    private func runCommand(_ commandId: String, for session: PeerSession) {
        guard let command = commands.first(where: { $0.id == commandId }) else {
            let result = CommandResult(id: commandId, exitCode: -1, output: "Command not found")
            return session.send(Envelope(type: MessageType.commandResult, commandResult: result))
        }
        CommandRunner.run(command) { result in
            DispatchQueue.main.async {
                session.send(Envelope(type: MessageType.commandResult, commandResult: result))
            }
        }
    }

    func addCommand() {
        let name = newCommandName.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = newCommandScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !script.isEmpty else { return }
        commands.append(SavedCommand(id: UUID().uuidString, name: name, script: script))
        newCommandName = ""
        newCommandScript = ""
        commandsChanged()
    }

    func removeCommand(_ id: String) {
        commands.removeAll { $0.id == id }
        commandsChanged()
    }

    private func commandsChanged() {
        if let data = try? JSONEncoder().encode(commands) {
            try? data.write(to: commandsURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: commandsURL.path)
        }
        for (id, session) in sessions where records[id] != nil { sendCommandList(to: session) }
    }

    private func loadCommands() {
        guard let data = try? Data(contentsOf: commandsURL),
              let decoded = try? JSONDecoder().decode([SavedCommand].self, from: data)
        else { return }
        commands = decoded
    }

    // MARK: - Phone data

    func phone(_ id: String) -> PhoneSnapshot { phoneData[id] ?? PhoneSnapshot() }

    private static let requiredFeature: [String: String] = [
        MessageType.notificationPosted: "notifications", MessageType.notificationRemoved: "notifications",
        MessageType.smsMessages: "sms", MessageType.smsNew: "sms", MessageType.smsResult: "sms",
        MessageType.call: "calls", MessageType.contacts: "contacts", MessageType.fsListing: "files",
    ]

    private func handlePhone(_ envelope: Envelope, from id: String, session: PeerSession) {
        var data = phone(id)
        // A reply still in flight when the feature is turned off must not be stored.
        if let feature = Self.requiredFeature[envelope.type], !data.features.contains(feature) { return }
        defer { phoneData[id] = data }
        switch envelope.type {
        case MessageType.features:
            let features = Set(envelope.features ?? [])
            let wasKnown = data.isKnown
            let previous = data.features
            data.apply(features: features)
            TestEnv.log("PHONE_FEATURES \(features.sorted().joined(separator: ",")) contacts=\(data.contacts.count)")
            if !features.isDisjoint(with: ["notifications", "calls", "sms"]) { notifier.prepare() }
            if features.contains("sms") { session.send(Envelope(type: MessageType.smsList)) }
            if features.contains("contacts") { session.send(Envelope(type: MessageType.contactsList)) }
            if features.contains("files"), !wasKnown || !previous.contains("files") {
                data.beginListing("")
                session.send(Envelope(type: MessageType.fsList, path: ""))
            }
            if TestEnv.value("PHONELINK_TEST_PROBE_PHONE") == "1", features.count == 7, !didProbePhone {
                didProbePhone = true
                data.pendingSms = "uji-sms"
                probePhone(session)
            }
        case MessageType.notificationPosted:
            guard let item = envelope.notification else { return }
            data.upsert(item)
            TestEnv.log("PHONE_NOTIFICATION \(item.app) \(item.title ?? "") silent=\(item.silent == true)")
            if item.silent != true {
                notifier.show(id: "\(id):\(item.key)", title: item.title ?? item.app, subtitle: item.app, body: item.text ?? "")
            }
        case MessageType.notificationRemoved:
            guard let key = envelope.key else { return }
            data.notifications.removeAll { $0.key == key }
            notifier.remove(id: "\(id):\(key)")
            TestEnv.log("PHONE_NOTIFICATION_REMOVED \(key)")
        case MessageType.smsMessages, MessageType.smsNew:
            let items = envelope.sms ?? []
            let isNew = envelope.type == MessageType.smsNew
            let known = Set(data.messages.map(\.id))
            data.merge(items)
            TestEnv.log("PHONE_SMS \(envelope.type) \(items.map(\.body).joined(separator: "|"))")
            // With notifications on, the phone's SMS app already posts its own notification.
            if isNew, !data.features.contains("notifications") {
                for item in items where !item.outgoing && !known.contains(item.id) {
                    notifier.show(id: "\(id):sms:\(item.id)", title: data.name(for: item.address), subtitle: "SMS", body: item.body)
                }
            }
        case MessageType.smsResult:
            guard let result = envelope.smsResult, data.pendingSms == result.id else { return }
            data.pendingSms = nil
            data.smsStatus = result.ok ? .sent : .failed(result.error ?? "Failed to send SMS")
            TestEnv.log("PHONE_SMS_RESULT ok=\(result.ok)")
            if result.ok { smsDraft = "" }
        case MessageType.call:
            guard let call = envelope.call else { return }
            data.lastCall = call
            let name = call.number.map(data.name(for:)) ?? "Unknown number"
            TestEnv.log("PHONE_CALL \(call.state) \(name)")
            switch call.state {
            case "ringing": notifier.show(id: "\(id):call", title: "Incoming call", subtitle: nil, body: name)
            case "missed": notifier.show(id: "\(id):call", title: "Missed call", subtitle: nil, body: name)
            default: notifier.remove(id: "\(id):call")
            }
        case MessageType.contacts:
            incomingContacts[id, default: []].append(contentsOf: envelope.contacts ?? [])
            guard envelope.more != true else { return }
            // The list is replaced whole, so contacts deleted on the phone also leave the Mac.
            data.setContacts(incomingContacts[id] ?? [])
            incomingContacts[id] = nil
            TestEnv.log("PHONE_CONTACTS \(data.contacts.count)")
            if TestEnv.value("PHONELINK_TEST_PROBE_PHONE") == "1" {
                TestEnv.log("PHONE_VCARD \(ContactExport.vcard(data.contacts).replacingOccurrences(of: "\r\n", with: "~"))")
            }
        case MessageType.fsListing:
            data.receiveListing(path: envelope.path ?? "", entries: envelope.entries ?? [], more: envelope.more == true, error: envelope.error)
            TestEnv.log("PHONE_FS \(envelope.path ?? "") \((envelope.entries ?? []).map(\.name).joined(separator: ",")) \(envelope.error ?? "")")
        default:
            break
        }
    }

    func dismissNotification(_ key: String, on id: String) {
        guard records[id] != nil else { return }
        sessions[id]?.send(Envelope(type: MessageType.notificationDismiss, key: key))
    }

    func sendSms(to address: String, on id: String) {
        let body = smsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard records[id] != nil, let session = sessions[id], !body.isEmpty, !target.isEmpty else { return }
        let requestId = UUID().uuidString
        var data = phone(id)
        data.pendingSms = requestId
        data.smsStatus = .sending
        phoneData[id] = data
        session.send(Envelope(type: MessageType.smsSend, smsSend: SmsSend(id: requestId, address: target, body: body)))
    }

    func composeSms(to number: String) {
        smsThread = nil
        smsAddress = number
        peerTab = .messages
    }

    func openPhoneFolder(_ path: String, on id: String) {
        guard records[id] != nil, let session = sessions[id] else { return }
        var data = phone(id)
        data.beginListing(path)
        phoneData[id] = data
        session.send(Envelope(type: MessageType.fsList, path: path, hidden: data.showHidden ? true : nil))
    }

    func setShowHidden(_ show: Bool, on id: String) {
        var data = phone(id)
        data.showHidden = show
        let folder = data.folder
        phoneData[id] = data
        openPhoneFolder(folder, on: id)
    }

    func toggleFileSelection(_ name: String, on id: String) {
        var data = phone(id)
        if data.selectedFiles.remove(name) == nil { data.selectedFiles.insert(name) }
        phoneData[id] = data
    }

    func toggleSelectAllFiles(on id: String) {
        var data = phone(id)
        let files = Set(data.entries.filter { !$0.isDirectory }.map(\.name))
        data.selectedFiles = data.selectedFiles == files ? [] : files
        phoneData[id] = data
    }

    /// The phone sends only a few files at a time, so a large selection doesn't overload the connection.
    func downloadSelectedFiles(on id: String) {
        var data = phone(id)
        let names = data.selectedFiles.sorted()
        let folder = data.folder
        data.selectedFiles = []
        phoneData[id] = data
        for name in names {
            downloadPhoneFile(folder.isEmpty ? name : "\(folder)/\(name)", on: id)
        }
    }

    /// Files arrive through the normal transfer path, so they land in Downloads/DyskLink once the hash matches.
    func downloadPhoneFile(_ path: String, on id: String) {
        guard records[id] != nil else { return }
        sessions[id]?.send(Envelope(type: MessageType.fsGet, path: path))
    }

    func exportContacts(of id: String) {
        let contacts = phone(id).contacts
        guard !contacts.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Phone Contacts.vcf"
        panel.allowedContentTypes = [.vCard]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? Data(ContactExport.vcard(contacts).utf8).write(to: url, options: [.atomic])
        }
    }

    #if DEBUG
    /// Integration tests only: imitates the user, because tests can't press UI buttons.
    private func probePhone(_ session: PeerSession) {
        session.send(Envelope(type: MessageType.smsSend, smsSend: SmsSend(id: "uji-sms", address: "+620000", body: "uji")))
        session.send(Envelope(type: MessageType.notificationDismiss, key: "uji-notif"))
        session.send(Envelope(type: MessageType.fsGet, path: "folder/uji.txt"))
        session.send(Envelope(type: MessageType.screenRequest))
        session.send(Envelope(type: MessageType.control, control: ControlEvent(kind: "key", key: "home")))
    }
    #else
    private func probePhone(_ session: PeerSession) {}
    #endif

    // MARK: - Phone screen

    /// Input dropped by macOS looks like a broken app, so the window opens once to explain it.
    private func showTrustCardIfNeeded() {
        guard !TestEnv.isDryRun, !DeviceInput.isTrusted, !didShowTrustCard else { return }
        didShowTrustCard = true
        peerTab = .overview
        onNeedsAttention?()
    }

    func allowInput() {
        DeviceInput.requestTrust()
        isInputTrusted = DeviceInput.isTrusted
        broadcastInfo()
    }

    private func handleScreen(_ envelope: Envelope, from id: String, session: PeerSession) {
        switch envelope.type {
        case MessageType.screenStarted:
            guard let info = envelope.screen, info.width > 0, info.height > 0 else { return }
            // Only one phone is shown at a time.
            if let current = screen, current.peerId != id {
                return session.send(Envelope(type: MessageType.screenStop))
            }
            TestEnv.log("SCREEN_STARTED \(info.width)x\(info.height)")
            screenRequests.remove(id)
            screenError[id] = nil
            let name = session.hello?.name ?? "Phone"
            screen = ScreenSession(peerId: id, peerName: name, info: info)
            decoder.reset()
            decoder.onFrame = { buffer in
                DispatchQueue.main.async { MainActor.assumeIsolated { ScreenWindow.display(buffer) } }
            }
            if !TestEnv.isDryRun { ScreenWindow.show(model: self, peerId: id, name: name, info: info) }
            session.send(Envelope(type: MessageType.screenSync))
        case MessageType.screenFrame:
            guard screen?.peerId == id, let text = envelope.video, let data = Data(base64Encoded: text) else { return }
            if !decoder.decode(data), Date().timeIntervalSince(lastSyncRequest) > 1 {
                lastSyncRequest = Date()
                session.send(Envelope(type: MessageType.screenSync))
            }
        case MessageType.screenStopped:
            TestEnv.log("SCREEN_STOPPED \(envelope.error ?? "")")
            screenRequests.remove(id)
            screenError[id] = envelope.error
            if screen?.peerId == id { endScreen() }
        default:
            break
        }
    }

    func requestScreen(from id: String) {
        guard records[id] != nil, let session = sessions[id] else { return }
        screenError[id] = nil
        screenRequests.insert(id)
        session.send(Envelope(type: MessageType.screenRequest))
    }

    func cancelScreenRequest(for id: String) {
        screenRequests.remove(id)
    }

    func stopScreen() {
        guard let current = screen else { return }
        sessions[current.peerId]?.send(Envelope(type: MessageType.screenStop))
        endScreen()
    }

    private func endScreen() {
        screen = nil
        decoder.reset()
        decoder.onFrame = nil
        ScreenWindow.close()
    }

    func sendControl(_ event: ControlEvent, to id: String) {
        guard records[id] != nil, phone(id).features.contains("control") else { return }
        sessions[id]?.send(Envelope(type: MessageType.control, control: event))
    }

    // MARK: - File transfer

    func pickFiles(for id: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK else { return }
                panel.urls.forEach { self?.sendFile($0, to: id) }
            }
        }
    }

    /** Used when files are dragged onto the app window. */
    func sendDroppedFiles(_ urls: [URL]) -> Bool {
        guard let id = selectedPeerId, records[id] != nil, sessions[id] != nil else { return false }
        urls.filter(\.isFileURL).forEach { sendFile($0, to: id) }
        return true
    }

    func sendFile(_ url: URL, to id: String) {
        guard let session = sessions[id], records[id] != nil else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes?[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return }
        let transferId = UUID().uuidString
        let name = FileNames.sanitize(url.lastPathComponent)
        transfers.insert(Transfer(id: transferId, peerId: id, name: name, size: size, outgoing: true), at: 0)
        Task { [weak self] in
            defer { try? handle.close() }
            let failure = await Self.upload(handle, id: transferId, name: name, size: size, session: session) { sent in
                self?.updateTransfer(transferId) { $0.transferred = sent }
                return self?.cancelledSends.contains(transferId) == true
            }
            if let failure {
                session.send(Envelope(type: MessageType.fileCancel, file: FileMessage(id: transferId)))
                self?.finishTransfer(transferId, status: .failed, detail: failure)
            }
        }
    }

    private static func upload(
        _ handle: FileHandle, id: String, name: String, size: Int64, session: PeerSession,
        progress: (Int64) -> Bool
    ) async -> String? {
        let offer = FileMessage(id: id, name: name, size: size)
        guard await session.sendAndWait(Envelope(type: MessageType.fileOffer, file: offer)) else { return "Connection lost" }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            // read(upToCount:) returns nil at end of file, which isn't an error.
            let data: Data
            do {
                data = try handle.read(upToCount: PhoneLinkProtocol.chunkBytes) ?? Data()
            } catch {
                return "Failed to read the file"
            }
            guard !data.isEmpty else { break }
            hasher.update(data: data)
            total += Int64(data.count)
            let chunk = FileMessage(id: id, data: data.base64EncodedString())
            guard await session.sendAndWait(Envelope(type: MessageType.fileChunk, file: chunk)) else { return "Connection lost" }
            if progress(total) { return "Canceled by the receiver" }
        }
        guard total == size else { return "File size changed while sending" }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let done = FileMessage(id: id, sha256: hash)
        return await session.sendAndWait(Envelope(type: MessageType.fileDone, file: done)) ? nil : "Connection lost"
    }

    private func handleFile(type: String, file: FileMessage, from id: String, session: PeerSession) {
        switch type {
        case MessageType.fileOffer:
            guard let size = file.size, size >= 0, incomingFiles[file.id] == nil else { return }
            let name = FileNames.sanitize(file.name)
            do {
                incomingFiles[file.id] = try IncomingFile(peerId: id, name: name, size: size, folder: downloadFolder)
                transfers.insert(Transfer(id: file.id, peerId: id, name: name, size: size, outgoing: false), at: 0)
            } catch {
                replyFile(file.id, ok: false, error: "Can't save the file", to: session)
            }
        case MessageType.fileChunk:
            guard let item = incomingFiles[file.id], item.peerId == id else { return }
            guard let data = Data(base64Encoded: file.data ?? ""), item.received + Int64(data.count) <= item.size,
                  (try? item.handle.write(contentsOf: data)) != nil
            else { return failIncoming(file.id, item, "Invalid file data", session: session) }
            item.hasher.update(data: data)
            item.received += Int64(data.count)
            updateTransfer(file.id) { $0.transferred = item.received }
        case MessageType.fileDone:
            guard let item = incomingFiles[file.id], item.peerId == id else { return }
            let hash = item.hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard item.received == item.size, hash == file.sha256 else {
                return failIncoming(file.id, item, "File was corrupted in transit", session: session)
            }
            incomingFiles[file.id] = nil
            do {
                try item.handle.close()
                let target = FileNames.unique(in: downloadFolder, name: item.name)
                try FileManager.default.moveItem(at: item.partURL, to: target)
                updateTransfer(file.id) { $0.location = target }
                replyFile(file.id, ok: true, error: nil, to: session)
                finishTransfer(file.id, status: .done, detail: nil)
            } catch {
                item.abort()
                replyFile(file.id, ok: false, error: "Failed to save the file", to: session)
                finishTransfer(file.id, status: .failed, detail: "Failed to save the file")
            }
        case MessageType.fileCancel:
            cancelledSends.insert(file.id)
            guard let item = incomingFiles[file.id], item.peerId == id else { return }
            incomingFiles[file.id] = nil
            item.abort()
            finishTransfer(file.id, status: .failed, detail: "Canceled by the sender")
        case MessageType.fileResult:
            if file.ok == true {
                finishTransfer(file.id, status: .done, detail: nil)
            } else {
                cancelledSends.insert(file.id)
                finishTransfer(file.id, status: .failed, detail: file.error ?? "Rejected by the receiver")
            }
        default:
            break
        }
    }

    private func failIncoming(_ id: String, _ item: IncomingFile, _ message: String, session: PeerSession) {
        incomingFiles[id] = nil
        item.abort()
        replyFile(id, ok: false, error: message, to: session)
        finishTransfer(id, status: .failed, detail: message)
    }

    private func replyFile(_ id: String, ok: Bool, error: String?, to session: PeerSession) {
        session.send(Envelope(type: MessageType.fileResult, file: FileMessage(id: id, ok: ok, error: error)))
    }

    private func cancelIncomingFiles(from peerId: String) {
        for (id, item) in incomingFiles where item.peerId == peerId {
            incomingFiles[id] = nil
            item.abort()
        }
    }

    private func updateTransfer(_ id: String, _ change: (inout Transfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private func finishTransfer(_ id: String, status: TransferStatus, detail: String?) {
        updateTransfer(id) { transfer in
            guard transfer.status == .active else { return }
            transfer.status = status
            transfer.detail = detail
        }
        if transfers.count > 20 { transfers.removeLast(transfers.count - 20) }
    }

    // MARK: - Login item

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to change the login setting: \(error.localizedDescription)")
            loginProblem = "Couldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        if launchAtLogin == enabled { loginProblem = nil }
    }

    // MARK: - State

    private func hello(of session: PeerSession) -> String { session.hello?.name ?? "?" }

    private func currentInfo() -> DeviceInfo {
        var info = LocalDevice.info(network: networkName)
        info.inputTrusted = DeviceInput.isTrusted
        return info
    }

    private func broadcastInfo() {
        let info = currentInfo()
        for (id, session) in sessions where records[id] != nil {
            session.send(Envelope(type: MessageType.info, info: info))
        }
    }

    private func removeRecord(_ id: String) {
        guard records[id] != nil else { return }
        records[id] = nil
        infos[id] = nil
        phoneData[id] = nil
        incomingContacts[id] = nil
        screenRequests.remove(id)
        if screen?.peerId == id { endScreen() }
        saveRecords()
    }

    private func rebuildPeers() {
        var result: [Peer] = []
        for id in Set(records.keys).union(sessions.keys) {
            let hello = sessions[id]?.hello
            let record = records[id]
            // A connection that has not sent hello has no identity to show yet.
            guard hello != nil || record != nil else { continue }
            result.append(Peer(
                id: id,
                name: hello?.name ?? record?.name ?? "Device",
                platform: hello?.platform ?? record?.platform ?? "android",
                model: hello?.model ?? record?.model ?? "",
                isPaired: record != nil,
                isConnected: sessions[id] != nil,
                info: infos[id],
                lastSeen: lastSeen[id]
            ))
        }
        peers = result.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if let selected = selectedPeerId, !peers.contains(where: { $0.id == selected }) {
            selectedPeerId = nil
        }
        if selectedPeerId == nil { selectedPeerId = peers.first?.id }
    }

    private func loadRecords() {
        guard let data = try? Data(contentsOf: recordsURL),
              let decoded = try? JSONDecoder().decode([String: PairedRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func saveRecords() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsURL, options: [.atomic])
    }

    #if DEBUG
    /// Sample data for UI preview images.
    func loadSnapshotState(_ peers: [Peer], prompt: PairingPrompt?, addresses: [String],
                           phone: PhoneSnapshot = PhoneSnapshot(), tab: PeerTab = .overview) {
        self.peers = peers
        self.pairingPrompt = prompt
        self.addresses = addresses
        self.selectedPeerId = peers.first?.id
        self.serverState = .listening
        self.commands = [SavedCommand(id: "1", name: "Sleep display", script: "pmset displaysleepnow")]
        if let id = peers.first?.id { self.phoneData[id] = phone }
        self.peerTab = tab
        self.smsThread = phone.threads.first?.id
        self.transfers = peers.first.map {
            [
                Transfer(id: "1", peerId: $0.id, name: "final-presentation.pdf", size: 8_000_000, transferred: 5_000_000, outgoing: true),
                Transfer(id: "2", peerId: $0.id, name: "vacation-photo.jpg", size: 3_000_000, transferred: 3_000_000, outgoing: false, status: .done),
            ]
        } ?? []
    }
    #endif
}
