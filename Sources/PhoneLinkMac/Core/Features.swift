import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import ImageIO
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
    case overview, notifications, messages, contacts, files, gallery, screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .notifications: return "Notifications"
        case .messages: return "Messages"
        case .contacts: return "Contacts"
        case .files: return "Files"
        case .gallery: return "Gallery"
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
        case .gallery: return "photo.on.rectangle.angled"
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

/// Contacts under one letter, for the Contacts tab.
struct ContactSection: Equatable, Identifiable {
    let letter: String
    let contacts: [ContactItem]
    var id: String { letter }
}

struct PhoneSnapshot: Equatable {
    private static let maxNotifications = 100
    private static let maxMessages = 1000

    var isKnown = false
    var features: Set<String> = []
    var notifications: [NotificationItem] = []
    var messages: [SmsItem] = [] {
        didSet { rebuildThreads() }
    }
    private(set) var contacts: [ContactItem] = []
    /// Made when the data changes, not on every redraw: threads newest first, and contacts sorted under letters.
    private(set) var threads: [SmsThread] = []
    private(set) var sortedContacts: [ContactItem] = []
    private(set) var contactSections: [ContactSection] = []
    var usage: UsageReport?
    var usageTime: Date?
    var lastCall: CallEvent?
    var folder = ""
    var entries: [FsEntry] = []
    var filesLoading = false
    var filesError: String?
    var showHidden = false
    var selectedFiles: Set<String> = []
    var gallery: [GalleryItem] = []
    var galleryLoading = false
    var galleryEnd = false
    var galleryError: String?
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
        if !new.contains("screentime") { usage = nil; usageTime = nil }
        if !new.contains("gallery") { gallery = []; galleryLoading = false; galleryEnd = false; galleryError = nil }
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
        messages = Array(byId.values.sorted { $0.time > $1.time }.prefix(Self.maxMessages))
    }

    mutating func setContacts(_ items: [ContactItem]) {
        contacts = items
        names = [:]
        for contact in items {
            for phone in contact.phones { names[Self.numberKey(phone)] = contact.name }
        }
        sortedContacts = PhoneSearch.contacts(items, query: "")
        let groups = Dictionary(grouping: sortedContacts, by: { PhoneSearch.section($0.name) })
        contactSections = groups.keys.sorted { $0 == "#" ? false : $1 == "#" ? true : $0 < $1 }
            .map { ContactSection(letter: $0, contacts: groups[$0] ?? []) }
        // Thread names come from contacts.
        rebuildThreads()
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

    /// Adds a gallery page. Photos already shown aren't added twice.
    mutating func receiveGallery(_ items: [GalleryItem], more: Bool, end: Bool, error: String?) {
        if let error { galleryError = error }
        let known = Set(gallery.map(\.id))
        gallery.append(contentsOf: items.filter { !known.contains($0.id) })
        if !more { galleryLoading = false }
        if end { galleryEnd = true }
    }

    func name(for number: String) -> String { names[Self.numberKey(number)] ?? number }

    private mutating func rebuildThreads() {
        var seen = Set<Int64>()
        threads = messages.compactMap { item in
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

    /// Calls back on the main queue with whether the person turned DyskLink's notifications off in System Settings.
    func isDenied(_ done: @escaping @Sendable (Bool) -> Void) {
        guard isPrepared, let center else { return }
        center.getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async { done(denied) }
        }
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
    /// tccutil runs on a background thread so the main thread never waits for it; `done` runs on main after the prompt.
    @MainActor
    static func requestTrust(then done: @escaping @MainActor @Sendable () -> Void = {}) {
        guard !isTrusted, let bundle = Bundle.main.bundleIdentifier else {
            promptForTrust()
            return done()
        }
        Task.detached(priority: .userInitiated) {
            _ = ProcessRunner.run("/usr/bin/tccutil", ["reset", "Accessibility", bundle], timeout: 10)
            await MainActor.run {
                promptForTrust()
                done()
            }
        }
    }

    @MainActor
    private static func promptForTrust() {
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
        case "move", "scroll":
            // Phone numbers are checked like the other Mac's, so a huge or broken one can't crash the conversion.
            guard let dx = RemoteLimits.delta(event.dx.map(Double.init), limit: RemoteLimits.maxMove),
                  let dy = RemoteLimits.delta(event.dy.map(Double.init), limit: RemoteLimits.maxMove) else { return }
            if event.kind == "move" { move(dx: Float(dx), dy: Float(dy)) } else { scroll(dx: Float(dx), dy: Float(dy)) }
        case "click": click(right: event.button == "right")
        case "text": type(event.text ?? "")
        case "key": press(event.key ?? "")
        case "shortcut": shortcut(event.key ?? "")
        default: break
        }
    }

    /// A tap or drag at a point on a display, from the phone viewing the Mac's screen. The point is in global screen
    /// coordinates with the origin at the top left, as CGEvent uses.
    static func pointer(_ kind: String, at point: CGPoint) {
        if TestEnv.isDryRun { return TestEnv.log("POINTER \(kind) \(Int(point.x)) \(Int(point.y))") }
        func post(_ type: CGEventType, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: clicks)
            event?.post(tap: .cghidEventTap)
        }
        switch kind {
        case "move": post(.mouseMoved)
        case "down": post(.leftMouseDown)
        case "drag": post(.leftMouseDragged)
        case "up": post(.leftMouseUp)
        case "click": post(.mouseMoved); post(.leftMouseDown); post(.leftMouseUp)
        // The first tap was already a click, so the second one only adds the double-click.
        case "double": post(.leftMouseDown, clicks: 2); post(.leftMouseUp, clicks: 2)
        case "right": post(.mouseMoved); post(.rightMouseDown, .right); post(.rightMouseUp, .right)
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
        let from = cursor
        let target = keepOnDisplays(CGPoint(x: from.x + CGFloat(dx), y: from.y + CGFloat(dy)), from: from, displays: activeDisplayBounds())
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Every display, in the coordinates CGEvent uses (origin at the top left of the main display, y going down).
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Lets the pointer cross onto any display, including ones above or left of the main one, but never into the gaps
    /// between them: there it stops at the edge of the display it was on.
    static func keepOnDisplays(_ target: CGPoint, from: CGPoint, displays: [CGRect]) -> CGPoint {
        if displays.contains(where: { $0.contains(target) }) { return target }
        guard let home = displays.first(where: { $0.contains(from) }) ?? displays.min(by: {
            hypot($0.midX - from.x, $0.midY - from.y) < hypot($1.midX - from.x, $1.midY - from.y)
        }) else { return target }
        return CGPoint(x: min(max(target.x, home.minX), home.maxX - 1), y: min(max(target.y, home.minY), home.maxY - 1))
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

    /// A key event carries at most 20 UTF-16 units of text (CGEventKeyboardSetUnicodeString); the event itself
    /// keeps more, but apps only get the first 20, so a long scan or dictation was cut short. Text goes out in
    /// pieces of up to 20, each a key down and up as before.
    static let unicodeChunk = 20

    private static func type(_ text: String) {
        for units in unicodeChunks(text) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Splits text into pieces of at most `limit` UTF-16 units, between characters (grapheme clusters), so an emoji,
    /// a flag, or a letter with its accent stays whole. A single character longer than `limit` (a long joined emoji)
    /// is split between its Unicode scalars, which never splits a surrogate pair.
    static func unicodeChunks(_ text: String, limit: Int = unicodeChunk) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        func add(_ units: [UniChar]) {
            if current.count + units.count > limit, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current += units
        }
        for character in text {
            let units = Array(String(character).utf16)
            if units.count <= limit { add(units); continue }
            for scalar in character.unicodeScalars { add(Array(String(scalar).utf16)) }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func press(_ key: String) {
        guard let code = keyCodes[key] else { return }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    /// A key with modifiers from the phone's Stream Deck, such as "cmd+shift+4".
    private static func shortcut(_ text: String) {
        guard let (code, flags) = Shortcut.parse(text) else { return }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// Parses shortcuts like "cmd+shift+4". Only ordinary keyboard keys are allowed, by US key position.
enum Shortcut {
    static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "ctrl": .maskControl, "control": .maskControl,
        "fn": .maskSecondaryFn,
    ]

    static let keys: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
            "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let function: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in function.enumerated() { map["f\(index + 1)"] = code }
        return map
    }()

    static func parse(_ text: String) -> (CGKeyCode, CGEventFlags)? {
        let raw = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw.count <= 40 else { return nil }
        // "cmd++" means Command and the plus key, which is "=" with Shift on a US layout.
        var parts = raw.split(separator: "+", omittingEmptySubsequences: true).map { String($0).trimmingCharacters(in: .whitespaces) }
        if raw.hasSuffix("++") { parts.append("=") }
        guard let last = parts.popLast(), let code = keys[last] else { return nil }
        var flags: CGEventFlags = []
        for part in parts {
            guard let flag = modifiers[part] else { return nil }
            flags.insert(flag)
        }
        if raw.hasSuffix("++") { flags.insert(.maskShift) }
        return (code, flags)
    }
}

// MARK: - Clipboard

/// macOS has no clipboard change notification, so the value is checked every second.
@MainActor
final class ClipboardWatcher {
    var onChange: ((String) -> Void)?
    /// A copied picture as PNG, for other computers. Phones only get text.
    var onImage: ((Data) -> Void)?
    /// Bigger pictures, such as a full-resolution photo, stay on this Mac.
    nonisolated static let maxImageBytes = 24 * 1024 * 1024
    private var lastImageHash: String?

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
        // Each test instance has its own pasteboard, so two of them can test syncing between Macs.
        pasteboard = TestEnv.isDryRun ? NSPasteboard(name: .init("id.phonelink.test" + (TestEnv.value("PHONELINK_PORT") ?? ""))) : .general
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

    /// Decoding, encoding, and hashing pictures runs here, so a large one doesn't stall the app.
    private static let imageQueue = DispatchQueue(label: "dysklink.clipboard.image", qos: .userInitiated)
    /// Bumped on each copy, so a picture still being encoded is dropped when something newer was copied.
    private var imageGeneration = 0

    nonisolated static let maxImagePixels = 100_000_000
    nonisolated static let maxTIFFPixels = 8_000_000

    /// Width × height from the image's header, without decoding it; nil when it isn't an image.
    nonisolated static func pixelCount(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : product
    }

    /// Puts a picture from another computer on the clipboard, as PNG (and TIFF when small) so every app can paste it.
    func setImage(_ png: Data) {
        imageGeneration += 1
        let generation = imageGeneration
        Self.imageQueue.async { [weak self] in
            // The size is read from the header first, so a small file can't decode into gigabytes. A TIFF copy,
            // for apps that only paste TIFF, is made only for pictures small enough that it stays modest.
            // Data no image reader understands can't be decoded into anything large either, so it goes on as it
            // came, without a TIFF copy.
            let pixels = Self.pixelCount(png)
            if let pixels, pixels > Self.maxImagePixels {
                print("Ignored a clipboard picture of \(pixels / 1_000_000) megapixels, over \(Self.maxImagePixels / 1_000_000)")
                return
            }
            let hash = Self.hash(png)
            let tiff = (pixels ?? .max) <= Self.maxTIFFPixels ? NSBitmapImageRep(data: png)?.tiffRepresentation : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.imageGeneration else { return }
                    self.lastImageHash = hash
                    self.pasteboard.declareTypes([.png, .tiff], owner: nil)
                    self.pasteboard.setData(png, forType: .png)
                    if let tiff { self.pasteboard.setData(tiff, forType: .tiff) }
                    self.changeCount = self.pasteboard.changeCount
                    TestEnv.log("CLIPBOARD_IMAGE_SET \(png.count)")
                }
            }
        }
    }

    /// Reads a received picture from disk and puts it on the clipboard, then removes the file.
    func setImage(contentsOf url: URL) {
        Self.imageQueue.async { [weak self] in
            let png = try? Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            guard let png else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setImage(png) } }
        }
    }

    private func check() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        imageGeneration += 1
        let types = pasteboard.types ?? []
        guard !types.contains(where: Self.excludedTypes.contains) else { return }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            // Counted in UTF-16 units, like the Kotlin side, so both agree on what fits.
            guard text != lastText, text.utf16.count <= PhoneLinkProtocol.maxClipboardChars else { return }
            lastText = text
            onChange?(text)
            return
        }
        // A copied file has its own icon as a picture; only real pictures are sent.
        guard onImage != nil, !types.contains(.fileURL) else { return }
        // Only the raw bytes are read here; converting and hashing happen off the main thread.
        let raw: (data: Data, isPNG: Bool)
        if let png = pasteboard.data(forType: .png) { raw = (png, true) }
        else if let tiff = pasteboard.data(forType: .tiff) { raw = (tiff, false) }
        else { return }
        let generation = imageGeneration
        Self.imageQueue.async { [weak self] in
            guard let png = raw.isPNG ? raw.data : Self.png(fromTIFF: raw.data), png.count <= Self.maxImageBytes else { return }
            let hash = Self.hash(png)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.imageGeneration, hash != self.lastImageHash else { return }
                    self.lastImageHash = hash
                    self.onImage?(png)
                }
            }
        }
    }

    static func png(from board: NSPasteboard) -> Data? {
        if let png = board.data(forType: .png) { return png }
        guard let tiff = board.data(forType: .tiff) else { return nil }
        return png(fromTIFF: tiff)
    }

    nonisolated static func png(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    nonisolated private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
            // Stopped after the timeout. A command that leaves something running in the background no longer
            // keeps this waiting on the output pipe.
            guard let result = ProcessRunner.run("/bin/zsh", ["-c", script], timeout: timeout, errorOutput: .merge) else {
                return completion(CommandResult(id: id, exitCode: -1, output: "The shell couldn't be started."))
            }
            let text = String(decoding: result.output.suffix(maxOutputBytes), as: UTF8.self)
            completion(CommandResult(id: id, exitCode: result.status, output: text))
        }
    }
}

