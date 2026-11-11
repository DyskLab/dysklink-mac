import CryptoKit
import Foundation

enum PhoneLinkProtocol {
    /// 3: pairing by CPace on the typed code. 2: the code is random and typed on the device that asked to pair.
    static let version = 3
    static let serviceType = "_phonelink._tcp"
    static let port: UInt16 = 47821
    /// On the phone, `adb reverse` forwards this port to the Mac, so the phone reaches it over USB at 127.0.0.1.
    static let usbPort: UInt16 = 47823
    /// At most this many copies in one `clipboard.history`.
    static let maxSyncedClips = 500
    static let maxFrameBytes = 1024 * 1024
    /// Raw video above this is dropped, so it still fits in one frame after base64 (to peers without binary frames).
    static let maxScreenFrameBytes = 760 * 1024
    static let pairingTimeout: TimeInterval = 60
    static let maxClipboardChars = 256 * 1024
    /// Platforms that are computers; anything else in hello is a phone.
    static let computers: Set<String> = ["macos", "windows", "linux"]
    /// Raw bytes per `file.chunk`. Every receiver (Mac, Android, desktop) takes chunks of any size, so smaller
    /// chunks keep less bulk data ahead of live messages on the connection.
    static let chunkBytes = 64 * 1024
}

struct Hello: Codable, Equatable {
    var name: String
    var platform: String
    var model: String
    var protocolVersion: Int
    var paired: Bool
    /// The app version, such as "0.2.0". Missing from apps older than 0.2.0.
    var appVersion: String? = nil
    /// Optional protocol features the sender understands, such as `bin1` (binary frames, see `BinaryFrame`).
    /// Missing from apps before 1.2; older apps ignore it.
    var caps: [String]? = nil
}

struct DeviceInfo: Codable, Equatable {
    var batteryPercent: Int?
    var isCharging: Bool?
    var network: String?
    var storageFreeBytes: Int64?
    var storageTotalBytes: Int64?
    var osVersion: String?
    var model: String?
    var carrier: String?
    var cellType: String?
    var signalLevel: Int?
    var wifiLevel: Int?
    var inputTrusted: Bool?
    /// From a Mac: other Macs may use their mouse and keyboard on it.
    var remoteControl: Bool?
    /// From the Mac: Keep Awake is `active`, `idle`, or `unavailable` while the tool is turned off.
    var keepAwake: String?
    /// From the Mac: its network card's hardware address and the network's broadcast address, for Wake-on-LAN.
    /// The private Wi-Fi address when the Mac can read it, and the card's own address.
    var wakeMacs: [String]?
    var wakeBroadcast: String?
    /// From the Mac: whether "Wake for network access" is on.
    var wakeEnabled: Bool?
    /// From the Mac: its charge control, when the helper is installed.
    var charge: MacCharge?
}

/// A photo or video on the phone. `thumb` is a small JPEG in base64.
struct GalleryItem: Codable, Equatable, Identifiable {
    var id: Int64
    var name: String
    var date: Int64
    var size: Int64
    var video: Bool?
    var durationMs: Int64?
    var width: Int?
    var height: Int?
    var thumb: String?

    var isVideo: Bool { video == true }
}

struct DisplayChoice: Codable, Equatable {
    var id: UInt32
    var name: String
    var main: Bool
}

struct MacCharge: Codable, Equatable {
    var limit: Int?
    var status: String
    var topUp: Bool
    var limiting: Bool
}

struct FileMessage: Codable {
    var id: String
    var name: String?
    var size: Int64?
    var data: String?
    var sha256: String?
    var ok: Bool?
    var error: String?
    /// "photo" for photo sync, which saves into Pictures instead of Downloads.
    var kind: String? = nil
}

struct InputEvent: Codable {
    var kind: String
    var dx: Float?
    var dy: Float?
    var button: String?
    var text: String?
    var key: String?
}

struct CommandItem: Codable {
    var id: String
    var name: String
}

struct CommandResult: Codable, Sendable {
    var id: String
    var exitCode: Int32
    var output: String
}

