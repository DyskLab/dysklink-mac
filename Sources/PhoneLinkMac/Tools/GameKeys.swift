import AppKit
import Foundation

/// A key on the Mac mapped to a touch on the phone. Points are 0…1 on the phone screen as it is now.
struct GameKey: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case tap, joystick, look, fire }
    var id = UUID()
    var kind: Kind
    /// The Mac key code for a tap key. Unused for the joystick, which always takes W, A, S, D.
    var keyCode: UInt16 = 0
    var label: String
    var x: Double
    var y: Double
    /// Joystick reach, as a share of the phone's width.
    var radius: Double = 0.08
}

/// A named layout, so each game keeps its own keys.
struct GameProfile: Codable, Equatable {
    var name: String
    var keys: [GameKey]
}

/// Turns key presses into fingers on the phone. Finger 0 is the joystick, 1 to 7 are tap keys, 8 is the click spot
/// while looking, and 9 is the mouse, or the look finger while looking.
struct GameKeyEngine {
    static let joystickFinger = 0
    static let fireFinger = 8
    static let mouseFinger = 9
    static let maxTapKeys = 7
    /// W, A, S, D on a US layout. Key codes don't change with the keyboard layout's letters.
    static let up: UInt16 = 13, left: UInt16 = 0, down: UInt16 = 1, right: UInt16 = 2

    var keys: [GameKey]
    /// Phone width divided by height, so the joystick reaches as far up as sideways.
    var aspect: Double
    private(set) var pressed: Set<UInt16> = []
    private var stick: (x: Double, y: Double)?
    /// Where the look finger is while the mouse aims.
    private(set) var lookAt: (x: Double, y: Double)?
    private var firing = false

    init(keys: [GameKey], aspect: Double) {
        self.keys = keys
        self.aspect = aspect
    }

    private var joystick: GameKey? { keys.first { $0.kind == .joystick } }
    var lookArea: GameKey? { keys.first { $0.kind == .look } }
    var fireSpot: GameKey? { keys.first { $0.kind == .fire } }
    private var taps: [GameKey] { Array(keys.filter { $0.kind == .tap }.prefix(Self.maxTapKeys)) }

    func handles(_ code: UInt16) -> Bool {
        (joystick != nil && [Self.up, Self.left, Self.down, Self.right].contains(code)) || taps.contains { $0.keyCode == code }
    }

    private static func event(_ kind: String, _ finger: Int, _ x: Double, _ y: Double) -> ControlEvent {
        ControlEvent(kind: kind, x: Float(min(max(x, 0), 1)), y: Float(min(max(y, 0), 1)), key: String(finger))
    }

    mutating func keyDown(_ code: UInt16) -> [ControlEvent] {
        guard handles(code), !pressed.contains(code) else { return [] }
        pressed.insert(code)
        if let index = taps.firstIndex(where: { $0.keyCode == code }), joystick == nil || ![Self.up, Self.left, Self.down, Self.right].contains(code) {
            let key = taps[index]
            return [Self.event("tdown", index + 1, key.x, key.y)]
        }
        return updateStick()
    }

    mutating func keyUp(_ code: UInt16) -> [ControlEvent] {
        guard pressed.remove(code) != nil else { return [] }
        if let index = taps.firstIndex(where: { $0.keyCode == code }), joystick == nil || ![Self.up, Self.left, Self.down, Self.right].contains(code) {
            let key = taps[index]
            return [Self.event("tup", index + 1, key.x, key.y)]
        }
        return updateStick()
    }

    private mutating func updateStick() -> [ControlEvent] {
        guard let joystick else { return [] }
        var dx = 0.0, dy = 0.0
        if pressed.contains(Self.left) { dx -= 1 }
        if pressed.contains(Self.right) { dx += 1 }
        if pressed.contains(Self.up) { dy -= 1 }
        if pressed.contains(Self.down) { dy += 1 }
        let length = (dx * dx + dy * dy).squareRoot()
        if length == 0 {
            guard let current = stick else { return [] }
            stick = nil
            return [Self.event("tup", Self.joystickFinger, current.x, current.y)]
        }
        let target = (x: joystick.x + dx / length * joystick.radius,
                      y: joystick.y + dy / length * joystick.radius * aspect)
        var events: [ControlEvent] = []
        if stick == nil { events.append(Self.event("tdown", Self.joystickFinger, joystick.x, joystick.y)) }
        stick = target
        events.append(Self.event("tmove", Self.joystickFinger, target.x, target.y))
        return events
    }

    // MARK: Looking with the mouse

    /// Puts the look finger down in the middle of the look area.
    mutating func lookBegin() -> [ControlEvent] {
        guard let area = lookArea, lookAt == nil else { return [] }
        lookAt = (area.x, area.y)
        return [Self.event("tdown", Self.mouseFinger, area.x, area.y)]
    }

