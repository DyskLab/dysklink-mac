import VirtualDisplay
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

    var isMac: Bool { platform == "macos" }
}

struct PairingPrompt: Identifiable, Equatable {
    var id: String { peerId }
    let peerId: String
    let peerName: String
    /// The code this Mac shows. Empty when this Mac is the one typing.
    let code: String
    /// True when the other device asked, so this Mac shows the code and the other types it.
    let startedByPeer: Bool
    /// This Mac typed the code and waits for the answer.
    var localAccepted = false
    var error: String?
    var attempts = 0
    /// The other device has an older DyskLink that can't type codes.
    var outdated = false
    var showsCode: Bool { startedByPeer }
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
    private(set) var peers: [Peer] = [] {
        didSet { updateBadge() }
    }
    private(set) var addresses: [String] = []
    var pairingPrompt: PairingPrompt?
    var selectedPeerId: String?
    var showsTools = false
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    private(set) var loginProblem: String?

    /// Called when a pairing needs the user, even if the window is closed.
    @ObservationIgnored var onNeedsAttention: (() -> Void)?
    /// Called each time a paired phone reports its status.
    /// Recent text copies to share with a paired Mac, newest first. Nil when Clipboard History is off.
    @ObservationIgnored var clipboardHistoryProvider: (() -> [SyncedClip]?)?
    @ObservationIgnored var onClipboardHistory: ((_ clips: [SyncedClip]) -> Void)?
    @ObservationIgnored var onPeerInfo: ((_ peerId: String, _ name: String, _ info: DeviceInfo) -> Void)?
    /// The notch's Todo list, water, and Pomodoro, sent to each phone when it connects.
    @ObservationIgnored var notchState: (() -> NotchState)?
    /// A phone asked to change the notch's data.
    @ObservationIgnored var onNotchAction: ((NotchAction) -> Void)?
    /// A new phone notification arrived, for the notch to show briefly.
    @ObservationIgnored var onPhoneNotification: ((PhoneAlert) -> Void)?
    /// A phone asked to lock the Mac or change Keep Awake.
    @ObservationIgnored var onMacAction: ((String) -> Void)?
    /// Keep Awake's state for the phone: `active`, `idle`, or `unavailable`.
    @ObservationIgnored var keepAwakeState: (() -> String)?
    @ObservationIgnored var chargeState: (() -> MacCharge?)?
    /// A call on the phone changed state.
    @ObservationIgnored var onCall: ((_ state: String) -> Void)?

    let ringer = MacRinger()
    /// Phones that are ringing because this Mac asked them to.
    private(set) var ringingPhones: Set<String> = []

    var hasPairedDevices: Bool { !records.isEmpty }