struct NotificationItem: Codable, Identifiable, Equatable {
    var key: String
    var app: String
    var title: String?
    var text: String?
    var time: Int64
    var silent: Bool?
    /// The app's package, such as com.whatsapp.
    var pkg: String?
    /// Base64 PNG of the app icon.
    var icon: String?
    /// Base64 PNG of the sender's photo or the app's large icon.
    var avatar: String?
    /// Base64 JPEG of a picture in the notification.
    var picture: String?
    /// The app's accent color as 0xRRGGBB.
    var color: Int?

    var id: String { key }
}

struct SmsItem: Codable, Identifiable, Equatable {
    var id: Int64
    var threadId: Int64
    var address: String
    var body: String
    var time: Int64
    var outgoing: Bool
}

struct SmsSend: Codable {
    var id: String
    var address: String
    var body: String
}

struct SmsResult: Codable {
    var id: String
    var ok: Bool
    var error: String?
}

struct CallEvent: Codable, Equatable {
    var state: String
    var number: String?
    var time: Int64
}

/// One app in today's screen time on the phone. `icon` is a small base64 PNG.
struct UsageApp: Codable, Identifiable, Equatable {
    var pkg: String
    var name: String
    var ms: Int64
    var icon: String?
    var id: String { pkg }
}

/// The phone's screen time since midnight.
struct UsageReport: Codable, Equatable {
    var since: Int64
    var totalMs: Int64
    var apps: [UsageApp]
    var unlocks: Int?
}

struct ContactItem: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var phones: [String]
}

struct FsEntry: Codable, Identifiable, Equatable {
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Int64

    var id: String { name }
}

struct ScreenInfo: Codable, Equatable {
    var width: Int
    var height: Int
}

/// The `x` and `y` coordinates range from 0 to 1, relative to the phone screen.
struct ControlEvent: Codable {
    var kind: String
    var x: Float?
    var y: Float?
    var text: String?
    var key: String?
}

/// The notch's Todo list, water, and Pomodoro, sent from the Mac so the phone can show and change them.
/// The Mac holds the real data. The phone only asks for changes with `notch.action`.
struct NotchState: Codable, Equatable {
    struct Task: Codable, Equatable {
        var id: String
        var title: String
        var done: Bool
    }

    struct Water: Codable, Equatable {
        var totalMl: Int
        var goalMl: Int
        var glassMl: Int
    }

    struct Focus: Codable, Equatable {
        /// `focus`, `shortBreak`, or `longBreak`.
        var phase: String
        var session: Int
        var sessions: Int
        var running: Bool
        /// Time left in this step when the message was sent. The phone counts down from when it arrives,
        /// so the two clocks don't need to agree.
        var remainingMs: Int64
        var lengthMs: Int64
    }

    var todos: [Task]
    var water: Water
    var focus: Focus
    /// The quick note, and when it last changed in milliseconds since 1970.
    var note: String?
    var noteTime: Int64?
    /// What plays on the Mac, for the phone's media widget.
    var music: Music?

    struct Music: Codable, Equatable {
        var title: String
        var artist: String
        var playing: Bool
    }
}

/// `kind`: `todo.add` (`text`), `todo.toggle`, `todo.delete`, `todo.rename` (`id`, `text`), `water.drink`,
/// `water.undo`, `focus.toggle`, `focus.reset`, and `note.set` (`text`).
struct NotchAction: Codable, Equatable {
    var kind: String
    var id: String?
    var text: String?
}

/// One text copy in `clipboard.history`, sent between Macs.
struct SyncedClip: Codable, Equatable {
    var text: String
    /// Milliseconds since 1970.
    var time: Int64
}

