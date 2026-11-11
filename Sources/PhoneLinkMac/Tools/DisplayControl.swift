import AppKit
import AudioToolbox
import CoreAudio
import IOKit
import Observation
import os

private let log = Logger(subsystem: "id.dysklink.mac", category: "Displays")

/// DDC/CI messages, the standard way to change settings inside a monitor over its cable.
enum DDC {
    static let brightness: UInt8 = 0x10
    static let volume: UInt8 = 0x62

    static func writePacket(code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    static func readPacket(code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, code]
        return body + [checksum(body)]
    }

    /// Returns nil unless this is a successful reply about the same setting.
    static func parseReply(_ reply: [UInt8], code: UInt8) -> (current: Int, maximum: Int)? {
        guard reply.count >= 11, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }

    private static func checksum(_ body: [UInt8]) -> UInt8 {
        body.reduce(0x6E ^ 0x51, ^)
    }
}

/// Apple Silicon reaches external monitors through a private API, so every symbol is looked up
/// at run time and the app falls back to dimming if macOS removes it.
private enum AVService {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    static let create = symbol("IOAVServiceCreateWithService", Create.self)
    static let write = symbol("IOAVServiceWriteI2C", Transfer.self)
    static let read = symbol("IOAVServiceReadI2C", Transfer.self)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    static func externalServices() -> [CFTypeRef] { externalServicesWithIdentity().map(\.service) }