    private(set) var transfers: [Transfer] = []
    /// Every finished transfer with any device, newest first, up to 200.
    private(set) var history: [FileRecord] = []
    var showsHistory = false
    /// The Mac care page: cleaner, duplicates, uninstall, and startup.
    var showsCare = false
    var historyFilter = FileHistoryView.Filter.all
    private(set) var commands: [SavedCommand] = []
    private(set) var isInputTrusted = DeviceInput.isTrusted
    var newCommandName = ""
    var newCommandScript = ""
    var clipboardEnabled = UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(clipboardEnabled, forKey: "clipboardEnabled") }
    }
    /// The phone whose leaving locks this Mac. Nil when off.
    var autoLockPhone = UserDefaults.standard.string(forKey: "autolock.phone") {
        didSet {
            UserDefaults.standard.set(autoLockPhone, forKey: "autolock.phone")
            autoLockWork?.cancel()
        }
    }
    /// Seconds the phone has to be gone before the Mac locks.
    var autoLockDelay = UserDefaults.standard.object(forKey: "autolock.delay") as? Int ?? AutoLock.defaultDelay {
        didSet { UserDefaults.standard.set(autoLockDelay, forKey: "autolock.delay") }
    }
    @ObservationIgnored private var autoLockWork: DispatchWorkItem?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Shows one-time codes from the phone's SMS and notifications under the notch.
    var codesEnabled = UserDefaults.standard.object(forKey: "codes.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(codesEnabled, forKey: "codes.enabled") }
    }
    /// A one-time code arrived on a phone.
    @ObservationIgnored var onCode: ((CodeNotice) -> Void)?
    /// The same code often comes as an SMS and as a notification, so it's shown once.
    @ObservationIgnored private var recentCodes: [String: Date] = [:]
    /// Lets paired phones open a shell on this Mac. Off by default, and turning it off ends open sessions.
    /// Lets paired phones view and control this Mac's screen. Off by default; turning it off ends viewing.
    var screenShareEnabled = UserDefaults.standard.bool(forKey: "macscreen.enabled") || TestEnv.value("PHONELINK_TEST_MACSCREEN") == "1" {
        didSet {
            UserDefaults.standard.set(screenShareEnabled, forKey: "macscreen.enabled")
            if !screenShareEnabled { for id in Array(macScreens.keys) { endMacScreen(id, error: "Screen viewing was turned off on the Mac") } }
        }
    }
    /// Phones viewing this screen now.
    private(set) var macScreens: [String: MacScreenViewer] = [:] {
        didSet {
            guard Set(macScreens.keys) != Set(oldValue.keys) else { return }
            let names = macScreens.keys.sorted().map { records[$0]?.name ?? "A phone" }
            TestEnv.log("MACSCREEN_WATCHERS \(names.count)")
            onMacScreenWatchers?(names)
        }
    }
    // MARK: Audio sharing

    /// Paired phones may listen to this Mac's sound. Off by default, like viewing the screen.
    var audioShareEnabled = UserDefaults.standard.bool(forKey: "audio.enabled") || TestEnv.value("PHONELINK_TEST_AUDIO") == "1" {
        didSet {
            UserDefaults.standard.set(audioShareEnabled, forKey: "audio.enabled")
            if !audioShareEnabled { for id in audioListeners { stopListening(id, error: "Listening was turned off on the Mac") } }
        }
    }
    /// Phones hearing this Mac now.
    private(set) var audioListeners: Set<String> = [] {
        didSet {
            guard audioListeners != oldValue else { return }
            onAudioListeners?(audioListeners.sorted().map { records[$0]?.name ?? "A phone" })
        }
    }
    @ObservationIgnored var onAudioListeners: (([String]) -> Void)?
    /// The phone whose sound this Mac is playing.
    private(set) var phoneAudioFrom: String?
    /// Muted on this Mac only; the phone keeps sending, so unmuting needs no new Android prompt.
    var phoneAudioMuted = false {
        didSet { phoneAudio.muted = phoneAudioMuted }
    }
    @ObservationIgnored private var audioCapture: MacAudioCapture?
    @ObservationIgnored private var audioInFlight: [String: Int] = [:]
    @ObservationIgnored private var audioChunksSent = 0
    @ObservationIgnored private lazy var phoneAudio = PhoneAudioPlayer()
    static let audioMaxInFlight = 6

    private func handleAudio(_ envelope: Envelope, from id: String, session: PeerSession) {
        switch envelope.type {
        case MessageType.audioListen:
            guard audioShareEnabled else {
                var reply = Envelope(type: MessageType.audioStopped)
                reply.error = "Turn on \"Let phones hear this Mac\" in DyskLink on the Mac first."
                return session.send(reply)
            }
            audioListeners.insert(id)
            var started = Envelope(type: MessageType.audioStarted)
            started.audioRate = AudioPCM.rate
            started.audioChannels = AudioPCM.channels
            session.send(started)
            TestEnv.log("MAC_AUDIO_LISTEN")
            startAudioCapture()
        case MessageType.audioStop:
            stopListening(id, error: nil)
        case MessageType.audioStarted:
            if let other = phoneAudioFrom, other != id { sessions[other]?.send(Envelope(type: MessageType.audioStop)) }
            phoneAudioFrom = id
            // Sound that comes with the phone's screen is kept closer to the picture.
            phoneAudio.start(rate: envelope.audioRate ?? AudioPCM.rate, channels: envelope.audioChannels ?? AudioPCM.channels,
                             tight: screen?.peerId == id)
            phoneAudioMuted = false
            TestEnv.log("PHONE_AUDIO_STARTED tight=\(screen?.peerId == id)")
        case MessageType.audioFrame:
            guard phoneAudioFrom == id, let data = envelope.audio.flatMap({ Data(base64Encoded: $0) }), !data.isEmpty else { return }
            phoneAudio.feed(data)
            if phoneAudio.played == 1 { TestEnv.log("PHONE_AUDIO_PLAYING \(data.count)") }
        case MessageType.audioStopped:
            if phoneAudioFrom == id { phoneAudio.stop(); phoneAudioFrom = nil }
        default:
            break
        }
    }

    private func startAudioCapture() {
        guard audioCapture == nil else { return }
        let capture = MacAudioCapture()
        capture.onChunk = { [weak self] chunk in
            let text = chunk.base64EncodedString()
            Task { @MainActor in self?.sendAudio(text) }
        }
        capture.onStop = { [weak self] error in
            Task { @MainActor in self?.audioListeners.forEach { self?.stopListening($0, error: error ?? "Recording stopped") } }
        }
        audioCapture = capture
        Task {
            do {
                try await capture.start()
            } catch {
                for id in audioListeners { stopListening(id, error: "Can't record the Mac's sound. Allow Screen Recording for DyskLink.") }
            }
        }
    }

    /// Each phone gets the chunk unless too many are still on their way, which happens on a slow network.
    private func sendAudio(_ text: String) {
        var envelope = Envelope(type: MessageType.audioFrame)
        envelope.audio = text
        for id in audioListeners {
            guard let session = sessions[id], audioInFlight[id, default: 0] < Self.audioMaxInFlight else { continue }
            audioInFlight[id, default: 0] += 1
            session.send(envelope) { [weak self] _ in
                Task { @MainActor in self?.audioInFlight[id, default: 1] -= 1 }
            }
        }
        audioChunksSent += 1
        if audioChunksSent == 1 { TestEnv.log("MAC_AUDIO_SENT") }
    }

    /// Stops sending this Mac's sound to a phone, and recording when nobody listens.
    func stopListening(_ id: String, error: String?) {
        guard audioListeners.remove(id) != nil else { return }
        audioInFlight[id] = nil
        var reply = Envelope(type: MessageType.audioStopped)
        reply.error = error
        sessions[id]?.send(reply)
        TestEnv.log("MAC_AUDIO_STOPPED")
        if audioListeners.isEmpty {
            audioCapture?.stop()
            audioCapture = nil
            audioChunksSent = 0
        }
    }

    /// Asks the phone to stop sending its sound.
    func stopPhoneAudio() {
        guard let id = phoneAudioFrom else { return }
        sessions[id]?.send(Envelope(type: MessageType.audioStop))
        phoneAudio.stop()
        phoneAudioFrom = nil
    }

    /// The phones watching or using this Mac's screen, for the notch.
    @ObservationIgnored var onMacScreenWatchers: (([String]) -> Void)?
    var terminalEnabled = UserDefaults.standard.bool(forKey: "terminal.enabled") || TestEnv.value("PHONELINK_TEST_TERMINAL") == "1" {
        didSet {
            UserDefaults.standard.set(terminalEnabled, forKey: "terminal.enabled")
            if !terminalEnabled { endTerminals() }
        }
    }
    /// Open shells, by session id, with the phone each belongs to.
    private(set) var terminals: [String: (peerId: String, shell: PtyShell)] = [:]
    private static let maxTerminalsPerPhone = 4

    /// Finds other Macs with DyskLink on this network and connects to the paired ones. Off by default.
    var macSyncEnabled = UserDefaults.standard.bool(forKey: "macs.sync") || TestEnv.value("PHONELINK_TEST_MAC_SYNC") == "1" {
        didSet { UserDefaults.standard.set(macSyncEnabled, forKey: "macs.sync"); applyMacSync() }
    }
    /// When a Mac connects, both send their recent text copies so the histories match.
    var sharesClipboardHistory = UserDefaults.standard.object(forKey: "macs.history") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sharesClipboardHistory, forKey: "macs.history") }
    }
    /// Other Macs seen on the network, by device ID.
    private(set) var nearbyMacs: Set<String> = []

    /// Phone data is kept in memory only, and cleared when the phone turns the feature off or unpairs.
    private(set) var phoneData: [String: PhoneSnapshot] = [:] {
        didSet { updateBadge() }
    }
    var peerTab: PeerTab = .overview
    var contactQuery = ""
    var smsQuery = ""
    var smsThread: Int64?
    var smsAddress = ""
    var smsDraft = ""

    private(set) var screen: ScreenSession?
    private(set) var camera: CameraSession?
    /// Phones over a USB cable, through adb.
    let usb = UsbBridge()
    private(set) var cameraRequests: Set<String> = []
    private(set) var cameraError: [String: String] = [:]
    @ObservationIgnored private let cameraDecoder = VideoDecoder()
    @ObservationIgnored private var lastCameraSync = Date.distantPast
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
    @ObservationIgnored private var networkName: String?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var infoTimer: Timer?
    @ObservationIgnored private var pairingTimeout: Task<Void, Never>?
    @ObservationIgnored private let clipboard = ClipboardWatcher()
    @ObservationIgnored private var incomingFiles: [String: IncomingFile] = [:]
    @ObservationIgnored private var cancelledSends: Set<String> = []
    @ObservationIgnored private var incomingContacts: [String: [ContactItem]] = [:]
    @ObservationIgnored private var screenTimeAsked: [String: Date] = [:]
    @ObservationIgnored private let notifier = MacNotifier()
    @ObservationIgnored private var didProbePhone = false
    @ObservationIgnored private var didProbeGallery = false
    @ObservationIgnored private let decoder = VideoDecoder()
    @ObservationIgnored private var lastSyncRequest = Date.distantPast
    @ObservationIgnored private var didShowTrustCard = false
    @ObservationIgnored private var trustTimer: Timer?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var macEndpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var dialing: [String: PeerSession] = [:]
    @ObservationIgnored private var macTimer: Timer?
    /// What a paired Mac may send. Input, commands, and phone data stay phone-only.
    private static let macMessageTypes: Set<String> = [
        MessageType.hello, MessageType.pairRequest, MessageType.pairAccept, MessageType.pairReject, MessageType.unpair,
        MessageType.info, MessageType.ping, MessageType.pong, MessageType.clipboard, MessageType.clipboardHistory,
        MessageType.ring, MessageType.fileOffer, MessageType.fileChunk, MessageType.fileDone, MessageType.fileCancel,
        MessageType.fileResult,
    ]

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
    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    /// Synced photos go to Pictures/DyskLink/<phone>, one folder per phone.
    private func photoFolder(for id: String) -> URL {
        let base = TestEnv.value("PHONELINK_PHOTO_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("DyskLink", isDirectory: true)
        let phone = FileNames.sanitize(records[id]?.name ?? peers.first { $0.id == id }?.name ?? "Phone")
        return base.appendingPathComponent(phone, isDirectory: true)
    }

    private var downloadFolder: URL {
        if let path = TestEnv.value("PHONELINK_DOWNLOAD_DIR") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DyskLink", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        guard listener == nil else { return }
        // After sleep the phone needs a moment to reconnect, so the wait starts again.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.autoLockPhone, self.autoLockWork != nil, self.sessions[id] == nil else { return }
                self.scheduleAutoLock()
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            loadRecords()
            loadCommands()
            loadHistory()
            let identity = try LocalIdentity.loadOrCreate(in: directory)
            self.identity = identity
            try startListener(identity: identity)
            startNetworkMonitor()
            startInfoTimer()
            clipboard.onChange = { [weak self] text in self?.shareClipboard(text) }
            ringer.onStopped = { [weak self] in self?.broadcastRingStopped() }
            clipboard.start()
            rebuildPeers()
            applyMacSync()
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
            // The ID lets other Macs skip this one and decide which side connects.
            let txt = NWTXTRecord(["id": identity.deviceId, "platform": "macos"])
            listener.service = NWListener.Service(name: LocalDevice.name, type: PhoneLinkProtocol.serviceType, domain: nil, txtRecord: txt)
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
        // Test instances don't touch real phones on USB.
        if testPort == nil || TestEnv.value("PHONELINK_TEST_USB") == "1" { usb.start(port: testPort ?? PhoneLinkProtocol.port) }
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
        attach(PeerSession(connection: connection))
    }

    private func attach(_ session: PeerSession) {
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
        for (key, value) in dialing where value === session { dialing[key] = nil }
        guard let id = session.deviceId, sessions[id] === session else { return }
        sessions[id] = nil
        lastSeen[id] = Date()
        if id == autoLockPhone, records[id] != nil { scheduleAutoLock() }
        ringingPhones.remove(id)
        if audioListeners.contains(id) { stopListening(id, error: nil) }
        if phoneAudioFrom == id { phoneAudio.stop(); phoneAudioFrom = nil }
        cancelIncomingFiles(from: id)
        // The phone resends active notifications when it reconnects.
        phoneData[id]?.notifications = []
        phoneData[id]?.filesLoading = false
        screenRequests.remove(id)
        if screen?.peerId == id { endScreen() }
        endTerminals(of: id)
        if camera?.peerId == id { endCamera() }
        cameraRequests.remove(id)
        if macScreens[id] != nil { endMacScreen(id, error: nil) }
        for index in transfers.indices where transfers[index].peerId == id && transfers[index].status == .active {
            transfers[index].status = .failed
            transfers[index].detail = "Connection lost"
        }
        if pairingPrompt?.peerId == id { clearPairing() }
        rebuildPeers()
    }

    // MARK: - This screen on a phone

    private func handleMacScreen(_ envelope: Envelope, from id: String, session: PeerSession) {
        switch envelope.type {
        case MessageType.macScreenStart:
            let mode = envelope.text ?? ""
            startMacScreen(for: id, session: session, extend: mode.hasPrefix("extend") ? envelope.screen : nil,
                           large: mode == "extend-large", display: envelope.displayId)
        case MessageType.macScreenSync:
            macScreens[id]?.encoder.requestKeyFrame()
        case MessageType.macScreenStop:
            endMacScreen(id, error: nil)
        case MessageType.macScreenPointer:
            guard let viewer = macScreens[id], let control = envelope.control,
                  let x = control.x, let y = control.y, x.isFinite, y.isFinite else { return }
            guard isInputTrusted || TestEnv.isDryRun else { return showTrustCardIfNeeded() }
            let frame = viewer.displayFrame
            let point = CGPoint(x: frame.minX + CGFloat(min(max(x, 0), 1)) * frame.width,
                                y: frame.minY + CGFloat(min(max(y, 0), 1)) * frame.height)
            DeviceInput.pointer(control.kind, at: point)
        default:
            break
        }
    }

    private func startMacScreen(for id: String, session: PeerSession, extend: ScreenInfo? = nil, large: Bool = false,
                                display: UInt32? = nil) {
        // Only one of this Mac's own displays can be picked.
        let display = display.flatMap { wanted in MacScreenViewer.displays().contains { $0.id == wanted } ? wanted : nil }
        func refuse(_ reason: String) {
            var reply = Envelope(type: MessageType.macScreenStopped)
            reply.error = reason
            session.send(reply)
        }
        guard screenShareEnabled else {
            return refuse("Turn on \"View this screen from the phone\" in DyskLink on the Mac first.")
        }
        let wanted = extend.flatMap { SecondDisplay.size(requested: $0, large: large) }
        if let viewer = macScreens[id], (viewer.extraDisplay != nil) != (extend != nil)
            || (wanted != nil && (viewer.extraSize?.width != wanted?.width || viewer.extraSize?.height != wanted?.height
                || viewer.extraLarge != large))
            || (extend == nil && display != nil && macScreens[id]?.displayID != display) {
            // Switching between viewing and extending, or turning the phone, starts over.
            endMacScreen(id, error: nil)
        }
        if let viewer = macScreens[id] {
            // Asked again, for example after the app came back: send the size and a fresh picture.
            var started = Envelope(type: MessageType.macScreenStarted)
            started.screen = ScreenInfo(width: viewer.width, height: viewer.height)
            started.text = viewer.displayName
            if viewer.extraDisplay == nil {
                started.displays = MacScreenViewer.displays()
                started.displayId = viewer.displayID ?? CGMainDisplayID()
            }
            session.send(started)
            viewer.encoder.requestKeyFrame()
            return
        }
        guard TestEnv.isDryRun || CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return refuse("Allow Screen Recording for DyskLink in System Settings › Privacy & Security on the Mac, then try again.")
        }
        var extra: DLVirtualDisplay?
        if extend != nil {
            guard let size = wanted else { return refuse("The phone asked for a display size this Mac can't make.") }
            let name = "\(records[id]?.name ?? "Phone") (DyskLink)"
            // Each orientation is its own display, so macOS remembers where each one sits.
            let serial = (UInt32(id.prefix(8), radix: 16) ?? 1) & ~3 | (size.height > size.width ? 1 : 0) | (large ? 2 : 0)
            if TestEnv.isDryRun {
                TestEnv.log("SECOND_DISPLAY \(size.width)x\(size.height)\(large ? " large" : "")")
                return refuse("Extra displays aren't made in tests.")
            }
            guard let made = SecondDisplay.make(name: name, width: size.width, height: size.height, serial: serial, sharp: !large) else {
                return refuse("macOS didn't make the extra display.")
            }
            extra = made
        }
        var config = MacScreenEncoder.Config()
        if extra != nil { config.maxSide = 1920 }
        let encoder = MacScreenEncoder(config: config)
        let viewer = MacScreenViewer(encoder: encoder)
        viewer.extraDisplay = extra
        viewer.extraSize = wanted
        viewer.extraLarge = large
        viewer.displayID = extra == nil ? display : nil
        viewer.bitrate = config.bitrate
        viewer.maxBitrate = config.bitrate
        macScreens[id] = viewer
        encoder.onFrame = { [weak self] data, key in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sendMacScreenFrame(data, key: key, to: id) } }
        }
        encoder.onStopped = { [weak self] error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.endMacScreen(id, error: error ?? "Recording stopped") } }
        }
        Task { @MainActor in
            do {
                let started = try await encoder.start(displayID: viewer.extraDisplay?.displayID ?? viewer.displayID)
                guard macScreens[id] === viewer else { return encoder.stop() }
                viewer.width = started.width
                viewer.height = started.height
                viewer.displayFrame = started.displayFrame
                viewer.displayName = started.displayName
                var reply = Envelope(type: MessageType.macScreenStarted)
                reply.screen = ScreenInfo(width: started.width, height: started.height)
                reply.text = started.displayName
                if viewer.extraDisplay == nil {
                    reply.displays = MacScreenViewer.displays()
                    reply.displayId = viewer.displayID ?? CGMainDisplayID()
                    TestEnv.log("MACSCREEN_DISPLAYS \(reply.displays?.count ?? 0)")
                }
                sessions[id]?.send(reply)
                let name = records[id]?.name ?? "A phone"
                TestEnv.log("MACSCREEN_STARTED \(started.width)x\(started.height)")
                if viewer.extraDisplay != nil {
                    notifier.show(id: "macscreen:\(id)", title: "\(name) is now an extra display", subtitle: "DyskLink",
                                  body: "Drag windows onto it. Arrange it in System Settings › Displays.")
                } else {
                    notifier.show(id: "macscreen:\(id)", title: "\(name) is viewing this screen", subtitle: "DyskLink",
                                  body: "Turn off View this screen from the phone to stop it.")
                }
            } catch {
                macScreens[id] = nil
                encoder.stop()
                viewer.extraDisplay = nil
                refuse("The screen couldn't be recorded: \(error.localizedDescription)")
            }
        }
    }

    /// Sends a frame unless the network has fallen behind, then waits for a key frame so the picture stays whole.
    private func sendMacScreenFrame(_ data: Data, key: Bool, to id: String) {
        guard let viewer = macScreens[id], let session = sessions[id] else { return }
        if data.count > PhoneLinkProtocol.maxScreenFrameBytes {
            viewer.waitsForKey = true
            viewer.encoder.requestKeyFrame()
            return
        }
        if viewer.windowSent + viewer.windowDropped >= MacScreenViewer.adaptEvery {
            let next = MacScreenViewer.nextBitrate(current: viewer.bitrate, sent: viewer.windowSent,
                                                   dropped: viewer.windowDropped, max: viewer.maxBitrate)
            if next != viewer.bitrate {
                viewer.bitrate = next
                viewer.encoder.setBitrate(next)
            }
            viewer.windowSent = 0
            viewer.windowDropped = 0
        }
        if !key, viewer.waitsForKey || viewer.inFlight >= MacScreenViewer.maxInFlight {
            if !viewer.waitsForKey { viewer.encoder.requestKeyFrame() }
            viewer.waitsForKey = true
            viewer.dropped += 1
            viewer.windowDropped += 1
            return
        }
        viewer.windowSent += 1
        viewer.waitsForKey = false
        viewer.inFlight += 1
        viewer.sent += 1
        if viewer.sent == 1 { TestEnv.log("MACSCREEN_FRAME key=\(key) bytes=\(data.count)") }
        var envelope = Envelope(type: MessageType.macScreenFrame)
        envelope.video = data.base64EncodedString()
        envelope.keyFrame = key
        session.send(envelope) { [weak viewer] _ in viewer?.inFlight -= 1 }
    }

    func endMacScreen(_ id: String, error: String?) {
        guard let viewer = macScreens.removeValue(forKey: id) else { return }
        viewer.encoder.stop()
        // Windows on the extra display move back to the others when it goes away.
        viewer.extraDisplay = nil
        notifier.remove(id: "macscreen:\(id)")
        TestEnv.log("MACSCREEN_STOPPED sent=\(viewer.sent) dropped=\(viewer.dropped)")
        var reply = Envelope(type: MessageType.macScreenStopped)
        reply.error = error
        sessions[id]?.send(reply)
    }

    /// Waits for the chosen phone to come back, and locks the Mac when it doesn't.
    private func scheduleAutoLock() {
        autoLockWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let id = self.autoLockPhone else { return }
                let lock = AutoLock.shouldLock(phoneConnected: self.sessions[id] != nil,
                                               screenLocked: AutoLock.isScreenLocked, macOnline: !self.addresses.isEmpty)
                guard lock else { return }
                let name = self.records[id]?.name ?? "The phone"
                TestEnv.log("AUTOLOCK \(name)")
                MacActions.lockScreen()
                self.notifier.show(id: "autolock", title: "Mac locked", subtitle: "DyskLink",
                                   body: "\(name) went away, so this Mac was locked.")
            }
        }
        autoLockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(autoLockDelay), execute: work)
    }

    private func handle(_ envelope: Envelope, from session: PeerSession) {
        guard let id = session.deviceId else { return }
        // Every message except hello only applies to registered connections.
        guard envelope.type == MessageType.hello || sessions[id] === session else { return }
        if isMac(id, session), !Self.macMessageTypes.contains(envelope.type) { return }
        switch envelope.type {
        case MessageType.hello:
            guard let hello = envelope.hello else { return }
            if hello.platform == "macos", !macSyncEnabled { return session.close() }
            // The newest connection replaces the old one, which may be dead.
            if let old = sessions[id], old !== session { old.close() }
            sessions[id] = session
            session.hello = hello
            if session.isLoopback { TestEnv.log("USB_SESSION \(hello.name)") }
            if id == autoLockPhone { autoLockWork?.cancel() }
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
            #if DEBUG
            if TestEnv.value("PHONELINK_TEST_PAIR_MAC") == "1", hello.platform == "macos", records[id] == nil {
                requestPairing(with: id)
            }
            #endif
        case MessageType.pairRequest:
            guard records[id] == nil, session.hello != nil else { return }
            beginPairing(with: id, startedByPeer: true)
        case MessageType.pairAccept:
            guard var prompt = pairingPrompt, prompt.peerId == id, let identity else { return }
            if prompt.showsCode {
                if envelope.key == Pairing.proof(prompt.code, identity.deviceId, id) {
                    session.send(Envelope(type: MessageType.pairAccept))
                    completePairing(id)
                } else {
                    prompt.attempts += 1
                    if prompt.attempts >= Pairing.maxAttempts { return rejectPairing() }
                    prompt.error = "A wrong code was typed on \(prompt.peerName)."
                    pairingPrompt = prompt
                    var wrong = Envelope(type: MessageType.pairReject)
                    wrong.error = Pairing.wrongCode
                    session.send(wrong)
                }
            } else if prompt.localAccepted {
                completePairing(id)
            }
        case MessageType.pairReject:
            guard var prompt = pairingPrompt, prompt.peerId == id else { return }
            if envelope.error == Pairing.wrongCode, !prompt.showsCode {
                prompt.localAccepted = false
                pairingEntry = ""
                prompt.error = "That code isn't right. Check the code on \(prompt.peerName) and try again."
                pairingPrompt = prompt
            } else {
                clearPairing()
            }
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
            if !isMac(id, session) { onPeerInfo?(id, peers.first { $0.id == id }?.name ?? "Phone", info) }
        case MessageType.ping:
            session.send(Envelope(type: MessageType.pong))
        case MessageType.notchAction:
            guard records[id] != nil, let action = envelope.notchAction else { return }
            TestEnv.log("NOTCH_ACTION \(action.kind) \(action.text ?? "")")
            onNotchAction?(action)
        case MessageType.macAction:
            guard records[id] != nil, let action = envelope.macAction else { return }
            TestEnv.log("MAC_ACTION \(action)")
            onMacAction?(action)
            broadcastInfo()
        case MessageType.ring:
            guard records[id] != nil else { return }
            if envelope.ring == "start" { ringer.start(from: hello(of: session)) }
            else if envelope.ring == "stop" { ringer.stop() }
            else if envelope.ring == "stopped" { ringingPhones.remove(id) }
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
        case MessageType.clipboardHistory:
            guard records[id] != nil, clipboardEnabled, sharesClipboardHistory, let clips = envelope.clips else { return }
            TestEnv.log("CLIPBOARD_HISTORY \(clips.count)")
            onClipboardHistory?(Array(clips.prefix(PhoneLinkProtocol.maxSyncedClips)))
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
        case MessageType.audioListen, MessageType.audioStarted, MessageType.audioFrame, MessageType.audioStop, MessageType.audioStopped:
            guard records[id] != nil, !isMac(id, session) else { return }
            handleAudio(envelope, from: id, session: session)
        case MessageType.macScreenStart, MessageType.macScreenSync, MessageType.macScreenStop, MessageType.macScreenPointer:
            guard records[id] != nil else { return }
            handleMacScreen(envelope, from: id, session: session)
        case MessageType.terminalOpen, MessageType.terminalInput, MessageType.terminalResize, MessageType.terminalClose:
            guard records[id] != nil, let message = envelope.terminal else { return }
            handleTerminal(envelope.type, message, from: id, session: session)
        case MessageType.fileOffer, MessageType.fileChunk, MessageType.fileDone,
             MessageType.fileCancel, MessageType.fileResult:
            guard records[id] != nil, let file = envelope.file else { return }
            handleFile(type: envelope.type, file: file, from: id, session: session)
        case MessageType.screenStarted, MessageType.screenFrame, MessageType.screenStopped:
            guard records[id] != nil else { return }
            handleScreen(envelope, from: id, session: session)
        case MessageType.cameraStarted, MessageType.cameraFrame, MessageType.cameraStopped:
            guard records[id] != nil, !isMac(id, session) else { return }
            handleCamera(envelope, from: id, session: session)
        case MessageType.features, MessageType.notificationPosted, MessageType.notificationRemoved,
             MessageType.smsMessages, MessageType.smsNew, MessageType.smsResult, MessageType.call,
             MessageType.contacts, MessageType.fsListing, MessageType.usage, MessageType.gallery:
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

    /// Sends the code typed on this Mac. The other device checks it.
    func submitPairingCode(_ typed: String) {
        let digits = typed.filter(\.isNumber)
        guard var prompt = pairingPrompt, !prompt.showsCode, !prompt.outdated, digits.count == 6,
              let session = sessions[prompt.peerId], let identity else { return }
        prompt.localAccepted = true
        prompt.error = nil
        pairingPrompt = prompt
        session.send(Envelope(type: MessageType.pairAccept, key: Pairing.proof(digits, identity.deviceId, prompt.peerId)))
    }

    /// What's typed in the code box on this Mac.
    var pairingEntry = ""

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
        if let current = pairingPrompt, current.peerId == id {
            // Both asked at once: the smaller ID shows the code, the other types it.
            guard startedByPeer, !current.showsCode, identity.deviceId < id else { return }
        }
        let testCode = ProcessInfo.processInfo.environment["PHONELINK_TEST_AUTO_ACCEPT"] == "1"
        pairingEntry = ""
        pairingPrompt = PairingPrompt(
            peerId: id, peerName: hello.name,
            code: startedByPeer ? (testCode ? "123456" : Pairing.newCode()) : "", startedByPeer: startedByPeer,
            error: hello.protocolVersion < Pairing.typedSince
                ? "\(hello.name) has an older DyskLink. Update it there, then pair again." : nil,
            outdated: hello.protocolVersion < Pairing.typedSince
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
            print("PAIRING_CODE 123456")
            if !startedByPeer { submitPairingCode("123456") }
        }
        #endif
    }

    private func completePairing(_ id: String) {
        guard let session = sessions[id], let hello = session.hello else { return }
        records[id] = PairedRecord(name: hello.name, platform: hello.platform, model: hello.model, pairedAt: Date())
        saveRecords()
        clearPairing()
        selectedPeerId = id
        #if DEBUG
        print("PAIRING_DONE \(hello.name)")
        // The integration test checks that the Mac locks once the test phone leaves.
        if let seconds = TestEnv.value("PHONELINK_TEST_AUTOLOCK").flatMap(Int.init), hello.platform != "macos" {
            autoLockPhone = id
            autoLockDelay = seconds
        }
        #endif
        sendInitialState(to: session)
        rebuildPeers()
    }

    private func clearPairing() {
        pairingTimeout?.cancel()
        pairingTimeout = nil
        pairingPrompt = nil
        pairingEntry = ""
    }

    // MARK: - Features

    private func sendInitialState(to session: PeerSession) {
        session.send(Envelope(type: MessageType.info, info: currentInfo()))
        if let id = session.deviceId, isMac(id, session) {
            if clipboardEnabled, sharesClipboardHistory, let clips = clipboardHistoryProvider?(), !clips.isEmpty {
                var envelope = Envelope(type: MessageType.clipboardHistory)
                envelope.clips = MacSync.fitting(clips)
                session.send(envelope)
            }
            #if DEBUG
            if let text = TestEnv.value("PHONELINK_TEST_SHARE_CLIPBOARD") { shareClipboard(text) }
            #endif
            return
        }
        sendCommandList(to: session)
        if let state = notchState?() {
            var envelope = Envelope(type: MessageType.notchState)
            envelope.notch = state
            session.send(envelope)
        }
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

    /// Sends the notch's data to every paired phone after it changed on the Mac or from a phone.
    func broadcastNotch(_ state: NotchState) {
        var envelope = Envelope(type: MessageType.notchState)
        envelope.notch = state
        for (id, session) in sessions where records[id] != nil { session.send(envelope) }
    }

    /// Makes the phone ring loudly, even when it is on silent, until it is stopped or 30 seconds pass.
    func ringPhone(_ id: String, _ on: Bool) {
        guard records[id] != nil, let session = sessions[id] else { return }
        var envelope = Envelope(type: MessageType.ring)
        envelope.ring = on ? "start" : "stop"
        session.send(envelope)
        if on {
            ringingPhones.insert(id)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(MacRinger.duration))
                self?.ringingPhones.remove(id)
            }
        } else {
            ringingPhones.remove(id)
        }
    }

    private func broadcastRingStopped() {
        var envelope = Envelope(type: MessageType.ring)
        envelope.ring = "stopped"
        for (id, session) in sessions where records[id] != nil { session.send(envelope) }
    }

    /// The version of DyskLink on a connected phone. Nil for apps older than 0.2.0, which don't say.
    func phoneAppVersion(_ id: String) -> String? { sessions[id]?.hello?.appVersion }

    func sendMedia(_ action: String, to id: String) {
        guard records[id] != nil else { return }
        sessions[id]?.send(Envelope(type: MessageType.media, media: action))
    }

    /// Commands from tools, such as restoring a saved window layout, listed after the user's own.
    @ObservationIgnored var toolCommands: (() -> [CommandItem])?
    /// Runs a tool command. Returns nil when the ID isn't one.
    @ObservationIgnored var runToolCommand: ((String) -> String?)?

    /// Sends the command list again, after tool commands change.
    func toolCommandsChanged() {
        for (id, session) in sessions where records[id] != nil { sendCommandList(to: session) }
    }

    private func sendCommandList(to session: PeerSession) {
        // Script contents are deliberately not sent to the phone.
        let items = commands.map { CommandItem(id: $0.id, name: $0.name) } + (toolCommands?() ?? [])
        session.send(Envelope(type: MessageType.commandsList, commands: items))
    }

    private func runCommand(_ commandId: String, for session: PeerSession) {
        if let output = runToolCommand?(commandId) {
            TestEnv.log("TOOL_COMMAND \(commandId)")
            return session.send(Envelope(type: MessageType.commandResult, commandResult: CommandResult(id: commandId, exitCode: 0, output: output)))
        }
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
        MessageType.usage: "screentime", MessageType.gallery: "gallery",
    ]

    // MARK: Gallery

    /// What to do with each gallery file on its way, by file name.
    private var galleryWanted: [String: GalleryAction] = [:]
    enum GalleryAction { case open, save }

    private static func galleryRequest(offset: Int) -> Envelope {
        var envelope = Envelope(type: MessageType.galleryList)
        envelope.offset = offset
        return envelope
    }

    private static func galleryGet(_ id: Int64) -> Envelope {
        var envelope = Envelope(type: MessageType.galleryGet)
        envelope.galleryId = id
        return envelope
    }

    /// Loads the next page of the phone's gallery, or starts over.
    func loadGallery(_ id: String, reset: Bool = false) {
        guard records[id] != nil, let session = sessions[id] else { return }
        var data = phone(id)
        guard data.features.contains("gallery") else { return }
        if reset { data.gallery = []; data.galleryEnd = false; data.galleryError = nil; data.galleryLoading = false }
        guard !data.galleryLoading, !data.galleryEnd else { return }
        data.galleryLoading = true
        phoneData[id] = data
        session.send(Self.galleryRequest(offset: data.gallery.count))
    }

    /// Copies of opened photos are kept here, so opening one again doesn't download it again.
    func galleryFolder(for id: String) -> URL {
        let phone = FileNames.sanitize(records[id]?.name ?? peers.first { $0.id == id }?.name ?? "Phone")
        let base = TestEnv.value("PHONELINK_DATA_DIR").map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Gallery") }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DyskLink/Gallery", isDirectory: true)
        return base.appendingPathComponent(phone, isDirectory: true)
    }

    /// Opens a photo or video, or saves it to Downloads/DyskLink.
    func galleryItem(_ item: GalleryItem, on id: String, action: GalleryAction) {
        let name = FileNames.sanitize(item.name)
        let cached = galleryFolder(for: id).appendingPathComponent(name)
        if let size = (try? FileManager.default.attributesOfItem(atPath: cached.path))?[.size] as? NSNumber, size.int64Value == item.size || item.size <= 0 {
            return finishGallery(cached, action: action)
        }
        guard records[id] != nil, let session = sessions[id] else { return }
        galleryWanted[name] = action
        session.send(Self.galleryGet(item.id))
    }

    private func finishGallery(_ url: URL, action: GalleryAction) {
        TestEnv.log("GALLERY_FILE \(url.lastPathComponent) \(action == .open ? "open" : "save")")
        switch action {
        case .open:
            if !TestEnv.isDryRun { NSWorkspace.shared.open(url) }
        case .save:
            try? FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
            let target = FileNames.unique(in: downloadFolder, name: url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil, !TestEnv.isDryRun {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        }
    }

    /// Asks the phone for today's screen time, at most once a minute.
    func requestScreenTime(_ id: String, force: Bool = false) {
        guard records[id] != nil, let session = sessions[id], phone(id).features.contains("screentime") else { return }
        if !force, let last = screenTimeAsked[id], Date().timeIntervalSince(last) < 60 { return }
        screenTimeAsked[id] = Date()
        session.send(Envelope(type: MessageType.usageList))
    }

    /// Shows the code under the notch when the text has one. True when it did.
    private func foundCode(_ text: String, source: String, from id: String) -> Bool {
        guard codesEnabled, let code = OneTimeCode.find(in: text) else { return false }
        let now = Date()
        recentCodes = recentCodes.filter { now.timeIntervalSince($0.value) < 120 }
        TestEnv.log("PHONE_CODE \(code)")
        if recentCodes[code] == nil {
            recentCodes[code] = now
            onCode?(CodeNotice(code: code, source: source, phone: peers.first { $0.id == id }?.name ?? "Phone"))
        }
        return true
    }

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
            if features.contains("screentime"), !previous.contains("screentime") || !wasKnown {
                screenTimeAsked[id] = Date()
                session.send(Envelope(type: MessageType.usageList))
            }
            if features.contains("gallery"), !wasKnown || !previous.contains("gallery") {
                data.gallery = []
                data.galleryEnd = false
                data.galleryLoading = true
                session.send(Self.galleryRequest(offset: 0))
            }
            if features.contains("files"), !wasKnown || !previous.contains("files") {
                data.beginListing("")
                session.send(Envelope(type: MessageType.fsList, path: ""))
            }
            if TestEnv.value("PHONELINK_TEST_PROBE_PHONE") == "1", features.count >= 7, !didProbePhone {
                didProbePhone = true
                data.pendingSms = "uji-sms"
                probePhone(session)
            }
        case MessageType.notificationPosted:
            guard let item = envelope.notification else { return }
            data.upsert(item)
            TestEnv.log("PHONE_NOTIFICATION \(item.app) \(item.title ?? "") silent=\(item.silent == true)")
            if item.silent != true, !foundCode([item.title, item.text].compactMap { $0 }.joined(separator: " "), source: item.title ?? item.app, from: id) {
                onPhoneNotification?(PhoneAlert(peerId: id, phone: peers.first { $0.id == id }?.name ?? "Phone", item: item))
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
            if isNew {
                for item in items where !item.outgoing && !known.contains(item.id) {
                    _ = foundCode(item.body, source: data.name(for: item.address), from: id)
                }
            }
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
            onCall?(call.state)
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
        case MessageType.usage:
            guard let report = envelope.usage else { return }
            data.usage = UsageReport(since: report.since, totalMs: max(0, report.totalMs),
                                     apps: Array(report.apps.prefix(12)), unlocks: report.unlocks)
            data.usageTime = Date()
            TestEnv.log("PHONE_USAGE \(report.totalMs / 60_000) \(report.apps.map { "\($0.name) \($0.ms / 60_000)" }.joined(separator: ",")) unlocks=\(report.unlocks ?? -1)")
        case MessageType.gallery:
            data.receiveGallery(envelope.gallery ?? [], more: envelope.more == true, end: envelope.galleryEnd == true, error: envelope.error)
            TestEnv.log("PHONE_GALLERY \(data.gallery.count) end=\(data.galleryEnd)")
            if TestEnv.value("PHONELINK_TEST_PROBE_PHONE") == "1", let first = data.gallery.first, !didProbeGallery {
                didProbeGallery = true
                galleryWanted[FileNames.sanitize(first.name)] = .save
                session.send(Self.galleryGet(first.id))
            }
        case MessageType.fsListing:
            data.receiveListing(path: envelope.path ?? "", entries: envelope.entries ?? [], more: envelope.more == true, error: envelope.error)
            TestEnv.log("PHONE_FS \(envelope.path ?? "") \((envelope.entries ?? []).map(\.name).joined(separator: ",")) \(envelope.error ?? "")")
        default:
            break
        }
    }

    /// Notifications from every connected phone that shares them, newest first, for the notch.
    /// Phone notifications on all connected phones, for the Dock and menu bar number.
    private(set) var alertCount = 0

    private func updateBadge() {
        let count = peers.filter { $0.isPaired && $0.isConnected }.reduce(0) { $0 + (phoneData[$1.id]?.notifications.count ?? 0) }
        guard count != alertCount else { return }
        alertCount = count
        if !TestEnv.isDryRun { NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil }
    }

    var phoneAlerts: [PhoneAlert] {
        peers.filter { $0.isPaired && $0.isConnected }.flatMap { peer in
            phone(peer.id).notifications.map { PhoneAlert(peerId: peer.id, phone: peer.name, item: $0) }
        }
        .sorted { $0.item.time > $1.item.time }
    }

    var hasPhoneAlerts: Bool {
        peers.contains { $0.isPaired && $0.isConnected && phone($0.id).features.contains("notifications") }
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

    // MARK: Terminal

    private func handleTerminal(_ type: String, _ message: TerminalMessage, from id: String, session: PeerSession) {
        let key = "\(id):\(message.id)"
        switch type {
        case MessageType.terminalOpen:
            guard terminalEnabled else {
                return session.send(Envelope(type: MessageType.terminalClosed, terminal: TerminalMessage(
                    id: message.id, error: "Terminal is turned off on the Mac. Turn it on in DyskLink on the Mac, on this phone's page.")))
            }
            guard terminals[key] == nil else { return }
            guard terminals.values.filter({ $0.peerId == id }).count < Self.maxTerminalsPerPhone else {
                return session.send(Envelope(type: MessageType.terminalClosed, terminal: TerminalMessage(
                    id: message.id, error: "Close a terminal first. Up to \(Self.maxTerminalsPerPhone) can be open.")))
            }
            let shell = PtyShell(id: message.id)
            shell.onOutput = { [weak self, weak session] data in
                Task { @MainActor in
                    guard self?.terminals[key] != nil else { return }
                    session?.send(Envelope(type: MessageType.terminalOutput, terminal: TerminalMessage(id: message.id, data: data.base64EncodedString())))
                }
            }
            shell.onExit = { [weak self, weak session] code in
                Task { @MainActor in
                    guard let self, self.terminals.removeValue(forKey: key) != nil else { return }
                    TestEnv.log("TERMINAL_CLOSED \(code)")
                    session?.send(Envelope(type: MessageType.terminalClosed, terminal: TerminalMessage(id: message.id, exitCode: Int(code))))
                }
            }
            do {
                try shell.start(cols: message.cols ?? 80, rows: message.rows ?? 24)
            } catch {
                return session.send(Envelope(type: MessageType.terminalClosed, terminal: TerminalMessage(id: message.id, error: "The shell couldn't start.")))
            }
            terminals[key] = (id, shell)
            TestEnv.log("TERMINAL_OPENED")
            session.send(Envelope(type: MessageType.terminalOpened, terminal: TerminalMessage(id: message.id)))
            let phone = peers.first { $0.id == id }?.name ?? "A phone"
            // Always visible on the Mac, so a terminal never opens unnoticed.
            notifier.show(id: "terminal:\(key)", title: "Terminal opened from \(phone)", subtitle: nil,
                          body: "It runs as you. Turn Terminal off on the phone's page in DyskLink to stop it.")
        case MessageType.terminalInput:
            guard let shell = terminals[key]?.shell, let data = message.data.flatMap({ Data(base64Encoded: $0) }) else { return }
            shell.write(data)
        case MessageType.terminalResize:
            guard let shell = terminals[key]?.shell, let cols = message.cols, let rows = message.rows else { return }
            shell.resize(cols: cols, rows: rows)
        case MessageType.terminalClose:
            terminals[key]?.shell.hangUp()
        default:
            break
        }
    }

    func terminalCount(of id: String) -> Int { terminals.values.filter { $0.peerId == id }.count }

    func endTerminals(of id: String? = nil) {
        for (key, value) in terminals where id == nil || value.peerId == id {
            value.shell.hangUp()
            terminals[key] = nil
            let sessionId = String(key.split(separator: ":", maxSplits: 1).last ?? "")
            sessions[value.peerId]?.send(Envelope(type: MessageType.terminalClosed, terminal: TerminalMessage(
                id: sessionId, error: "The terminal was ended on the Mac.")))
        }
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

    // MARK: - Phone camera

    private func handleCamera(_ envelope: Envelope, from id: String, session: PeerSession) {
        switch envelope.type {
        case MessageType.cameraStarted:
            guard let info = envelope.screen, info.width > 0, info.height > 0 else { return }
            if let current = camera, current.peerId != id {
                return session.send(Envelope(type: MessageType.cameraStop))
            }
            let rotation = ((envelope.rotation ?? 0) % 360 + 360) % 360 / 90 * 90
            let facing = envelope.text == "front" ? "front" : "back"
            let name = session.hello?.name ?? records[id]?.name ?? "Phone"
            let isNew = camera == nil
            TestEnv.log("CAMERA_STARTED \(info.width)x\(info.height) \(facing) \(rotation)")
            cameraRequests.remove(id)
            cameraError[id] = nil
            let sizeChanged = camera?.info != info
            camera = CameraSession(peerId: id, peerName: name, info: info, facing: facing, rotation: rotation)
            if isNew || sizeChanged {
                cameraDecoder.reset()
                cameraDecoder.onFrame = { buffer in
                    DispatchQueue.main.async { MainActor.assumeIsolated { CameraWindow.display(buffer) } }
                }
            }
            if !TestEnv.isDryRun, let camera { CameraWindow.show(model: self, session: camera) }
            session.send(Envelope(type: MessageType.cameraSync))
        case MessageType.cameraFrame:
            guard camera?.peerId == id, let text = envelope.video, let data = Data(base64Encoded: text) else { return }
            if !cameraDecoder.decode(data), Date().timeIntervalSince(lastCameraSync) > 1 {
                lastCameraSync = Date()
                session.send(Envelope(type: MessageType.cameraSync))
            }
        case MessageType.cameraStopped:
            TestEnv.log("CAMERA_STOPPED \(envelope.error ?? "")")
            cameraRequests.remove(id)
            cameraError[id] = envelope.error
            if camera?.peerId == id { endCamera() }
        default:
            break
        }
    }

    /// The phone shows a notification; the camera only starts after a tap there.
    func requestCamera(from id: String) {
        guard records[id] != nil, let session = sessions[id] else { return }
        cameraError[id] = nil
        cameraRequests.insert(id)
        session.send(Envelope(type: MessageType.cameraRequest))
    }

    func cancelCameraRequest(for id: String) { cameraRequests.remove(id) }

    /// True when this device is connected through a USB cable.
    func isUsb(_ id: String) -> Bool { sessions[id]?.isLoopback == true }

    func stopCamera() {
        guard let current = camera else { return }
        sessions[current.peerId]?.send(Envelope(type: MessageType.cameraStop))
        endCamera()
    }

    func cameraControl(_ action: String) {
        guard let current = camera else { return }
        var envelope = Envelope(type: MessageType.cameraControl)
        envelope.text = action
        sessions[current.peerId]?.send(envelope)
    }

    private func endCamera() {
        camera = nil
        cameraDecoder.reset()
        cameraDecoder.onFrame = nil
        CameraWindow.close()
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
        var outgoing = Transfer(id: transferId, peerId: id, name: name, size: size, outgoing: true)
        outgoing.location = url
        transfers.insert(outgoing, at: 0)
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
                let folder = file.kind == "photo" ? photoFolder(for: id) : file.kind == "gallery" ? galleryFolder(for: id) : downloadFolder
                let incoming = try IncomingFile(peerId: id, name: name, size: size, folder: folder)
                incoming.kind = file.kind
                incomingFiles[file.id] = incoming
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
                // A photo sent again, such as from catching up on earlier photos, isn't saved twice.
                let existing = item.folder.appendingPathComponent(item.name)
                if item.folder.standardizedFileURL.path == photoFolder(for: id).standardizedFileURL.path, FileNames.sameFile(existing, size: item.size, sha256: hash) {
                    try? FileManager.default.removeItem(at: item.partURL)
                    updateTransfer(file.id) { $0.location = existing }
                    replyFile(file.id, ok: true, error: nil, to: session)
                    finishTransfer(file.id, status: .done, detail: "Already on this Mac")
                    TestEnv.log("PHOTO_DUPLICATE \(item.name)")
                    return
                }
                if item.kind == "gallery" {
                    // A gallery copy replaces an older one of the same name.
                    let target = item.folder.appendingPathComponent(item.name)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: item.partURL, to: target)
                    updateTransfer(file.id) { $0.location = target }
                    replyFile(file.id, ok: true, error: nil, to: session)
                    finishTransfer(file.id, status: .done, detail: nil)
                    finishGallery(target, action: galleryWanted.removeValue(forKey: item.name) ?? .open)
                    return
                }
                let target = FileNames.unique(in: item.folder, name: item.name)
                try FileManager.default.moveItem(at: item.partURL, to: target)
                updateTransfer(file.id) { $0.location = target }
                if item.kind == "scan", target.pathExtension.lowercased() == "pdf" {
                    // The text layer is added afterwards, so the scan is there right away.
                    Task.detached(priority: .utility) {
                        let pages = SearchablePDF.addText(to: target)
                        TestEnv.log("SCAN_TEXT \(pages)")
                    }
                }
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
        var finished: Transfer?
        updateTransfer(id) { transfer in
            guard transfer.status == .active else { return }
            transfer.status = status
            transfer.detail = detail
            finished = transfer
        }
        if let finished { record(finished) }
        if transfers.count > 20 { transfers.removeLast(transfers.count - 20) }
    }

    // MARK: - File history

    private func record(_ transfer: Transfer) {
        let device = peers.first { $0.id == transfer.peerId }?.name ?? records[transfer.peerId]?.name ?? "Device"
        history.insert(FileRecord(
            id: transfer.id, device: device, name: transfer.name, size: transfer.size, outgoing: transfer.outgoing,
            date: Date(), ok: transfer.status == .done, detail: transfer.detail, path: transfer.location?.path
        ), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        saveHistory()
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    func removeFromHistory(_ id: String) {
        history.removeAll { $0.id == id }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([FileRecord].self, from: data) else { return }
        history = decoded
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
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
        info.keepAwake = keepAwakeState?()
        info.charge = chargeState?()
        return info
    }

    /// Tells paired devices about a change on this Mac, such as its charging.
    func infoChanged() { broadcastInfo() }

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

    // MARK: - Other Macs

    private func isMac(_ id: String, _ session: PeerSession?) -> Bool {
        (session?.hello?.platform ?? sessions[id]?.hello?.platform ?? records[id]?.platform) == "macos"
    }

    private func applyMacSync() {
        guard identity != nil else { return }
        if macSyncEnabled {
            startBrowser()
            macTimer?.invalidate()
            // Bonjour doesn't report every reconnect, so lost connections are retried on a timer.
            macTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.dialMacs() }
            }
            dialMacs()
        } else {
            browser?.cancel()
            browser = nil
            macTimer?.invalidate()
            macTimer = nil
            macEndpoints = [:]
            nearbyMacs = []
            dialing.values.forEach { $0.close() }
            dialing = [:]
            for (id, session) in sessions where isMac(id, session) { session.close() }
        }
    }

    private func startBrowser() {
        guard browser == nil, TestEnv.value("PHONELINK_PORT") == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PhoneLinkProtocol.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, let mine = self.identity?.deviceId else { return }
                var found: [String: NWEndpoint] = [:]
                for result in results {
                    guard case .bonjour(let txt) = result.metadata, txt["platform"] == "macos",
                          let id = txt["id"], id != mine else { continue }
                    found[id] = result.endpoint
                }
                self.macEndpoints = found
                self.nearbyMacs = Set(found.keys)
                self.dialMacs()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Only the Mac with the smaller ID connects, so two Macs never hold two connections to each other.
    private func dialMacs() {
        guard macSyncEnabled, let identity else { return }
        for (id, endpoint) in macEndpoints where MacSync.shouldDial(from: identity.deviceId, to: id)
            && sessions[id] == nil && dialing[id] == nil {
            dial(endpoint, key: id)
        }
        #if DEBUG
        if let target = TestEnv.value("PHONELINK_TEST_CONNECT_MAC"), sessions.isEmpty, dialing[target] == nil {
            let parts = target.split(separator: ":")
            if parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) {
                dial(.hostPort(host: NWEndpoint.Host(String(parts[0])), port: port), key: target)
            }
        }
        #endif
    }

    private func dial(_ endpoint: NWEndpoint, key: String) {
        guard let identity, let parameters = Self.clientParameters(identity) else { return }
        let session = PeerSession(connection: NWConnection(to: endpoint, using: parameters))
        dialing[key] = session
        attach(session)
    }

    private static func clientParameters(_ identity: LocalIdentity) -> NWParameters? {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        guard let localIdentity = sec_identity_create(identity.identity) else { return nil }
        sec_protocol_options_set_local_identity(security, localIdentity)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        // Self-signed certificate. Trust comes from the fingerprint at pairing, as with phones.
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, .main)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
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
    func loadSnapshotHistory(_ records: [FileRecord], filter: FileHistoryView.Filter) {
        history = records
        historyFilter = filter
        showsHistory = true
    }

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
