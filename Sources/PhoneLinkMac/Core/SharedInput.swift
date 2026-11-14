import AppKit
import CoreGraphics

// One mouse and keyboard for two Macs. The pointer crosses to the other Mac past the edge chosen for it, and comes
// back past the same edge over there. The Mac being used must allow it, and both need Accessibility.

/// One input from the Mac whose mouse and keyboard are in use.
struct RemoteEvent: Codable, Equatable {
    /// `move`, `down`, `up`, `scroll`, `key`, `flags`, or on `remote.enter`/`remote.leave` the crossing itself.
    var kind: String
    var dx: Double?
    var dy: Double?
    /// 0 left, 1 right, 2 and up for other buttons.
    var button: Int?
    var keyCode: Int?
    var keyDown: Bool?
    /// CGEventFlags raw value.
    var flags: UInt64?
    /// On `remote.enter`: the edge where the pointer appears. On `remote.leave`: the edge it left by.
    var edge: String?
    /// How far along that edge, from 0 at the top or left to 1.
    var at: Double?
}

enum ScreenEdge: String, CaseIterable, Codable {
    case left, right, top, bottom

    var opposite: ScreenEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    var label: String {
        switch self {
        case .left: "Left of this Mac"
        case .right: "Right of this Mac"
        case .top: "Above this Mac"
        case .bottom: "Below this Mac"
        }
    }

    /// Whether a movement pushes toward this edge.
    func pushes(dx: Double, dy: Double) -> Bool {
        switch self {
        case .left: dx < 0
        case .right: dx > 0
        case .top: dy < 0
        case .bottom: dy > 0
        }
    }
}