    /// Drags the look finger by a share of the phone's width and height, as a thumb swipes to turn a game camera.
    /// At the edge of the area the finger lifts and starts again from the middle, so turning never runs out.
    mutating func look(dx: Double, dy: Double) -> [ControlEvent] {
        guard let area = lookArea, let current = lookAt else { return [] }
        var next = (x: current.x + dx, y: current.y + dy)
        var events: [ControlEvent] = []
        let reachX = area.radius * 1.6
        let reachY = area.radius * 1.6 * aspect
        if abs(next.x - area.x) > reachX || abs(next.y - area.y) > reachY || !(0.01...0.99).contains(next.x) || !(0.01...0.99).contains(next.y) {
            events.append(Self.event("tup", Self.mouseFinger, current.x, current.y))
            events.append(Self.event("tdown", Self.mouseFinger, area.x, area.y))
            next = (area.x + dx, area.y + dy)
        }
        lookAt = next
        events.append(Self.event("tmove", Self.mouseFinger, next.x, next.y))
        return events
    }

    mutating func lookEnd() -> [ControlEvent] {
        guard let current = lookAt else { return [] }
        lookAt = nil
        return [Self.event("tup", Self.mouseFinger, current.x, current.y)]
    }

    /// The mouse button while looking presses the click spot.
    mutating func fire(_ down: Bool) -> [ControlEvent] {
        guard let spot = fireSpot, down != firing else { return [] }
        firing = down
        return [Self.event(down ? "tdown" : "tup", Self.fireFinger, spot.x, spot.y)]
    }

    /// Where every held finger is, sent again now and then so the phone knows the Mac is still there.
    func held() -> [ControlEvent] {
        var events: [ControlEvent] = []
        if let lookAt { events.append(Self.event("tmove", Self.mouseFinger, lookAt.x, lookAt.y)) }
        if firing, let spot = fireSpot { events.append(Self.event("tmove", Self.fireFinger, spot.x, spot.y)) }
        if let stick { events.append(Self.event("tmove", Self.joystickFinger, stick.x, stick.y)) }
        for (index, key) in taps.enumerated() where pressed.contains(key.keyCode) {
            events.append(Self.event("tmove", index + 1, key.x, key.y))
        }
        return events
    }

    mutating func releaseAll() -> [ControlEvent] {
        var events: [ControlEvent] = []
        for code in pressed { events += keyUp(code) }
        pressed = []
        events += fire(false)
        events += lookEnd()
        return events
    }
}