struct Envelope: Codable {
    var type: String
    var hello: Hello?
    var info: DeviceInfo?
    var text: String?
    var file: FileMessage?
    var media: String?
    var input: InputEvent?
    var commands: [CommandItem]?
    var commandId: String?
    var commandResult: CommandResult?
    var features: [String]?
    var notification: NotificationItem?
    var key: String?
    var sms: [SmsItem]?
    var smsSend: SmsSend?
    var smsResult: SmsResult?
    var call: CallEvent?
    var contacts: [ContactItem]?
    /// On `usage`: the phone's screen time today.
    var usage: UsageReport?
    /// On `audio.frame`: 16-bit interleaved PCM in base64. On `audio.started`: the sample rate and channels that follow.
    var audio: String?
    var audioRate: Int?
    var audioChannels: Int?
    /// On `gallery`: a page of photos and videos, newest first.
    var gallery: [GalleryItem]?
    /// On `gallery.list`: how many to skip. On `gallery`: where the reply started.
    var offset: Int?
    /// On `gallery`: nothing after this reply.
    var galleryEnd: Bool?
    /// On `gallery.get`: which photo or video to send.
    var galleryId: Int64?
    var path: String?
    var hidden: Bool?
    var entries: [FsEntry]?
    var error: String?
    var more: Bool?
    var screen: ScreenInfo?
    /// On `macscreen.started`: this Mac's displays. On `macscreen.start`: which one the phone wants.
    var displays: [DisplayChoice]?
    var displayId: UInt32?
    var video: String?
    var keyFrame: Bool?
    /// Phone camera: clockwise degrees that turn the picture upright.
    var rotation: Int?
    var control: ControlEvent?
    var notch: NotchState?
    var notchAction: NotchAction?
    /// On `ring`: `start`, `stop`, or `stopped`.
    var ring: String?
    /// On `mac.action`: `lock`, `awake.start`, or `awake.stop`.
    var macAction: String?
    /// On `clipboard.history`: recent text copies, newest first.
    var clips: [SyncedClip]?
    /// On the `terminal.*` messages.
    var terminal: TerminalMessage?
    /// On the `remote.*` messages between Macs.
    var remote: RemoteEvent?
    /// On `pair.request`, `pair.pake`, and `pair.accept` (pairing version 3).
    var pake: PakeMessage?

    init(type: String, hello: Hello? = nil, info: DeviceInfo? = nil, text: String? = nil,
         file: FileMessage? = nil, media: String? = nil, input: InputEvent? = nil,
         commands: [CommandItem]? = nil, commandId: String? = nil, commandResult: CommandResult? = nil,
         key: String? = nil, smsSend: SmsSend? = nil, path: String? = nil, hidden: Bool? = nil, control: ControlEvent? = nil,
         terminal: TerminalMessage? = nil) {
        self.type = type
        self.hello = hello
        self.info = info
        self.text = text
        self.file = file
        self.media = media
        self.input = input
        self.commands = commands
        self.commandId = commandId
        self.commandResult = commandResult
        self.key = key
        self.smsSend = smsSend
        self.path = path
        self.hidden = hidden
        self.control = control
        self.terminal = terminal
    }
}

