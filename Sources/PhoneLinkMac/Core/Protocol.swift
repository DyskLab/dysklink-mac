import CryptoKit
import Foundation

enum PhoneLinkProtocol {
    static let version = 1
    static let serviceType = "_phonelink._tcp"
    static let port: UInt16 = 47821
    static let maxFrameBytes = 1024 * 1024
    static let pairingTimeout: TimeInterval = 60
    static let maxClipboardChars = 256 * 1024
    static let chunkBytes = 192 * 1024
}

struct Hello: Codable, Equatable {
    var name: String
    var platform: String
    var model: String
    var protocolVersion: Int
    var paired: Bool
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
}

struct FileMessage: Codable {
    var id: String
    var name: String?
    var size: Int64?
    var data: String?
    var sha256: String?
    var ok: Bool?
    var error: String?
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
    var path: String?
    var hidden: Bool?
    var entries: [FsEntry]?
    var error: String?
    var more: Bool?
    var screen: ScreenInfo?
    var video: String?
    var keyFrame: Bool?
    var control: ControlEvent?

    init(type: String, hello: Hello? = nil, info: DeviceInfo? = nil, text: String? = nil,
         file: FileMessage? = nil, media: String? = nil, input: InputEvent? = nil,
         commands: [CommandItem]? = nil, commandId: String? = nil, commandResult: CommandResult? = nil,
         key: String? = nil, smsSend: SmsSend? = nil, path: String? = nil, hidden: Bool? = nil, control: ControlEvent? = nil) {
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
    }
}

enum MessageType {
    static let hello = "hello"
    static let pairRequest = "pair.request"
    static let pairAccept = "pair.accept"
    static let pairReject = "pair.reject"
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
    static let fsList = "fs.list"
    static let fsListing = "fs.listing"
    static let fsGet = "fs.get"
    static let screenRequest = "screen.request"
    static let screenStarted = "screen.started"
    static let screenFrame = "screen.frame"
    static let screenSync = "screen.sync"
    static let screenStop = "screen.stop"
    static let screenStopped = "screen.stopped"
    static let control = "control"
}

enum Pairing {
    /// See docs/PROTOCOL.md. Android uses the same formula.
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
