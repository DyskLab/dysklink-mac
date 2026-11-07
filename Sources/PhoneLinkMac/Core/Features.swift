import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import UserNotifications

/// Settings for automated tests only. All inactive in release builds.
enum TestEnv {
    static func value(_ key: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[key]
        #else
        return nil
        #endif
    }

    /// Input and clipboard are only logged, so tests don't move the user's pointer.
    static var isDryRun: Bool { value("PHONELINK_TEST_DRY_RUN") == "1" }

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }
}

// MARK: - Phone data

enum PeerTab: String, CaseIterable, Identifiable {
    case overview, notifications, messages, contacts, files, screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .notifications: return "Notifications"
        case .messages: return "Messages"
        case .contacts: return "Contacts"
        case .files: return "Files"
        case .screen: return "Screen"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .notifications: return "bell.fill"
        case .messages: return "message.fill"
        case .contacts: return "person.2.fill"
        case .files: return "folder.fill"
        case .screen: return "rectangle.on.rectangle"
        }
    }
}

enum SmsStatus: Equatable {
    case sending, sent
    case failed(String)
}

struct SmsThread: Identifiable, Equatable {
    let id: Int64
    let address: String
    let name: String
    let latest: SmsItem
}

struct PhoneSnapshot: Equatable {
    private static let maxNotifications = 100
    private static let maxMessages = 1000

    var isKnown = false
    var features: Set<String> = []
    var notifications: [NotificationItem] = []
    var messages: [SmsItem] = []
    var contacts: [ContactItem] = []
    var lastCall: CallEvent?
    var folder = ""
    var entries: [FsEntry] = []
    var filesLoading = false
    var filesError: String?
    var showHidden = false
    var selectedFiles: Set<String> = []
    var pendingSms: String?
    var smsStatus: SmsStatus?
    private var names: [String: String] = [:]

    /// Data for a feature turned off on the phone is cleared from the Mac right away.
    mutating func apply(features new: Set<String>) {
        isKnown = true
        features = new
        if !new.contains("notifications") { notifications = [] }
        if !new.contains("sms") { messages = []; pendingSms = nil; smsStatus = nil }
        if !new.contains("calls") { lastCall = nil }
        if !new.contains("contacts") { setContacts([]) }
        if !new.contains("files") { folder = ""; entries = []; filesLoading = false; filesError = nil; selectedFiles = []; showHidden = false }
    }

    mutating func upsert(_ item: NotificationItem) {
        notifications.removeAll { $0.key == item.key }
        notifications.append(item)
        notifications.sort { $0.time > $1.time }
        if notifications.count > Self.maxNotifications { notifications.removeLast(notifications.count - Self.maxNotifications) }
    }

    mutating func merge(_ items: [SmsItem]) {
        var byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for item in items { byId[item.id] = item }
        messages = byId.values.sorted { $0.time > $1.time }
        if messages.count > Self.maxMessages { messages.removeLast(messages.count - Self.maxMessages) }
    }

    mutating func setContacts(_ items: [ContactItem]) {
        contacts = items
        names = [:]
        for contact in items {
            for phone in contact.phones { names[Self.numberKey(phone)] = contact.name }
        }
    }

    mutating func beginListing(_ path: String) {
        folder = path
        entries = []
        selectedFiles = []
        filesLoading = true
        filesError = nil
    }

    mutating func receiveListing(path: String, entries new: [FsEntry], more: Bool, error: String?) {
        if let error { filesError = error }
        // Download failures also arrive through this message and must not disturb the open folder.
        guard path == folder else { return }
        entries.append(contentsOf: new)
        filesLoading = more
    }

    func name(for number: String) -> String { names[Self.numberKey(number)] ?? number }

    var threads: [SmsThread] {
        var seen = Set<Int64>()
        return messages.compactMap { item in
            guard seen.insert(item.threadId).inserted else { return nil }
            return SmsThread(id: item.threadId, address: item.address, name: name(for: item.address), latest: item)
        }
    }

    /// The last 9 digits make +62812... and 0812... compare equal.
    private static func numberKey(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        return digits.isEmpty ? number : String(digits.suffix(9))
    }
}

enum ContactExport {
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func vcard(_ contacts: [ContactItem]) -> String {
        contacts.map { contact in
            var lines = ["BEGIN:VCARD", "VERSION:3.0", "FN:\(escape(contact.name))", "N:\(escape(contact.name));;;;"]
            lines += contact.phones.map { "TEL;TYPE=CELL:\(escape($0))" }
            lines.append("END:VCARD")
            return lines.joined(separator: "\r\n")
        }.joined(separator: "\r\n") + "\r\n"
    }
}