/// Edges in global display coordinates (origin at the top left of the main display, y going down).
enum EdgeMath {
    /// The display whose outer `edge` the point touches, with nothing beyond it, and how far along the edge it is.
    static func hit(_ point: CGPoint, edge: ScreenEdge, displays: [CGRect]) -> (display: CGRect, at: Double)? {
        guard let display = displays.first(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else { return nil }
        let beyond: CGPoint
        let touching: Bool
        switch edge {
        case .left: touching = point.x <= display.minX + 0.5; beyond = CGPoint(x: display.minX - 2, y: point.y)
        case .right: touching = point.x >= display.maxX - 1.5; beyond = CGPoint(x: display.maxX + 2, y: point.y)
        case .top: touching = point.y <= display.minY + 0.5; beyond = CGPoint(x: point.x, y: display.minY - 2)
        case .bottom: touching = point.y >= display.maxY - 1.5; beyond = CGPoint(x: point.x, y: display.maxY + 2)
        }
        guard touching, !displays.contains(where: { $0.contains(beyond) }) else { return nil }
        return (display, fraction(point, along: edge, of: display))
    }

    static func fraction(_ point: CGPoint, along edge: ScreenEdge, of display: CGRect) -> Double {
        let value: Double
        switch edge {
        case .left, .right: value = (point.y - display.minY) / max(display.height, 1)
        case .top, .bottom: value = (point.x - display.minX) / max(display.width, 1)
        }
        return min(max(value, 0), 1)
    }

    /// The outermost display on `edge`, where a pointer arriving from that side appears.
    static func outermost(_ edge: ScreenEdge, displays: [CGRect]) -> CGRect? {
        switch edge {
        case .left: displays.min { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        case .right: displays.max { ($0.maxX, -$0.minY) < ($1.maxX, -$1.minY) }
        case .top: displays.min { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        case .bottom: displays.max { ($0.maxY, -$0.minX) < ($1.maxY, -$1.minX) }
        }
    }

    /// The point just inside `edge` of `display`, `at` of the way along it.
    static func point(on edge: ScreenEdge, of display: CGRect, at: Double, inset: CGFloat = 2) -> CGPoint {
        let along = CGFloat(min(max(at, 0), 1))
        switch edge {
        case .left: return CGPoint(x: display.minX + inset, y: display.minY + along * (display.height - 1))
        case .right: return CGPoint(x: display.maxX - 1 - inset, y: display.minY + along * (display.height - 1))
        case .top: return CGPoint(x: display.minX + along * (display.width - 1), y: display.minY + inset)
        case .bottom: return CGPoint(x: display.minX + along * (display.width - 1), y: display.maxY - 1 - inset)
        }
    }

    /// Control, Option, and Command held together, and nothing else, brings the pointer home.
    static func isHomeChord(_ flags: CGEventFlags) -> Bool {
        let wanted: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        return flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == wanted
    }
}

/// Numbers from the other Mac are checked before they become CoreGraphics values, since a bad one would crash
/// the conversion or post a nonsense event.
enum RemoteLimits {
    static let maxMove: Double = 4000
    static let maxScroll: Double = 4000

    /// Mac virtual key codes are 0...127.
    static func keyCode(_ value: Int?) -> CGKeyCode? {
        guard let value, (0...127).contains(value) else { return nil }
        return CGKeyCode(value)
    }

    /// CoreGraphics knows buttons 0...31.
    static func button(_ value: Int?) -> Int? {
        guard let value, (0...31).contains(value) else { return nil }
        return value
    }

    /// A finite movement, clamped. Nil when missing is allowed as zero; NaN and infinity are refused.
    static func delta(_ value: Double?, limit: Double) -> Double? {
        guard let value else { return 0 }
        guard value.isFinite else { return nil }
        return min(max(value, -limit), limit)
    }

    /// A place along an edge, 0...1. Missing or broken values mean the middle.
    static func fraction(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    /// The event with every number made safe, or nil when it can't be made safe.
    static func sanitize(_ event: RemoteEvent) -> RemoteEvent? {
        var clean = RemoteEvent(kind: event.kind, flags: event.flags)
        switch event.kind {
        case "move":
            guard let dx = delta(event.dx, limit: maxMove), let dy = delta(event.dy, limit: maxMove) else { return nil }
            clean.dx = dx
            clean.dy = dy
        case "scroll":
            guard let dx = delta(event.dx, limit: maxScroll), let dy = delta(event.dy, limit: maxScroll) else { return nil }
            clean.dx = dx
            clean.dy = dy
        case "down", "up":
            guard let button = button(event.button ?? 0) else { return nil }
            clean.button = button
        case "key", "flags":
            guard let code = keyCode(event.keyCode ?? 0) else { return nil }
            clean.keyCode = Int(code)
            clean.keyDown = event.keyDown
        default:
            return nil
        }
        return clean
    }
}

/// Who may move their pointer into this Mac: a Mac, or a Windows or Linux PC whose DyskLink is a source
/// (`pc-shared-input-source` in its hello), and only while "Let paired computers use their mouse and keyboard
/// here" is on. The kind of device comes from its pairing record, never from its hello.
enum RemoteGate {
    static let pcSourceCap = "pc-shared-input-source"

    enum Decision: Equatable { case accept, refuse, ignore }

    /// Whether a device paired as `platform`, with `caps` in its hello, may send `remote.enter` and `remote.input`.
    static func isSender(platform: String?, caps: [String]) -> Bool {
        guard let platform else { return false }
        if platform == "macos" { return true }
        return PhoneLinkProtocol.computers.contains(platform) && caps.contains(pcSourceCap)
    }

    /// What happens to `remote.enter`. A paired computer that may not is answered with `remote.exit`, so its
    /// pointer comes home; anything else is dropped.
    static func enter(platform: String?, caps: [String], accepts: Bool, macSync: Bool, trusted: Bool,
                      busy: Bool, edge: String?) -> Decision {
        guard let platform, PhoneLinkProtocol.computers.contains(platform) else { return .ignore }
        guard isSender(platform: platform, caps: caps), accepts, macSync, trusted, !busy,
              edge.flatMap(ScreenEdge.init(rawValue:)) != nil else { return .refuse }
        return .accept
    }

    /// `remote.input` reaches the target only from a sender; the target itself checks it's the one in control.
    static func input(platform: String?, caps: [String]) -> Bool { isSender(platform: platform, caps: caps) }
}

/// While the pointer is on another computer, the Mac in use pings it every half second; no message from it for 3 s
/// means it went to sleep or off the network, so the pointer comes home instead of freezing here. The Mac being used
/// does the same check on the computer in control once that one has pinged it.
struct RemoteHeartbeat {
    static let interval: TimeInterval = 0.5
    static let timeout: TimeInterval = 3

    private(set) var lastHeard: TimeInterval

    init(now: TimeInterval) { lastHeard = now }

    mutating func heard(now: TimeInterval) { lastHeard = max(lastHeard, now) }

    func isSilent(now: TimeInterval) -> Bool { now - lastHeard > Self.timeout }
}

/// Keys and buttons go back up on the side they went down on. One pressed on the other computer has its release
/// sent there, also after the pointer came home (when it's swallowed here, since the other side let go already); one
/// pressed here before crossing is never released over there.
struct HeldAcross {
    /// Pressed while crossed, so their releases belong to the other computer.
    private(set) var remoteButtons = Set<Int>()
    private(set) var remoteKeys = Set<Int>()
    /// Pressed over there and still held when the pointer came home: their releases here are swallowed.
    private(set) var strayButtons = Set<Int>()
    private(set) var strayKeys = Set<Int>()

    /// While crossed: whether this release goes to the other computer.
    mutating func forwardUp(button: Int) -> Bool { remoteButtons.remove(button) != nil }
    mutating func forwardUp(key: Int) -> Bool { remoteKeys.remove(key) != nil }
    mutating func forwardDown(button: Int) { remoteButtons.insert(button); strayButtons.remove(button) }
    mutating func forwardDown(key: Int) { remoteKeys.insert(key); strayKeys.remove(key) }

    mutating func cameHome() {
        strayButtons.formUnion(remoteButtons)
        strayKeys.formUnion(remoteKeys)
        remoteButtons = []
        remoteKeys = []
    }

    /// At home: whether this local release is left over from the other computer and is swallowed.
    mutating func swallowsUp(button: Int) -> Bool { strayButtons.remove(button) != nil }
    mutating func swallowsUp(key: Int) -> Bool { strayKeys.remove(key) != nil }
    /// At home: a fresh press here means the old one was let go somewhere unseen.
    mutating func localDown(button: Int) { strayButtons.remove(button) }
    mutating func localDown(key: Int) { strayKeys.remove(key) }
}

// MARK: - The Mac whose mouse and keyboard are in use

@MainActor
final class SharedInputController {
    /// Which side of this Mac each other Mac sits on.
    var arrangement: [String: ScreenEdge] = [:] { didSet { refreshTap() } }
    /// Whether that Mac is connected and lets this one in.
    var canEnter: (String) -> Bool = { _ in false }
    var send: (String, Envelope) -> Void = { _, _ in }
    /// The Mac being used now, or nil when the pointer is home.
    var onChange: ((String?) -> Void)?
    /// Whether the edges are watched now, for the settings hint.
    var onWatchingChange: ((Bool) -> Void)?
    /// Whether any mouse button is held here; a drag never crosses an edge.
    var buttonsHeld: () -> Bool = SharedInputController.anyButtonHeld
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private(set) var activePeer: String?
    /// False when Accessibility is off, so the edges can't be watched.
    private(set) var isWatching = false { didSet { if isWatching != oldValue { onWatchingChange?(isWatching) } } }
    private var heartbeat = RemoteHeartbeat(now: 0)
    private var heartbeatTimer: Timer?
    private var held = HeldAcross()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Where the pointer left, to bring it back to the same place.
    private var departure: (display: CGRect, edge: ScreenEdge, at: Double)?
    private var pushes = 0
    private var cursorHidden = false

    func refreshTap() {
        if arrangement.isEmpty { stopTap() } else { startTap() }
    }

    private func startTap() {
        guard tap == nil, !TestEnv.isDryRun else { return }
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
            .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<SharedInputController>.fromOpaque(info).takeUnretainedValue()
            return MainActor.assumeIsolated { controller.handle(type, event) }
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            isWatching = false
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isWatching = true
    }

    private func stopTap() {
        if activePeer != nil { comeHome(notify: true) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
        isWatching = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let peer = activePeer else {
            if Self.isOwn(event) { return Unmanaged.passUnretained(event) }
            // A release left over from a press on the other computer is swallowed; that side let go already.
            if let up = Self.release(type, event) {
                let swallowed = up.isButton ? held.swallowsUp(button: up.number) : held.swallowsUp(key: up.number)
                if swallowed { return nil }
            } else if let down = Self.press(type, event) {
                if down.isButton { held.localDown(button: down.number) } else { held.localDown(key: down.number) }
            }
            // Pointer moves this app posted itself, for a Mac or phone controlling this one, never cross an edge,
            // so control can't loop back to the Mac it came from. Nor does a drag, whose release would be lost.
            if Self.watchesEdge(type: type, own: false, buttonsHeld: buttonsHeld()) { watchEdges(event) } else { pushes = 0 }
            return Unmanaged.passUnretained(event)
        }
        // Everything goes to the other Mac and nothing happens here, except the release of a key or button that went
        // down here before crossing, which goes up here.
        return forward(type, event, to: peer) ? nil : Unmanaged.passUnretained(event)
    }

    /// Only a plain move from the real mouse, with no button held, can cross an edge.
    static func watchesEdge(type: CGEventType, own: Bool, buttonsHeld: Bool) -> Bool {
        type == .mouseMoved && !own && !buttonsHeld
    }

    static func anyButtonHeld() -> Bool {
        (0..<5).contains { CGEventSource.buttonState(.combinedSessionState, button: CGMouseButton(rawValue: $0)!) }
    }

    private static func press(_ type: CGEventType, _ event: CGEvent) -> (isButton: Bool, number: Int)? {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: (true, Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .keyDown: (false, Int(event.getIntegerValueField(.keyboardEventKeycode)))
        default: nil
        }
    }

    private static func release(_ type: CGEventType, _ event: CGEvent) -> (isButton: Bool, number: Int)? {
        switch type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: (true, Int(event.getIntegerValueField(.mouseEventButtonNumber)))
        case .keyUp: (false, Int(event.getIntegerValueField(.keyboardEventKeycode)))
        default: nil
        }
    }

    private static let ownPid = Int64(getpid())

    static func isOwn(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) == ownPid
    }

    private func watchEdges(_ event: CGEvent) {
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        let displays = DeviceInput.activeDisplayBounds()
        for (peer, edge) in arrangement where edge.pushes(dx: dx, dy: dy) {
            guard let hit = EdgeMath.hit(event.location, edge: edge, displays: displays) else { continue }
            // Two pushes in a row, so brushing past an edge doesn't cross by accident.
            pushes += 1
            guard pushes >= 2, canEnter(peer) else { return }
            pushes = 0
            enter(peer, edge: edge, display: hit.display, at: hit.at)
            return
        }
        pushes = 0
    }

    private func enter(_ peer: String, edge: ScreenEdge, display: CGRect, at: Double) {
        activePeer = peer
        departure = (display, edge, at)
        // The pointer stays put and hidden here, while its movement goes to the other Mac.
        CGAssociateMouseAndMouseCursorPosition(0)
        setCursorHidden(true)
        var envelope = Envelope(type: MessageType.remoteEnter)
        envelope.remote = RemoteEvent(kind: "enter", edge: edge.opposite.rawValue, at: at)
        send(peer, envelope)
        TestEnv.log("REMOTE_CROSSED \(edge.rawValue)")
        startHeartbeat()
        onChange?(peer)
    }

    /// Any message from the computer in use counts as an answer.
    func heard(from peer: String) {
        guard activePeer == peer else { return }
        heartbeat.heard(now: now())
    }

    private func startHeartbeat() {
        heartbeat = RemoteHeartbeat(now: now())
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: RemoteHeartbeat.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
    }

    private func beat() {
        guard let peer = activePeer else { return stopHeartbeat() }
        if heartbeat.isSilent(now: now()) {
            print("The computer in use stopped answering; the pointer comes home")
            TestEnv.log("REMOTE_SILENT")
            return comeHome(notify: true)
        }
        send(peer, Envelope(type: MessageType.ping))
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// False when the event stays here instead.
    private func forward(_ type: CGEventType, _ event: CGEvent, to peer: String) -> Bool {
        var remote: RemoteEvent
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            remote = RemoteEvent(kind: "move", dx: event.getDoubleValueField(.mouseEventDeltaX),
                                 dy: event.getDoubleValueField(.mouseEventDeltaY))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            held.forwardDown(button: button)
            remote = RemoteEvent(kind: "down", button: button)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // A button pressed here before crossing is released here, never over there.
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard held.forwardUp(button: button) else { return false }
            remote = RemoteEvent(kind: "up", button: button)
        case .scrollWheel:
            remote = RemoteEvent(kind: "scroll", dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                                 dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        case .keyDown, .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown { held.forwardDown(key: code) } else if !held.forwardUp(key: code) { return false }
            remote = RemoteEvent(kind: "key", keyCode: code, keyDown: type == .keyDown, flags: event.flags.rawValue)
        case .flagsChanged:
            if EdgeMath.isHomeChord(event.flags) { comeHome(notify: true); return true }
            remote = RemoteEvent(kind: "flags", keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                                 flags: event.flags.rawValue)
        default:
            return true
        }
        var envelope = Envelope(type: MessageType.remoteInput)
        envelope.remote = remote
        send(peer, envelope)
        return true
    }

    /// The other Mac says the pointer went back over the edge, `at` of the way along it.
    func pointerReturned(from peer: String, at: Double?) {
        guard activePeer == peer else { return }
        if let at { departure?.at = RemoteLimits.fraction(at) }
        comeHome(notify: false)
    }

    /// Brings the pointer back, for example with the home chord or when the other Mac disconnects.
    func comeHome(notify: Bool) {
        guard let peer = activePeer else { return }
        if notify { send(peer, Envelope(type: MessageType.remoteExit)) }
        activePeer = nil
        stopHeartbeat()
        held.cameHome()
        if let departure {
            CGWarpMouseCursorPosition(EdgeMath.point(on: departure.edge, of: departure.display, at: departure.at, inset: 6))
        }
        departure = nil
        CGAssociateMouseAndMouseCursorPosition(1)
        setCursorHidden(false)
        TestEnv.log("REMOTE_HOME")
        onChange?(nil)
    }

    func peerGone(_ peer: String) {
        if activePeer == peer { comeHome(notify: false) }
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden, !TestEnv.isDryRun else { return }
        cursorHidden = hidden
        if hidden { Self.allowHidingInBackground() }
        _ = hidden ? CGDisplayHideCursor(CGMainDisplayID()) : CGDisplayShowCursor(CGMainDisplayID())
    }

    /// macOS only lets the frontmost app hide the pointer, unless the app sets this connection property, which is
    /// what other mouse-sharing apps do. Without it the pointer just stays still at the edge.
    private static func allowHidingInBackground() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let anywhere = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(anywhere, "_CGSDefaultConnection"),
              let setProperty = dlsym(anywhere, "CGSSetConnectionProperty") else { return }
        let id = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

// MARK: - The Mac being used from the other one

@MainActor
final class SharedInputTarget {
    /// Sends to the Mac in control.
    var send: (String, Envelope) -> Void = { _, _ in }
    var onChange: ((String?) -> Void)?

    private(set) var controller: String?
    /// The edge facing the Mac in control, where the pointer goes back.
    private var homeEdge: ScreenEdge = .left
    private var buttons = Set<Int>()
    private var keysDown = Set<Int>()
    private var flags: CGEventFlags = []
    private var lastClick: (time: TimeInterval, point: CGPoint, button: Int, count: Int64)?
    private var scrollRest = CGPoint.zero
    private var pushes = 0
    /// In a dry run (tests) the pointer isn't moved; this is where it would be, so going home can be tested.
    private var dryCursor: CGPoint?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Set once the computer in control pings (Macs and PCs that send a heartbeat), so one that never does is
    /// never timed out while its user just holds still.
    private var heartbeat: RemoteHeartbeat?
    private var silenceTimer: Timer?

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func enter(from peer: String, edge: ScreenEdge, at: Double) {
        if let controller, controller != peer { send(controller, Envelope(type: MessageType.remoteExit)) }
        release()
        controller = peer
        homeEdge = edge
        heartbeat = nil
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: RemoteHeartbeat.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.checkSilence() }
        }
        let at = RemoteLimits.fraction(at)
        let displays = DeviceInput.activeDisplayBounds()
        guard let display = EdgeMath.outermost(edge, displays: displays) else { return }
        let point = EdgeMath.point(on: edge, of: display, at: at)
        TestEnv.log("REMOTE_ENTER \(edge.rawValue) \(String(format: "%.2f", at))")
        if TestEnv.isDryRun { dryCursor = point } else { CGWarpMouseCursorPosition(point) }
        onChange?(peer)
    }

    func handle(_ event: RemoteEvent, from peer: String) {
        guard controller == peer, let event = RemoteLimits.sanitize(event) else { return }
        if TestEnv.isDryRun {
            TestEnv.log("REMOTE \(event.kind) \(event.keyCode.map(String.init) ?? "") \(event.button.map(String.init) ?? "")")
            if event.kind == "move" { dryMove(dx: event.dx ?? 0, dy: event.dy ?? 0) }
            return
        }
        switch event.kind {
        case "move": move(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case "down": button(event.button ?? 0, down: true)
        case "up": button(event.button ?? 0, down: false)
        case "scroll": scroll(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case "key": key(event.keyCode ?? 0, down: event.keyDown ?? true, flags: event.flags ?? 0)
        case "flags": changeFlags(event.keyCode ?? 0, flags: event.flags ?? 0)
        default: break
        }
    }

    /// Any message from the computer in control; a ping turns on the silence check.
    func heard(from peer: String, ping: Bool) {
        guard controller == peer else { return }
        if heartbeat == nil { if ping { heartbeat = RemoteHeartbeat(now: now()) } } else { heartbeat?.heard(now: now()) }
    }

    /// The computer in control went quiet (asleep, off the network): what it held is let go, and it's told control
    /// ended in case it comes back. True when control ended.
    @discardableResult
    func checkSilence() -> Bool {
        guard let controller else { return false }
        guard let heartbeat, heartbeat.isSilent(now: now()) else { return false }
        print("The computer in control stopped answering; its keys and buttons are let go")
        TestEnv.log("REMOTE_TARGET_SILENT")
        release()
        send(controller, Envelope(type: MessageType.remoteExit))
        return true
    }

    /// Ends control and tells the computer in control, for sleep and the screen locking.
    func end() {
        guard let controller else { return }
        release()
        send(controller, Envelope(type: MessageType.remoteExit))
    }

    /// Lets go of anything still held, so no key or button stays down after control ends.
    func release() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        heartbeat = nil
        guard !TestEnv.isDryRun else {
            if controller != nil { TestEnv.log("REMOTE_RELEASED") }
            controller = nil
            return
        }
        let point = cursor
        for button in buttons { post(mouse: button, down: false, at: point, clicks: 1) }
        for code in keysDown.compactMap(RemoteLimits.keyCode) {
            CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
        }
        if !flags.isEmpty, let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            event.type = .flagsChanged
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
        buttons = []
        keysDown = []
        flags = []
        if controller != nil { onChange?(nil) }
        controller = nil
    }

    /// The edge check of `move`, on `dryCursor`, posting nothing.
    private func dryMove(dx: Double, dy: Double) {
        guard let from = dryCursor else { return }
        let displays = DeviceInput.activeDisplayBounds()
        if homeEdge.pushes(dx: dx, dy: dy), let hit = EdgeMath.hit(from, edge: homeEdge, displays: displays) {
            pushes += 1
            if pushes >= 2, let controller {
                var envelope = Envelope(type: MessageType.remoteLeave)
                envelope.remote = RemoteEvent(kind: "leave", edge: homeEdge.rawValue, at: hit.at)
                send(controller, envelope)
                TestEnv.log("REMOTE_LEAVE \(homeEdge.rawValue)")
                pushes = 0
                dryCursor = nil
                release()
                return
            }
        } else {
            pushes = 0
        }
        dryCursor = DeviceInput.keepOnDisplays(CGPoint(x: from.x + dx, y: from.y + dy), from: from, displays: displays)
    }

    private func move(dx: Double, dy: Double) {
        let from = cursor
        let displays = DeviceInput.activeDisplayBounds()
        // Pushing past the edge facing the other Mac sends the pointer home.
        if homeEdge.pushes(dx: dx, dy: dy), let hit = EdgeMath.hit(from, edge: homeEdge, displays: displays) {
            pushes += 1
            if pushes >= 2, let controller {
                var envelope = Envelope(type: MessageType.remoteLeave)
                envelope.remote = RemoteEvent(kind: "leave", edge: homeEdge.rawValue, at: hit.at)
                send(controller, envelope)
                release()
                pushes = 0
                return
            }
        } else {
            pushes = 0
        }
        let target = DeviceInput.keepOnDisplays(CGPoint(x: from.x + dx, y: from.y + dy), from: from, displays: displays)
        let type: CGEventType
        let button: CGMouseButton
        if buttons.contains(0) { type = .leftMouseDragged; button = .left }
        else if buttons.contains(1) { type = .rightMouseDragged; button = .right }
        else if let other = buttons.first { type = .otherMouseDragged; button = CGMouseButton(rawValue: UInt32(clamping: other)) ?? .center }
        else { type = .mouseMoved; button = .left }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: button)
        event?.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event?.setDoubleValueField(.mouseEventDeltaY, value: dy)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func button(_ number: Int, down: Bool) {
        let point = cursor
        var clicks: Int64 = 1
        if down {
            buttons.insert(number)
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastClick, last.button == number, now - last.time < NSEvent.doubleClickInterval,
               hypot(last.point.x - point.x, last.point.y - point.y) < 5 {
                clicks = last.count + 1
            }
            lastClick = (now, point, number, clicks)
        } else {
            buttons.remove(number)
            clicks = lastClick?.button == number ? lastClick?.count ?? 1 : 1
        }
        post(mouse: number, down: down, at: point, clicks: clicks)
    }

    private func post(mouse number: Int, down: Bool, at point: CGPoint, clicks: Int64) {
        let type: CGEventType
        switch number {
        case 0: type = down ? .leftMouseDown : .leftMouseUp
        case 1: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        let button = CGMouseButton(rawValue: UInt32(clamping: number)) ?? .left
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: clicks)
        event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Double, dy: Double) {
        // Trackpads send fractions of a pixel, so the rest is kept for the next one.
        scrollRest.x += dx
        scrollRest.y += dy
        // The deltas are clamped already; this keeps a broken rest from trapping the conversion.
        guard scrollRest.x.isFinite, scrollRest.y.isFinite else { scrollRest = .zero; return }
        let x = Int32(min(max(scrollRest.x.rounded(.towardZero), -10_000), 10_000))
        let y = Int32(min(max(scrollRest.y.rounded(.towardZero), -10_000), 10_000))
        guard x != 0 || y != 0 else { return }
        scrollRest.x -= CGFloat(x)
        scrollRest.y -= CGFloat(y)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func key(_ code: Int, down: Bool, flags raw: UInt64) {
        guard let keyCode = RemoteLimits.keyCode(code) else { return }
        if down { keysDown.insert(code) } else { keysDown.remove(code) }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
        event?.flags = CGEventFlags(rawValue: raw)
        event?.post(tap: .cghidEventTap)
    }

    private func changeFlags(_ code: Int, flags raw: UInt64) {
        guard let keyCode = RemoteLimits.keyCode(code) else { return }
        flags = CGEventFlags(rawValue: raw)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
extension RemoteEvent: Sendable {}