// MARK: - File transfer

enum TransferStatus: Equatable {
    case active, done, failed
}

/// A finished transfer, kept on this Mac for the File history page.
struct FileRecord: Codable, Identifiable, Equatable {
    var id: String
    var device: String
    var name: String
    var size: Int64
    var outgoing: Bool
    var date: Date
    var ok: Bool
    var detail: String?
    /// Where the file is on this Mac: the saved copy, or the original that was sent.
    var path: String?

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }
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

    /// True when [url] is a file of exactly this size and SHA-256.
    static func sameFile(_ url: URL, size: Int64, sha256: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == size,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256
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
///
/// The main thread owns `received` and `kind`; writing, hashing, and closing run on the file's own serial queue,
/// so a large transfer doesn't stall the main thread.
final class IncomingFile: @unchecked Sendable {
    let peerId: String
    let name: String
    let size: Int64
    let partURL: URL
    let folder: URL
    /// Bytes accepted so far (main thread).
    var received: Int64 = 0
    /// What the phone said the file is, such as "photo" or "scan".
    var kind: String?

    // Owned by `queue`.
    private let queue = DispatchQueue(label: "dysklink.file-in", qos: .utility)
    private let handle: FileHandle
    private var hasher = SHA256()
    private var failed = false
    private var aborted = false

    init(peerId: String, name: String, size: Int64, folder: URL) throws {
        self.peerId = peerId
        self.folder = folder
        self.name = name
        self.size = size
        partURL = folder.appendingPathComponent(".\(UUID().uuidString).part")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: partURL)
    }

    /// Writes and hashes off the main thread. `failure` runs on the main queue if the disk refused the data.
    func write(_ data: Data, failure: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            guard !aborted, !failed else { return }
            do {
                try handle.write(contentsOf: data)
                hasher.update(data: data)
            } catch {
                failed = true
                DispatchQueue.main.async { MainActor.assumeIsolated { failure() } }
            }
        }
    }

    /// After every write: closes the file and hands the SHA-256 (nil if a write failed) to the main queue.
    /// `sameAs`, when given, is also checked off the main thread: whether that file already has this content.
    func finish(sameAs existing: URL? = nil, _ done: @escaping @MainActor (_ sha256: String?, _ isSame: Bool) -> Void) {
        queue.async { [self] in
            guard !aborted else { return }
            let hash = failed ? nil : hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let closed = (try? handle.close()) != nil
            let same = hash.map { hash in existing.map { FileNames.sameFile($0, size: size, sha256: hash) } ?? false } ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { done(closed ? hash : nil, same) } }
        }
    }

    func abort() {
        queue.async { [self] in
            guard !aborted else { return }
            aborted = true
            try? handle.close()
            try? FileManager.default.removeItem(at: partURL)
        }
    }
}

// MARK: - Phone screen

/// A phone camera shown on the Mac.
struct CameraSession: Equatable {
    let peerId: String
    let peerName: String
    var info: ScreenInfo
    /// "front" or "back".
    var facing: String
    /// Clockwise degrees that turn the picture upright.
    var rotation: Int
}

struct ScreenSession: Equatable {
    let peerId: String
    let peerName: String
    var info: ScreenInfo
}