/// macOS notifications for phone events.
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var isPrepared = false

    /// A binary with no bundle, like a debug build, crashes when it calls UNUserNotificationCenter.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, !TestEnv.isDryRun else { return nil }
        return .current()
    }

    func prepare() {
        guard !isPrepared, let center else { return }
        isPrepared = true
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func show(id: String, title: String, subtitle: String?, body: String) {
        guard let center else { return }
        prepare()
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func remove(id: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { MainActor.assumeIsolated { MainWindow.show() } }
        completionHandler()
    }
}

// MARK: - Input

/// Runs input from the phone. Without Accessibility permission, macOS ignores these events.
enum DeviceInput {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// An ad-hoc signature changes with every build, so an old grant looks enabled in Settings but
    /// doesn't apply. So this app's entry is removed first, then permission is requested from scratch.
    static func requestTrust() {
        if !isTrusted, let bundle = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", bundle]
            try? reset.run()
            reset.waitUntilExit()
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Only keys on this list may be sent from the phone.
    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "delete": 51, "tab": 48, "escape": 53, "space": 49,
        "left": 123, "right": 124, "down": 125, "up": 126, "f5": 96, "b": 11,
    ]

    private static let mediaKeys: [String: Int32] = [
        "play_pause": 16, "next": 17, "previous": 18,
        "volume_up": 0, "volume_down": 1, "mute": 7,
    ]

    static func handle(_ event: InputEvent) {
        if TestEnv.isDryRun { return TestEnv.log("INPUT \(event.kind) \(event.key ?? event.text ?? "")") }
        switch event.kind {
        case "move": move(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case "click": click(right: event.button == "right")
        case "scroll": scroll(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case "text": type(event.text ?? "")
        case "key": press(event.key ?? "")
        default: break
        }
    }

    static func media(_ action: String) {
        guard let key = mediaKeys[action] else { return }
        if TestEnv.isDryRun { return TestEnv.log("MEDIA \(action)") }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func move(dx: Float, dy: Float) {
        let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        var target = cursor
        target.x = min(max(target.x + CGFloat(dx), bounds.minX), bounds.maxX - 1)
        target.y = min(max(target.y + CGFloat(dy), 0), bounds.height - 1)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func click(right: Bool) {
        let position = cursor
        let button: CGMouseButton = right ? .right : .left
        let types: [CGEventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: position, mouseButton: button)?
                .post(tap: .cghidEventTap)
        }
    }

    private static func scroll(dx: Float, dy: Float) {
        CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    private static func type(_ text: String) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            let units = Array(text.utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func press(_ key: String) {
        guard let code = keyCodes[key] else { return }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Clipboard

/// macOS has no clipboard change notification, so the value is checked every second.
@MainActor
final class ClipboardWatcher {
    var onChange: ((String) -> Void)?

    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var lastText: String?
    private var timer: Timer?

    /// nspasteboard.org standard: password managers mark secret content with these types.
    private static let excludedTypes = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ].map { NSPasteboard.PasteboardType($0) }

    init() {
        pasteboard = TestEnv.isDryRun ? NSPasteboard(name: .init("id.phonelink.test")) : .general
        changeCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func set(_ text: String) {
        lastText = text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changeCount = pasteboard.changeCount
        TestEnv.log("CLIPBOARD_SET \(text)")
    }

    private func check() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let types = pasteboard.types ?? []
        guard !types.contains(where: Self.excludedTypes.contains),
              let text = pasteboard.string(forType: .string), !text.isEmpty,
              text != lastText, text.count <= PhoneLinkProtocol.maxClipboardChars
        else { return }
        lastText = text
        onChange?(text)
    }
}

// MARK: - Commands

struct SavedCommand: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var script: String
}

/// The phone only sends an ID, so only commands registered on this Mac can run.
enum CommandRunner {
    private static let timeout: TimeInterval = 60
    private static let maxOutputBytes = 4096

    static func run(_ command: SavedCommand, completion: @escaping @Sendable (CommandResult) -> Void) {
        let id = command.id
        let script = command.script
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", script]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return completion(CommandResult(id: id, exitCode: -1, output: error.localizedDescription))
            }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            let text = String(decoding: data.suffix(maxOutputBytes), as: UTF8.self)
            completion(CommandResult(id: id, exitCode: process.terminationStatus, output: text))
        }
    }
}

// MARK: - File transfer

enum TransferStatus: Equatable {
    case active, done, failed
}

struct Transfer: Identifiable, Equatable {
    let id: String
    let peerId: String
    let name: String
    let size: Int64
    var transferred: Int64 = 0
    let outgoing: Bool
    var status: TransferStatus = .active
    var detail: String?
    var location: URL?
}

enum FileNames {
    /// File names come from another device, so they must not be able to point at another folder.
    static func sanitize(_ raw: String?) -> String {
        let base = (raw ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let blocked = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "<>:\"|?*"))
        var clean = String(String.UnicodeScalarView(base.unicodeScalars.filter { !blocked.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() }
        return clean.isEmpty ? "file" : String(clean.prefix(200))
    }

    static func unique(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        var index = 1
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)")
            index += 1
        }
        return candidate
    }
}

/// Incoming files go to a temporary file and are moved only once the hash matches.
final class IncomingFile {
    let peerId: String
    let name: String
    let size: Int64
    let partURL: URL
    let handle: FileHandle
    var received: Int64 = 0
    var hasher = SHA256()

    init(peerId: String, name: String, size: Int64, folder: URL) throws {
        self.peerId = peerId
        self.name = name
        self.size = size
        partURL = folder.appendingPathComponent(".\(UUID().uuidString).part")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: partURL)
    }

    func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: partURL)
    }
}

// MARK: - Phone screen

struct ScreenSession: Equatable {
    let peerId: String
    let peerName: String
    var info: ScreenInfo
}