/// Game keys for the phone screen window: the layout per phone, editing, and play.
@MainActor
@Observable
final class GameKeysModel {
    var enabled = false {
        didSet {
            if !enabled { editing = false; release() }
            onChange?()
        }
    }
    var editing = false {
        didSet {
            pending = nil
            if editing { release() }
            onChange?()
        }
    }
    private(set) var keys: [GameKey] = []
    private(set) var profiles: [GameProfile] = []
    private(set) var current = 0
    var profileName: String { profiles.indices.contains(current) ? profiles[current].name : "Default" }
    /// The mouse aims through the look area; the pointer is held in the window meanwhile.
    private(set) var looking = false
    /// How far a mouse move turns, saved for every game.
    var lookSpeed = UserDefaults.standard.object(forKey: "gamekeys.lookSpeed") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(lookSpeed, forKey: "gamekeys.lookSpeed") }
    }
    @ObservationIgnored var onLookChange: ((Bool) -> Void)?
    /// A spot clicked while editing, waiting for a key.
    var pending: (x: Double, y: Double)? { didSet { onChange?() } }

    @ObservationIgnored var send: ((ControlEvent) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var aspect = 0.5
    @ObservationIgnored private var peerId = ""
    @ObservationIgnored private var engine = GameKeyEngine(keys: [], aspect: 0.5)
    @ObservationIgnored private var heartbeat: Timer?

    func load(peerId: String) {
        self.peerId = peerId
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "gameprofiles.\(peerId)"),
           let saved = try? JSONDecoder().decode([GameProfile].self, from: data), !saved.isEmpty {
            profiles = saved
        } else {
            // Layouts from before profiles become the first profile.
            let old = defaults.data(forKey: "gamekeys.\(peerId)").flatMap { try? JSONDecoder().decode([GameKey].self, from: $0) } ?? []
            profiles = [GameProfile(name: "Default", keys: old)]
        }
        current = min(max(defaults.integer(forKey: "gameprofile.\(peerId)"), 0), profiles.count - 1)
        keys = profiles[current].keys
        rebuild()
    }

    private func save() {
        if profiles.indices.contains(current) { profiles[current].keys = keys }
        if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "gameprofiles.\(peerId)") }
        UserDefaults.standard.set(current, forKey: "gameprofile.\(peerId)")
        rebuild()
        onChange?()
    }

    // MARK: Profiles

    func selectProfile(_ index: Int) {
        guard profiles.indices.contains(index), index != current else { return }
        current = index
        keys = profiles[index].keys
        save()
    }

    func addProfile(named name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        profiles.append(GameProfile(name: trimmed.isEmpty ? "Game \(profiles.count + 1)" : trimmed, keys: []))
        current = profiles.count - 1
        keys = []
        save()
    }

    func renameProfile(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        guard !trimmed.isEmpty, profiles.indices.contains(current) else { return }
        profiles[current].name = trimmed
        save()
    }

    func deleteProfile() {
        guard profiles.count > 1 else { return clear() }
        profiles.remove(at: current)
        current = max(0, current - 1)
        keys = profiles[current].keys
        save()
    }

    // MARK: Looking

    var hasLook: Bool { keys.contains { $0.kind == .look } }

    /// Starts or stops aiming with the mouse. Only works with a look area placed.
    func toggleLook() {
        guard enabled, !editing else { return }
        if looking {
            engine.lookEnd().forEach { send?($0) }
            _ = engine.fire(false).map { send?($0) }
            setLooking(false)
        } else if hasLook {
            engine.lookBegin().forEach { send?($0) }
            setLooking(true)
        }
        updateHeartbeat()
    }

    private func setLooking(_ value: Bool) {
        guard looking != value else { return }
        looking = value
        onLookChange?(value)
        onChange?()
    }

    /// A mouse move while looking, as a share of the phone's width and height.
    func look(dx: Double, dy: Double) {
        guard looking else { return }
        engine.look(dx: dx * lookSpeed, dy: dy * lookSpeed).forEach { send?($0) }
    }

    func fire(_ down: Bool) {
        guard looking else { return }
        engine.fire(down).forEach { send?($0) }
        updateHeartbeat()
    }

    func placeLook(x: Double, y: Double) {
        keys.removeAll { $0.kind == .look }
        keys.append(GameKey(kind: .look, label: "Look", x: x, y: y, radius: 0.12))
        save()
    }

    func placeFire(x: Double, y: Double) {
        keys.removeAll { $0.kind == .fire }
        keys.append(GameKey(kind: .fire, label: "Click", x: x, y: y))
        save()
    }

    private func rebuild() {
        release()
        engine = GameKeyEngine(keys: keys, aspect: aspect)
    }

    func setAspect(_ value: Double) {
        guard value.isFinite, value > 0, abs(value - aspect) > 0.001 else { return }
        aspect = value
        rebuild()
    }

    var tapCount: Int { keys.filter { $0.kind == .tap }.count }
    var hasJoystick: Bool { keys.contains { $0.kind == .joystick } }

    // MARK: Editing

    static func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 48: return "Tab"
        case 36: return "⏎"
        case 51: return "⌫"
        case 56, 60: return "⇧"
        case 59, 62: return "⌃"
        case 58, 61: return "⌥"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    /// Gives the waiting spot a key. Returns false when nothing is waiting.
    func assign(code: UInt16, label: String) -> Bool {
        guard let spot = pending else { return false }
        pending = nil
        guard tapCount < GameKeyEngine.maxTapKeys || keys.contains(where: { $0.kind == .tap && $0.keyCode == code }) else { return true }
        // A key does one thing, so an older spot for it moves here.
        keys.removeAll { $0.kind == .tap && $0.keyCode == code }
        keys.append(GameKey(kind: .tap, keyCode: code, label: label, x: spot.x, y: spot.y))
        save()
        return true
    }

    func placeJoystick(x: Double, y: Double) {
        keys.removeAll { $0.kind == .joystick }
        keys.append(GameKey(kind: .joystick, label: "WASD", x: x, y: y))
        save()
    }

    func move(_ id: UUID, x: Double, y: Double) {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[index].x = min(max(x, 0), 1)
        keys[index].y = min(max(y, 0), 1)
        onChange?()
    }

    func finishMove() { save() }

    func resize(_ id: UUID, by delta: Double) {
        guard let index = keys.firstIndex(where: { $0.id == id }), [.joystick, .look].contains(keys[index].kind) else { return }
        keys[index].radius = min(max(keys[index].radius + delta, 0.03), 0.25)
        save()
    }

    func remove(_ id: UUID) {
        keys.removeAll { $0.id == id }
        save()
    }

    func clear() {
        keys = []
        save()
    }

    // MARK: Playing

    /// Returns true when the key belongs to the game layout.
    func key(_ code: UInt16, down: Bool) -> Bool {
        guard enabled, !editing, engine.handles(code) else { return false }
        let events = down ? engine.keyDown(code) : engine.keyUp(code)
        events.forEach { send?($0) }
        updateHeartbeat()
        return true
    }

    func release() {
        engine.releaseAll().forEach { send?($0) }
        setLooking(false)
        updateHeartbeat()
    }

    private func updateHeartbeat() {
        let held = !engine.pressed.isEmpty || engine.lookAt != nil
        if held, heartbeat == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.held().forEach { self?.send?($0) } }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        } else if !held {
            heartbeat?.invalidate()
            heartbeat = nil
        }
    }
}
