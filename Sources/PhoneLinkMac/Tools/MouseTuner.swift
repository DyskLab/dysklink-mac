import AppKit
import IOKit.hid
import Observation
import os

private let log = Logger(subsystem: "id.dysklink.mac", category: "Mouse")

enum ScrollModifier: String, CaseIterable, Identifiable {
    case command, shift, option, control, optionControl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .command: return "⌘ Command + scroll"
        case .shift: return "⇧ Shift + scroll"
        case .option: return "⌥ Option + scroll"
        case .control: return "⌃ Control + scroll"
        case .optionControl: return "⌥⌃ Option + Control + scroll"
        }
    }

    private var flags: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .optionControl: return [.maskAlternate, .maskControl]
        }
    }

    /// Only an exact match counts, so Command + Shift + scroll keeps its normal behavior.
    static func exact(_ flags: CGEventFlags) -> ScrollModifier? {
        let held = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        return allCases.first { $0.flags == held }
    }

    var cgFlags: CGEventFlags { flags }
}

enum ScrollAction: String, CaseIterable, Identifiable {
    case standard, sideways, fast, slow, zoom, volume, brightness

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Normal"
        case .sideways: return "Scroll sideways"
        case .fast: return "Scroll faster"
        case .slow: return "Scroll slower"
        case .zoom: return "Zoom"
        case .volume: return "Change volume"
        case .brightness: return "Change brightness"
        }
    }
}

struct WheelSettings: Equatable {
    var reverses = false
    var usesFixedLines = false
    var lines = 3
    var actions: [ScrollModifier: ScrollAction] = [:]
    var isActive: Bool { reverses || usesFixedLines || actions.values.contains { $0 != .standard } }

    func action(for flags: CGEventFlags) -> ScrollAction {
        ScrollModifier.exact(flags).flatMap { actions[$0] } ?? .standard
    }

    /// Which way the wheel moved, where 1 is away from the user. Natural scrolling flips the event's sign.
    static func direction(of delta: Int64, natural: Bool) -> Int {
        guard delta != 0 else { return 0 }
        return (delta > 0) != natural ? 1 : -1
    }

    /// Only wheel notches come through here. Trackpads and the Magic Mouse scroll continuously.
    /// Slower scrolling still moves at least one line per notch.
    static func scaled(_ value: Int64, by multiplier: Double) -> Int64 {
        guard value != 0, multiplier != 1 else { return value }
        let result = Int64((Double(value) * multiplier).rounded())
        return result == 0 ? (value > 0 ? 1 : -1) : result
    }

    func transform(_ delta: Int64) -> Int64 {
        guard delta != 0 else { return 0 }
        var result = delta
        if usesFixedLines { result = delta > 0 ? Int64(lines) : -Int64(lines) }
        return reverses ? -result : result
    }
}

/// Private HID property names also used by the system's own mouse settings.
private enum HIDKey {
    static let acceleration = "HIDMouseAcceleration" as CFString
    static let linear = "HIDUseLinearScalingMouseAcceleration" as CFString
    static let resolution = "HIDPointerResolution" as CFString
    static let product = "Product" as CFString
    static let builtIn = "Built-In" as CFString
    static let transport = "Transport" as CFString
}

private typealias HIDClient = IOHIDEventSystemClient

/// The public "simple" client can't read or change these properties, so the full one is looked up at run time.
private func makeHIDClient() -> HIDClient? {
    typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
    if let symbol = dlsym(dlopen(nil, RTLD_NOW), "IOHIDEventSystemClientCreate") {
        return unsafeBitCast(symbol, to: Create.self)(kCFAllocatorDefault)?.takeRetainedValue()
    }
    return IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
}