enum MessageType {
    static let hello = "hello"
    static let pairRequest = "pair.request"
    static let pairAccept = "pair.accept"
    static let pairReject = "pair.reject"
    /// The showing side's CPace share, sent once the code shows.
    static let pairPake = "pair.pake"
    static let unpair = "unpair"
    static let info = "info"
    static let ping = "ping"
    static let pong = "pong"
    static let clipboard = "clipboard"
    static let clipboardAck = "clipboard.ack"
    static let media = "media"
    static let input = "input"
    static let commandsList = "commands.list"
    static let commandRun = "command.run"
    static let commandResult = "command.result"
    static let fileOffer = "file.offer"
    static let fileChunk = "file.chunk"
    static let fileDone = "file.done"
    static let fileCancel = "file.cancel"
    static let fileResult = "file.result"
    static let features = "features"
    static let notificationPosted = "notification.posted"
    static let notificationRemoved = "notification.removed"
    static let notificationDismiss = "notification.dismiss"
    static let smsList = "sms.list"
    static let smsMessages = "sms.messages"
    static let smsNew = "sms.new"
    static let smsSend = "sms.send"
    static let smsResult = "sms.result"
    static let call = "call"
    static let contactsList = "contacts.list"
    static let contacts = "contacts"
    static let usageList = "usage.list"
    static let usage = "usage"
    static let audioListen = "audio.listen"
    static let audioStarted = "audio.started"
    static let audioFrame = "audio.frame"
    static let audioStop = "audio.stop"
    static let audioStopped = "audio.stopped"
    static let galleryList = "gallery.list"
    static let gallery = "gallery"
    static let galleryGet = "gallery.get"
    static let fsList = "fs.list"
    static let fsListing = "fs.listing"
    static let fsGet = "fs.get"
    static let screenRequest = "screen.request"
    static let screenStarted = "screen.started"
    static let screenFrame = "screen.frame"
    static let screenSync = "screen.sync"
    /// The phone's camera on the Mac. The Mac asks, the phone user starts it, the phone sends video.
    static let cameraRequest = "camera.request"
    static let cameraStarted = "camera.started"
    static let cameraFrame = "camera.frame"
    static let cameraSync = "camera.sync"
    static let cameraStop = "camera.stop"
    static let cameraStopped = "camera.stopped"
    /// `text`: "switch" for the other lens, "torch" to toggle the light.
    static let cameraControl = "camera.control"
    static let screenStop = "screen.stop"
    static let screenStopped = "screen.stopped"
    /// The Mac's screen on a phone. The phone asks, the Mac sends video and takes taps.
    static let macScreenStart = "macscreen.start"
    static let macScreenStarted = "macscreen.started"
    static let macScreenFrame = "macscreen.frame"
    static let macScreenSync = "macscreen.sync"
    static let macScreenStop = "macscreen.stop"
    static let macScreenStopped = "macscreen.stopped"
    static let macScreenPointer = "macscreen.pointer"
    static let control = "control"
    static let notchState = "notch.state"
    static let notchAction = "notch.action"
    static let ring = "ring"
    static let macAction = "mac.action"
    static let clipboardHistory = "clipboard.history"
    /// Mouse and keyboard shared between Macs: the pointer crossed over, input, it went back, or control ended.
    static let remoteEnter = "remote.enter"
    static let remoteInput = "remote.input"
    static let remoteLeave = "remote.leave"
    static let remoteExit = "remote.exit"
    static let terminalOpen = "terminal.open"
    static let terminalOpened = "terminal.opened"
    static let terminalInput = "terminal.input"
    static let terminalOutput = "terminal.output"
    static let terminalResize = "terminal.resize"
    static let terminalClose = "terminal.close"
    static let terminalClosed = "terminal.closed"
}

enum Pairing {
    /// Sent in `pair.reject` when the typed code was wrong, so the other side can try again.
    static let wrongCode = "wrong-code"
    /// Sent in `pair.reject` to a device that can only pair the old way (version 1 or 2).
    static let updateRequired = "update-required"
    static let maxAttempts = 5
    /// The first protocol version that pairs with CPace. Older devices must update before they can pair.
    static let pakeSince = 3

    /// A random code, shown on the device that was asked to pair.
    static func newCode() -> String {
        String(format: "%06u", UInt32.random(in: 0..<1_000_000))
    }

    /// What the user sees when the other device has an older DyskLink.
    static func updateMessage(_ name: String) -> String { "Update DyskLink on \(name) to pair." }

    /// Version 1 code, from both IDs. Kept for the record; new pairings only use CPace ([Pake]).
    static func code(_ idA: String, _ idB: String) -> String {
        let ids = [idA, idB].sorted()
        let input = "phonelink-pair-v1:\(ids[0]):\(ids[1])"
        let bytes = Array(SHA256.hash(data: Data(input.utf8)))
        let value = bytes[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }
}

enum Hex {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// Messages cross from the session queues to the main thread.
extension Envelope: Sendable {}
extension Hello: Sendable {}
extension DeviceInfo: Sendable {}
extension GalleryItem: Sendable {}
extension DisplayChoice: Sendable {}
extension MacCharge: Sendable {}
extension FileMessage: Sendable {}
extension InputEvent: Sendable {}
extension CommandItem: Sendable {}
extension NotificationItem: Sendable {}
extension SmsItem: Sendable {}
extension SmsSend: Sendable {}
extension SmsResult: Sendable {}
extension CallEvent: Sendable {}
extension UsageApp: Sendable {}
extension UsageReport: Sendable {}
extension ContactItem: Sendable {}
extension FsEntry: Sendable {}
extension ScreenInfo: Sendable {}
extension ControlEvent: Sendable {}
extension NotchState: Sendable {}
extension NotchState.Task: Sendable {}
extension NotchState.Water: Sendable {}
extension NotchState.Focus: Sendable {}
extension NotchState.Music: Sendable {}
extension NotchAction: Sendable {}
extension SyncedClip: Sendable {}