    /// Each external monitor's DDC service with the monitor it belongs to, as far as the registry tells.
    /// A service follows its framebuffer in the registry, so the framebuffer seen last holds its monitor's EDID facts.
    static func externalServicesWithIdentity() -> [(service: CFTypeRef, identity: MonitorIdentity)] {
        guard let create else { return [] }
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(service: CFTypeRef, identity: MonitorIdentity)] = []
        var lastFramebuffer = MonitorIdentity()
        func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOMobileFramebufferShim") != 0 {
                let attributes = (property(entry, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
                lastFramebuffer = MonitorIdentity(attributes: attributes)
            } else if IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0 {
                guard property(entry, "Location") as? String == "External",
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
                found.append((service, lastFramebuffer))
                lastFramebuffer = MonitorIdentity()
            }
        }
        return found
    }

    static func read(_ service: CFTypeRef, code: UInt8) -> (current: Int, maximum: Int)? {
        guard let read, let write else { return nil }
        var request = DDC.readPacket(code: code)
        for _ in 0..<4 {
            guard write(service, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else {
                usleep(40_000)
                continue
            }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            if read(service, 0x37, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               let parsed = DDC.parseReply(reply, code: code) {
                return parsed
            }
            usleep(40_000)
        }
        return nil
    }

    static func write(_ service: CFTypeRef, code: UInt8, value: UInt16) -> Bool {
        guard let write else { return false }
        var packet = DDC.writePacket(code: code, value: value)
        return write(service, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess
    }
}

/// What the registry says about the monitor behind a DDC service: its EDID vendor, product and serial numbers.
struct MonitorIdentity: Equatable, Sendable {
    var vendor: UInt32?
    var product: UInt32?
    var serial: UInt32?

    init(vendor: UInt32? = nil, product: UInt32? = nil, serial: UInt32? = nil) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
    }

    init(attributes: [String: Any]?) {
        func number(_ key: String) -> UInt32? {
            guard let value = (attributes?[key] as? NSNumber)?.uint64Value, value <= UInt64(UInt32.max) else { return nil }
            return UInt32(value)
        }
        vendor = number("LegacyManufacturerID") ?? (attributes?["ManufacturerID"] as? String).flatMap(Self.eisaVendor)
        product = number("ProductID")
        serial = number("SerialNumber")
    }

    /// "GSM" → 0x1E6D, the number CoreGraphics gives as the vendor.
    static func eisaVendor(_ letters: String) -> UInt32? {
        let values = letters.uppercased().unicodeScalars.map { Int($0.value) - 64 }
        guard values.count == 3, values.allSatisfy({ (1...26).contains($0) }) else { return nil }
        return UInt32(values[0] << 10 | values[1] << 5 | values[2])
    }
}

/// Pairs screens with DDC services. Pure, so it can be tested.
enum MonitorMatch {
    /// Indices into `services` for each screen that could be told apart. With one monitor and one service they go
    /// together. Otherwise a pair needs the same vendor and product, and the serial too when both know it. Screens
    /// left out can't be told apart and aren't guessed.
    static func assign(screens: [(id: CGDirectDisplayID, identity: MonitorIdentity)], services: [MonitorIdentity]) -> [CGDirectDisplayID: Int] {
        if screens.count == 1, services.count == 1 { return [screens[0].id: 0] }
        var result: [CGDirectDisplayID: Int] = [:]
        let options = screens.map { (id: $0.id, choices: candidates($0.identity, services: services)) }
        for option in options where option.choices.count == 1 {
            let index = option.choices[0]
            // Two screens pointing at the one service can't both be right.
            guard options.filter({ $0.choices == [index] }).count == 1 else { continue }
            result[option.id] = index
        }
        // A single service with exactly one screen that can be it, such as a monitor beside a Sidecar iPad or an
        // AirPlay or DisplayLink screen (which have no DDC service), is paired by the loop above: the others have
        // no candidates, so they don't compete for it.
        return result
    }

    /// The services each screen could be: the same vendor and product, and the serial too when both know it.
    static func candidates(_ screen: MonitorIdentity, services: [MonitorIdentity]) -> [Int] {
        let same = services.indices.filter { index in
            let service = services[index]
            guard let vendor = service.vendor, let product = service.product,
                  vendor == screen.vendor, product == screen.product else { return false }
            if let a = service.serial, a != 0, let b = screen.serial, b != 0 { return a == b }
            return true
        }
        // A serial that matches exactly wins over services that don't know theirs.
        let exact = same.filter { services[$0].serial != nil && services[$0].serial != 0 && services[$0].serial == screen.serial }
        return exact.isEmpty ? same : exact
    }

    /// Screens that some DDC service could belong to but that weren't matched. Screens no service could be, such as
    /// Sidecar, AirPlay, or DisplayLink, are left out: they're dimmed anyway and nothing is wrong.
    static func unmatched(screens: [(id: CGDirectDisplayID, identity: MonitorIdentity)], services: [MonitorIdentity],
                          assigned: [CGDirectDisplayID: Int]) -> Int {
        guard !services.isEmpty else { return 0 }
        let free = Set(services.indices).subtracting(assigned.values)
        // A service that doesn't say what monitor it drives could be any screen's.
        let unknown = free.contains { services[$0].vendor == nil || services[$0].product == nil }
        return screens.filter { screen in
            assigned[screen.id] == nil && (unknown || !free.isDisjoint(with: candidates(screen.identity, services: services)))
        }.count
    }
}

private enum InternalBrightness {
    typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getter = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setter = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    static func get(_ display: CGDirectDisplayID) -> Double? {
        var value: Float = 0
        guard let getter, getter(display, &value) == 0 else { return nil }
        return Double(value)
    }

    static func set(_ display: CGDirectDisplayID, _ value: Double) {
        _ = setter?(display, Float(value))
    }
}

/// The current sound output, through the public Core Audio API.
enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static var device: AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var where_ = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static let mainVolume = kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    static var name: String {
        guard let device else { return "No output" }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var where_ = address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr, let value else { return "Output" }
        return value.takeRetainedValue() as String
    }

    /// Nil when this output has no software volume, as with many HDMI monitors.
    static var level: Double? {
        guard let device else { return nil }
        var where_ = address(mainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &where_) else { return nil }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &where_, &settable) == noErr, settable.boolValue else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func set(_ level: Double) {
        guard let device else { return }
        var where_ = address(mainVolume, scope: kAudioDevicePropertyScopeOutput)
        var value = Float32(min(max(level, 0), 1))
        AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}

/// Maps one slider to two ways of dimming. The top of the slider changes the screen's real backlight.
/// Below that, the backlight stays at its lowest and the picture itself is darkened further.
struct BrightnessCurve: Equatable {
    /// The share of the slider that sits below the normal minimum.
    var extraRange: Double

    static let floor = 0.08
    static let extended = BrightnessCurve(extraRange: 0.25)
    static let normal = BrightnessCurve(extraRange: 0)

    func backlight(_ slider: Double) -> Double {
        guard slider > extraRange else { return 0 }
        return min((slider - extraRange) / (1 - extraRange), 1)
    }

    func picture(_ slider: Double) -> Double {
        guard extraRange > 0, slider < extraRange else { return 1 }
        return Self.floor + (1 - Self.floor) * max(slider, 0) / extraRange
    }

    func slider(backlight: Double) -> Double {
        extraRange + (1 - extraRange) * min(max(backlight, 0), 1)
    }
}

struct DisplayItem: Identifiable, Equatable {
    enum Method: Equatable {
        case builtIn
        case monitor
        case dimming
    }

    let id: CGDirectDisplayID
    let name: String
    var method: Method
    var canUseDDC = false
    /// Where the slider sits, from 0 to 1.
    var brightness: Double
    var volume: Double?
}

@MainActor
@Observable
final class DisplayControl {
    private(set) var displays: [DisplayItem] = []
    private(set) var outputName = ""
    private(set) var outputVolume: Double?
    private(set) var isReading = false
    private(set) var needsAccessibility = false
    /// Set when several monitors couldn't be told apart, so they're dimmed instead of being sent DDC changes.
    private(set) var matchProblem: String?

    var linksScreens: Bool { didSet { defaults.set(linksScreens, forKey: "display.link") } }
    var goesDarker: Bool {
        didSet {
            defaults.set(goesDarker, forKey: "display.darker")
            refresh()
        }
    }
    var usesKeys: Bool {
        didSet {
            defaults.set(usesKeys, forKey: "display.keys")
            applyKeys()
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var services: [CGDirectDisplayID: CFTypeRef] = [:]
    @ObservationIgnored private var maximums: [String: Int] = [:]
    @ObservationIgnored private var pending: [String: DispatchWorkItem] = [:]
    @ObservationIgnored private var pictureLevels: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "id.phonelink.ddc", qos: .userInitiated)
    /// A refresh asked for while one is reading runs again when it finishes.
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var refreshForcePending = false

    private var curve: BrightnessCurve { goesDarker ? .extended : .normal }

    init() {
        let stored = UserDefaults.standard
        linksScreens = stored.object(forKey: "display.link") as? Bool ?? true
        goesDarker = stored.object(forKey: "display.darker") as? Bool ?? true
        usesKeys = stored.object(forKey: "display.keys") as? Bool ?? true
    }

    func start() {
        guard observers.isEmpty else { return }
        func watch(_ center: NotificationCenter, _ name: Notification.Name) {
            // After waking or a display change, macOS may have reset the picture dimming, so it's applied again.
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(force: true) }
            }
            observers.append((center: center, token: token))
        }
        watch(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        // macOS clears picture dimming when it wakes.
        watch(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        refresh()
        applyKeys()
    }

    /// Picture dimming returns to normal right away. A monitor keeps the value it was last given.
    func stop() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        BrightnessKeys.shared.update(onStep: nil)
        needsAccessibility = false
        pictureLevels = [:]
        CGDisplayRestoreColorSyncSettings()
        displays = []
    }

    private func applyKeys() {
        guard !observers.isEmpty else { return }
        guard usesKeys else {
            BrightnessKeys.shared.update(onStep: nil)
            needsAccessibility = false
            return
        }
        needsAccessibility = !BrightnessKeys.shared.update { direction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Shared.tools.displays.stepBrightness(direction) }
            }
        }
    }

    private func savedSlider(_ name: String) -> Double? {
        defaults.object(forKey: "display.slider." + name) as? Double
    }

    private func wantsDimming(_ name: String) -> Bool {
        defaults.bool(forKey: "display.dimOnly." + name)
    }

    func setUsesDDC(_ useDDC: Bool, for id: CGDirectDisplayID) {
        guard let item = displays.first(where: { $0.id == id }) else { return }
        defaults.set(!useDDC, forKey: "display.dimOnly." + item.name)
        setPicture(1, for: id)
        refresh()
    }

    /// `force` applies the picture dimming again even where it looks unchanged.
    func refresh(force: Bool = false) {
        guard !isReading else {
            refreshPending = true
            refreshForcePending = refreshForcePending || force
            return
        }
        isReading = true
        refreshOutput()
        let curve = curve
        let screens = NSScreen.screens.compactMap { screen -> (id: CGDirectDisplayID, name: String, saved: Double?, dimOnly: Bool)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let name = screen.localizedName
            return (id, name, savedSlider(name), wantsDimming(name))
        }
        queue.async {
            // Monitors answer slowly, so this stays off the main thread.
            let found = AVService.externalServicesWithIdentity()
            let externals = screens.filter { CGDisplayIsBuiltin($0.id) == 0 }.map {
                (id: $0.id, identity: MonitorIdentity(vendor: CGDisplayVendorNumber($0.id), product: CGDisplayModelNumber($0.id),
                                                       serial: CGDisplaySerialNumber($0.id)))
            }
            let assigned = MonitorMatch.assign(screens: externals, services: found.map(\.identity))
            let unmatched = MonitorMatch.unmatched(screens: externals, services: found.map(\.identity), assigned: assigned)
            var items: [DisplayItem] = []
            var mapped: [CGDirectDisplayID: CFTypeRef] = [:]
            var maximums: [String: Int] = [:]
            /// The saved position only counts if it's below the normal minimum and the screen is still at its minimum.
            func position(backlight: Double, saved: Double?) -> Double {
                if backlight == 0, let saved, saved < curve.extraRange { return saved }
                return curve.slider(backlight: backlight)
            }
            for screen in screens {
                if CGDisplayIsBuiltin(screen.id) != 0 {
                    let backlight = InternalBrightness.get(screen.id) ?? 1
                    items.insert(DisplayItem(id: screen.id, name: screen.name, method: .builtIn,
                                             brightness: position(backlight: backlight, saved: screen.saved)), at: 0)
                    continue
                }
                // Matched by the monitor's EDID facts, never by order: a wrong guess would change the other monitor.
                let service = assigned[screen.id].map { found[$0].service }
                let bright = service.flatMap { AVService.read($0, code: DDC.brightness) }
                if let service, !screen.dimOnly {
                    mapped[screen.id] = service
                    maximums["\(screen.id)-b"] = bright?.maximum ?? 100
                    var volume: Double?
                    if let sound = AVService.read(service, code: DDC.volume) {
                        maximums["\(screen.id)-v"] = sound.maximum
                        volume = Double(sound.current) / Double(sound.maximum)
                    }
                    log.info("A monitor is using DDC, read \(bright != nil)")
                    let backlight = bright.map { Double($0.current) / Double($0.maximum) } ?? 0.5
                    items.append(DisplayItem(id: screen.id, name: screen.name, method: .monitor, canUseDDC: true,
                                             brightness: position(backlight: backlight, saved: screen.saved), volume: volume))
                } else {
                    items.append(DisplayItem(id: screen.id, name: screen.name, method: .dimming, canUseDDC: service != nil,
                                             brightness: screen.saved ?? 1))
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.services = mapped
                    self.maximums = maximums
                    self.isReading = false
                    if unmatched > 0 { log.info("\(unmatched) monitors couldn't be matched to a DDC service") }
                    self.matchProblem = unmatched > 0
                        ? "DyskLink couldn't tell \(unmatched == 1 ? "one monitor" : "\(unmatched) monitors") apart from the others, so \(unmatched == 1 ? "it's" : "they're") dimmed instead of changing the monitor's own brightness."
                        : nil
                    if self.refreshPending {
                        // Something changed while reading: read again with what's there now.
                        let force = force || self.refreshForcePending
                        self.refreshPending = false
                        self.refreshForcePending = false
                        self.refresh(force: force)
                        return
                    }
                    guard !self.observers.isEmpty else { return }
                    if force { self.pictureLevels = [:] }
                    self.displays = items
                    for item in items { self.applyPicture(of: item) }
                }
            }
        }
    }

    func refreshOutput() {
        outputName = SystemVolume.name
        outputVolume = SystemVolume.level
    }

    func setOutputVolume(_ level: Double) {
        outputVolume = level
        SystemVolume.set(level)
    }

    func stepOutputVolume(_ direction: Int) {
        guard let level = SystemVolume.level else { return }
        let next = min(max(level + Double(direction) / 16, 0), 1)
        setOutputVolume(next)
        HintToast.show("Volume \(Int((next * 100).rounded()))%")
    }

    /// The slider that moves every screen to the same position.
    var allScreensBrightness: Double { displays.first?.brightness ?? 1 }

    func setAllScreens(_ value: Double) {
        displays.map(\.id).forEach { setBrightness(value, for: $0) }
    }

    /// One press of a brightness key, or one wheel notch. Screens keep their difference from each other.
    func stepBrightness(_ direction: Int) {
        let step = Double(direction) / 16
        for item in displays where linksScreens || isUnderPointer(item) {
            setBrightness(item.brightness + step, for: item.id)
        }
        let shown = linksScreens ? allScreensBrightness : (displays.first(where: isUnderPointer)?.brightness ?? 0)
        HintToast.show("Brightness \(Int((shown * 100).rounded()))%")
    }

    private func isUnderPointer(_ item: DisplayItem) -> Bool {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let point = CGEvent(source: nil)?.location ?? .zero
        return CGGetDisplaysWithPoint(point, 1, &id, &count) == .success && id == item.id
    }

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let slider = min(max(value, 0), 1)
        displays[index].brightness = slider
        let item = displays[index]
        defaults.set(slider, forKey: "display.slider." + item.name)
        switch item.method {
        case .builtIn:
            InternalBrightness.set(id, curve.backlight(slider))
        case .monitor:
            send(DDC.brightness, curve.backlight(slider), key: "\(id)-b", id: id)
        case .dimming:
            break
        }
        applyPicture(of: item)
    }

    private func applyPicture(of item: DisplayItem) {
        let level = item.method == .dimming ? max(item.brightness, BrightnessCurve.floor) : curve.picture(item.brightness)
        setPicture(level, for: item.id)
    }

    private func setPicture(_ level: Double, for id: CGDirectDisplayID) {
        guard pictureLevels[id] != level else { return }
        let wasDimmed = (pictureLevels[id] ?? 1) < 1
        pictureLevels[id] = level
        if level >= 1 {
            // Resetting affects every screen, so the others are dimmed again right after.
            if wasDimmed {
                CGDisplayRestoreColorSyncSettings()
                for (other, value) in pictureLevels where value < 1 { applyGamma(value, other) }
            }
        } else {
            applyGamma(level, id)
        }
    }

    private func applyGamma(_ level: Double, _ id: CGDirectDisplayID) {
        let channel = CGGammaValue(level)
        CGSetDisplayTransferByFormula(id, 0, channel, 1, 0, channel, 1, 0, channel, 1)
    }

    func setMonitorVolume(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }), displays[index].volume != nil else { return }
        displays[index].volume = value
        send(DDC.volume, value, key: "\(id)-v", id: id)
    }

    /// Dragging a slider makes many changes, and monitors only handle a few a second.
    private func send(_ code: UInt8, _ level: Double, key: String, id: CGDirectDisplayID) {
        guard let service = services[id], let maximum = maximums[key] else { return }
        pending[key]?.cancel()
        let value = UInt16((level * Double(maximum)).rounded())
        let work = DispatchWorkItem {
            if !AVService.write(service, code: code, value: value) {
                log.error("A monitor refused a change")
            }
        }
        pending[key] = work
        queue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    #if DEBUG
    func loadSnapshot(_ items: [DisplayItem], output: String, volume: Double?) {
        displays = items
        outputName = output
        outputVolume = volume
    }

    /// Moves the monitor's brightness a little, reads it back, and returns it to the original value.
    nonisolated static func writeTest() -> String {
        guard let service = AVService.externalServices().first,
              let before = AVService.read(service, code: DDC.brightness)
        else { return "no readable monitor" }
        let target = before.current < 80 ? before.current + 15 : before.current - 15
        let wrote = AVService.write(service, code: DDC.brightness, value: UInt16(target))
        usleep(700_000)
        let after = AVService.read(service, code: DDC.brightness)
        let restored = AVService.write(service, code: DDC.brightness, value: UInt16(before.current))
        usleep(700_000)
        let final = AVService.read(service, code: DDC.brightness)
        return "before \(before.current), target \(target), write ok \(wrote), read after \(after?.current ?? -1), restore ok \(restored), final \(final?.current ?? -1)"
    }

    /// Reads the current values only, and changes nothing on the monitor.
    nonisolated static func probe() -> String {
        let services = AVService.externalServices()
        var lines = ["external services: \(services.count)", "sound: \(SystemVolume.name) \(SystemVolume.level.map { String(format: "%.2f", $0) } ?? "no control")"]
        for service in services {
            let bright = AVService.read(service, code: DDC.brightness)
            let sound = AVService.read(service, code: DDC.volume)
            lines.append("brightness \(bright.map { "\($0.current)/\($0.maximum)" } ?? "no answer"), volume \(sound.map { "\($0.current)/\($0.maximum)" } ?? "no answer")")
        }
        return lines.joined(separator: "\n")
    }
    #endif
}