/// Changes apply to external mice only, and are put back when turned off or when the app quits normally.
@MainActor
@Observable
final class MouseTuner {
    var isLinear: Bool { didSet { store(isLinear, "mouse.linear"); applyPointer() } }
    var speed: Double { didSet { defaults.set(speed, forKey: "mouse.speed"); applyPointer() } }
    var reverses: Bool { didSet { store(reverses, "mouse.reverse"); applyWheel() } }
    var usesFixedLines: Bool { didSet { store(usesFixedLines, "mouse.fixedLines"); applyWheel() } }
    var lines: Int { didSet { defaults.set(lines, forKey: "mouse.lines"); applyWheel() } }
    private(set) var actions: [ScrollModifier: ScrollAction] = [:]
    private(set) var mouseNames: [String] = []
    private(set) var needsAccessibility = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var client: HIDClient?
    /// Saved to disk by mouse name. If the app is killed while this is on, the mouse keeps the changed
    /// values, and they must not be mistaken for the original ones on the next launch.
    @ObservationIgnored private var originals: [String: [String: NSNumber]] = [:]
    @ObservationIgnored private var rescanTimer: Timer?
    @ObservationIgnored private var isOn = false

    init() {
        let stored = UserDefaults.standard
        isLinear = stored.object(forKey: "mouse.linear") as? Bool ?? true
        speed = stored.object(forKey: "mouse.speed") as? Double ?? 1
        reverses = stored.bool(forKey: "mouse.reverse")
        usesFixedLines = stored.bool(forKey: "mouse.fixedLines")
        lines = stored.object(forKey: "mouse.lines") as? Int ?? 3
        originals = stored.dictionary(forKey: "mouse.originals") as? [String: [String: NSNumber]] ?? [:]
        for modifier in ScrollModifier.allCases {
            actions[modifier] = stored.string(forKey: "mouse.action." + modifier.rawValue).flatMap(ScrollAction.init) ?? .standard
        }
    }

    private func store(_ value: Bool, _ key: String) { defaults.set(value, forKey: key) }

    func setAction(_ action: ScrollAction, for modifier: ScrollModifier) {
        actions[modifier] = action
        defaults.set(action.rawValue, forKey: "mouse.action." + modifier.rawValue)
        applyWheel()
    }

    func start() {
        guard !isOn else { return }
        isOn = true
        client = makeHIDClient()
        applyPointer()
        applyWheel()
        // A mouse can be plugged in at any time.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rescanTimer = timer
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        rescanTimer?.invalidate()
        rescanTimer = nil
        WheelTap.shared.update(WheelSettings())
        restorePointer()
        client = nil
        mouseNames = []
        needsAccessibility = false
    }

    private func externalMice() -> [IOHIDServiceClient] {
        guard let client, let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }
        return all.filter { service in
            // Many keyboards also report a mouse function, so only the primary purpose counts.
            let page = (IOHIDServiceClientCopyProperty(service, "PrimaryUsagePage" as CFString) as? NSNumber)?.intValue
            let usage = (IOHIDServiceClientCopyProperty(service, "PrimaryUsage" as CFString) as? NSNumber)?.intValue
            guard page == kHIDPage_GenericDesktop, usage == kHIDUsage_GD_Mouse else { return false }
            let product = IOHIDServiceClientCopyProperty(service, HIDKey.product) as? String ?? ""
            let transport = IOHIDServiceClientCopyProperty(service, HIDKey.transport) as? String ?? ""
            let builtIn = IOHIDServiceClientCopyProperty(service, HIDKey.builtIn) as? Bool ?? false
            return !builtIn && transport != "FIFO" && !transport.contains("SPI") && !product.lowercased().contains("trackpad")
        }
    }

    private func originalsKey(_ service: IOHIDServiceClient) -> String {
        IOHIDServiceClientCopyProperty(service, HIDKey.product) as? String ?? "mouse"
    }

    private func applyPointer() {
        guard isOn else { return }
        let mice = externalMice()
        mouseNames = Array(Set(mice.compactMap { IOHIDServiceClientCopyProperty($0, HIDKey.product) as? String })).sorted()
        for service in mice {
            let id = originalsKey(service)
            if originals[id] == nil {
                var saved: [String: NSNumber] = [:]
                for key in [HIDKey.acceleration, HIDKey.linear, HIDKey.resolution] {
                    if let value = IOHIDServiceClientCopyProperty(service, key) as? NSNumber { saved[key as String] = value }
                }
                originals[id] = saved
                defaults.set(originals, forKey: "mouse.originals")
            }
            if isLinear {
                IOHIDServiceClientSetProperty(service, HIDKey.linear, kCFBooleanTrue)
                IOHIDServiceClientSetProperty(service, HIDKey.acceleration, NSNumber(value: -65536))
            } else {
                restore(service, keys: [HIDKey.linear, HIDKey.acceleration])
            }
            let base = originals[id]?[HIDKey.resolution as String]?.doubleValue ?? 400 * 65536
            // A lower resolution moves the pointer farther for the same hand movement.
            IOHIDServiceClientSetProperty(service, HIDKey.resolution, NSNumber(value: Int(base / max(speed, 0.1))))
        }
    }

    private func restore(_ service: IOHIDServiceClient, keys: [CFString]) {
        guard let saved = originals[originalsKey(service)] else { return }
        for key in keys {
            if let value = saved[key as String] {
                IOHIDServiceClientSetProperty(service, key, value)
            } else if key == HIDKey.linear {
                IOHIDServiceClientSetProperty(service, key, kCFBooleanFalse)
            }
        }
    }

    private func restorePointer() {
        for service in externalMice() {
            restore(service, keys: [HIDKey.linear, HIDKey.acceleration, HIDKey.resolution])
        }
        originals = [:]
        defaults.removeObject(forKey: "mouse.originals")
    }

    /// Called when the app quits.
    func shutDown() {
        stop()
    }

    private func applyWheel() {
        guard isOn else { return }
        let settings = WheelSettings(reverses: reverses, usesFixedLines: usesFixedLines, lines: lines, actions: actions)
        needsAccessibility = !WheelTap.shared.update(settings)
    }

    #if DEBUG
    func debugState() -> String {
        if client == nil { client = makeHIDClient() }
        return externalMice().map { service in
            [HIDKey.resolution, HIDKey.acceleration, HIDKey.linear]
                .map { (IOHIDServiceClientCopyProperty(service, $0)).map { "\($0)" } ?? "none" }
                .joined(separator: "/")
        }.joined(separator: " ")
    }

    static func probe() -> String {
        let tuner = MouseTuner()
        tuner.client = makeHIDClient()
        return tuner.externalMice().map { service in
            let product = IOHIDServiceClientCopyProperty(service, HIDKey.product) as? String ?? "?"
            func read(_ key: CFString) -> String {
                (IOHIDServiceClientCopyProperty(service, key)).map { "\($0)" } ?? "none"
            }
            var line = "mouse: \(product), resolution \(read(HIDKey.resolution)), acceleration \(read(HIDKey.acceleration)), linear \(read(HIDKey.linear))"
            // A change lasting a fraction of a second shows whether macOS accepts it.
            if let original = IOHIDServiceClientCopyProperty(service, HIDKey.resolution) as? NSNumber, original.intValue > 0 {
                IOHIDServiceClientSetProperty(service, HIDKey.resolution, NSNumber(value: original.intValue + 65536))
                usleep(30_000)
                let changed = (IOHIDServiceClientCopyProperty(service, HIDKey.resolution) as? NSNumber)?.intValue
                IOHIDServiceClientSetProperty(service, HIDKey.resolution, original)
                usleep(30_000)
                let back = (IOHIDServiceClientCopyProperty(service, HIDKey.resolution) as? NSNumber)?.intValue
                line += "\n  write test: accepted \(changed == original.intValue + 65536), restored \(back == original.intValue)"
            }
            return line
        }.joined(separator: "\n")
    }
    #endif
}