/// Takes over the brightness keys only. Every other key is left alone without being read.
final class BrightnessKeys: @unchecked Sendable {
    static let shared = BrightnessKeys()

    private static let systemDefined: UInt32 = 14
    private static let brightnessUp = 2
    private static let brightnessDown = 3

    private let lock = NSLock()
    private var onStep: (@Sendable (Int) -> Void)?
    private var tap: CFMachPort?
    private var loop: CFRunLoop?

    /// Returns false when macOS refuses, because Accessibility is off.
    @discardableResult
    func update(onStep: (@Sendable (Int) -> Void)?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.onStep = onStep
        if onStep == nil {
            if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            if let loop { CFRunLoopStop(loop) }
            tap = nil
            loop = nil
            return true
        }
        if tap != nil { return true }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventMask(Self.systemDefined),
            callback: { _, type, event, _ in
                BrightnessKeys.shared.handle(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: nil
        ) else {
            log.error("Brightness keys weren't allowed")
            return false
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let thread = Thread { [weak self] in
            self?.lock.lock()
            self?.loop = CFRunLoopGetCurrent()
            self?.lock.unlock()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "DyskLink brightness keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Returns true when the event was used and shouldn't reach macOS.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let port = tap
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard type.rawValue == Self.systemDefined, let system = NSEvent(cgEvent: event), system.subtype.rawValue == 8 else { return false }
        let key = (system.data1 & 0xFFFF_0000) >> 16
        guard key == Self.brightnessUp || key == Self.brightnessDown else { return false }
        if (system.data1 & 0xFF00) >> 8 == 0xA {
            lock.lock()
            let step = onStep
            lock.unlock()
            step?(key == Self.brightnessUp ? 1 : -1)
        }
        return true
    }
}