/// Watches scroll wheel events only, never the keyboard or pointer, on its own thread
/// so a busy window can't delay scrolling.
final class WheelTap: @unchecked Sendable {
    static let shared = WheelTap()

    private let lock = NSLock()
    private var settings = WheelSettings()
    private var tap: CFMachPort?
    private var thread: Thread?
    private var loop: CFRunLoop?

    /// Returns false when the tap is needed but macOS refused it, because Accessibility is off.
    @discardableResult
    func update(_ next: WheelSettings) -> Bool {
        lock.lock()
        settings = next
        lock.unlock()
        if next.isActive { return startIfNeeded() }
        stopTap()
        return true
    }

    private func current() -> WheelSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    private func startIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, _ in
                WheelTap.shared.handle(type, event) ? Unmanaged.passUnretained(event) : nil
            }, userInfo: nil
        ) else {
            log.error("Scroll tap wasn't allowed")
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
        thread.name = "DyskLink scroll wheel"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    private func stopTap() {
        lock.lock()
        defer { lock.unlock() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        tap = nil
        loop = nil
        thread = nil
    }

    /// Returns false when the scroll was used for another action and shouldn't reach any app.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let port = tap
            lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        }
        guard type == .scrollWheel, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return true }
        let settings = current()
        guard settings.isActive else { return true }
        let action = settings.action(for: event.flags)
        let raw = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        switch action {
        case .zoom, .volume, .brightness:
            guard raw != 0 else { return false }
            let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
            let direction = WheelSettings.direction(of: raw, natural: natural)
            run(action, direction: settings.reverses ? -direction : direction)
            return false
        case .standard:
            apply(settings, to: event, multiplier: 1)
        case .fast, .slow, .sideways:
            // The modifier was only there to pick this action, so apps shouldn't see it.
            if let modifier = ScrollModifier.exact(event.flags) {
                event.flags = event.flags.subtracting(modifier.cgFlags)
            }
            apply(settings, to: event, multiplier: action == .fast ? 3 : action == .slow ? 0.34 : 1)
            if action == .sideways { swapAxes(event) }
        }
        return true
    }

    private func apply(_ settings: WheelSettings, to event: CGEvent, multiplier: Double) {
        let axes: [(CGEventField, CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1),
            (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2),
        ]
        for (lines, points, fixed) in axes {
            let original = event.getIntegerValueField(lines)
            guard original != 0 else { continue }
            var next = settings.transform(original)
            if settings.usesFixedLines {
                next = WheelSettings.scaled(next, by: multiplier)
                event.setDoubleValueField(fixed, value: Double(next))
                event.setIntegerValueField(points, value: next * 16)
            } else {
                let sign: Double = (settings.reverses ? -1 : 1) * multiplier
                next = WheelSettings.scaled(next, by: multiplier)
                event.setDoubleValueField(fixed, value: event.getDoubleValueField(fixed) * sign)
                event.setIntegerValueField(points, value: Int64((Double(event.getIntegerValueField(points)) * sign).rounded()))
            }
            event.setIntegerValueField(lines, value: next)
        }
    }

    private func swapAxes(_ event: CGEvent) {
        let pairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ]
        for (first, second) in pairs {
            let value = event.getIntegerValueField(first)
            event.setIntegerValueField(first, value: event.getIntegerValueField(second))
            event.setIntegerValueField(second, value: value)
        }
        let first = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: first)
    }

    private func run(_ action: ScrollAction, direction: Int) {
        guard direction != 0 else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch action {
                case .volume: Shared.tools.displays.stepOutputVolume(direction)
                case .brightness: Shared.tools.displays.stepBrightness(direction)
                case .zoom: Self.pressZoom(direction)
                default: break
                }
            }
        }
    }

    /// The same Command + and Command - keys that browsers and most document apps zoom with.
    private static func pressZoom(_ direction: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let key: CGKeyCode = direction > 0 ? 24 : 27
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
