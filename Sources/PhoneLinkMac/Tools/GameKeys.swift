import AppKit
import Foundation

/// A key on the Mac mapped to a touch on the phone. Points are 0…1 on the phone screen as it is now.
struct GameKey: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case tap, joystick, look, fire, skill, swipe }
    /// What a tap key does while its key is held.
    enum Mode: String, Codable, CaseIterable { case tap, toggle, autoFire, combo }
    /// The four keys that push a joystick, in the order up, left, down, right.
    enum KeySet: String, Codable, CaseIterable { case wasd, arrows, ijkl, custom }
    /// Walking: a held modifier switches the joystick between half and full reach.
    enum Walk: String, Codable, CaseIterable { case off, fullWithKey, halfWithKey }

    /// One part of a combo.
    struct Step: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case tap, wait, swipe }
        var id = UUID()
        var kind: Kind
        var x = 0.0
        var y = 0.0
        var toX = 0.0
        var toY = 0.0
        /// A wait's length, or a swipe's duration, in milliseconds.
        var ms = 80.0
    }

    var id = UUID()
    var kind: Kind
    /// The Mac key code for a tap, skill, or swipe key. A joystick uses its key set instead.
    var keyCode: UInt16 = 0
    var label: String
    var x: Double
    var y: Double
    /// Joystick, look area, or skill aim reach, as a share of the phone's width.
    var radius: Double = 0.08
    var mode: Mode = .tap
    /// Auto-fire taps per second.
    var rate: Double = 10
    var keySet: KeySet = .wasd
    var customKeys: [UInt16] = []
    var customLabels: [String] = []
    var walk: Walk = .off
    /// The modifier that changes walking: Shift, Control, or Option (left key codes).
    var walkKey: UInt16 = 56
    /// Where a swipe ends.
    var toX: Double = 0
    var toY: Double = 0
    /// A swipe's length in milliseconds.
    var duration: Double = 120
    /// A skill pressed briefly casts at the button's middle, like a tap.
    var quickCast = false
    var steps: [Step] = []

    /// Keys that hold a finger of their own from the pool.
    var usesFinger: Bool { [.tap, .joystick, .skill, .swipe].contains(kind) }
    /// Keys bound to one keyboard key.
    var isAction: Bool { [.tap, .skill, .swipe].contains(kind) }

    static let wasdKeys: [UInt16] = [13, 0, 1, 2]
    static let arrowKeys: [UInt16] = [126, 123, 125, 124]
    static let ijklKeys: [UInt16] = [34, 38, 40, 37]

    var directionKeys: [UInt16] {
        switch keySet {
        case .wasd: Self.wasdKeys
        case .arrows: Self.arrowKeys
        case .ijkl: Self.ijklKeys
        case .custom: customKeys.count == 4 ? customKeys : Self.wasdKeys
        }
    }

    var directionLabels: [String] {
        switch keySet {
        case .wasd: ["W", "A", "S", "D"]
        case .arrows: ["↑", "←", "↓", "→"]
        case .ijkl: ["I", "J", "K", "L"]
        case .custom: customLabels.count == 4 ? customLabels : ["W", "A", "S", "D"]
        }
    }
}

extension GameKey {
    /// Layouts saved before the newer fields still load, with the defaults for what they lack.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 0
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.08
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .tap
        rate = try c.decodeIfPresent(Double.self, forKey: .rate) ?? 10
        keySet = try c.decodeIfPresent(KeySet.self, forKey: .keySet) ?? .wasd
        customKeys = try c.decodeIfPresent([UInt16].self, forKey: .customKeys) ?? []
        customLabels = try c.decodeIfPresent([String].self, forKey: .customLabels) ?? []
        walk = try c.decodeIfPresent(Walk.self, forKey: .walk) ?? .off
        walkKey = try c.decodeIfPresent(UInt16.self, forKey: .walkKey) ?? 56
        toX = try c.decodeIfPresent(Double.self, forKey: .toX) ?? 0
        toY = try c.decodeIfPresent(Double.self, forKey: .toY) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 120
        quickCast = try c.decodeIfPresent(Bool.self, forKey: .quickCast) ?? false
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }
}

/// A named layout, so each game keeps its own keys.
struct GameProfile: Codable, Equatable {
    var name: String
    var keys: [GameKey]
}

/// Turns key presses into fingers on the phone. Fingers 0 to 7 are a pool: each joystick, tap, skill, or swipe key
/// owns one (joysticks first). 8 is the click spot while looking, and 9 is the mouse, or the look finger while looking.
/// Time is passed in, in milliseconds, so timing can be tested without waiting.
struct GameKeyEngine {
    static let fireFinger = 8
    static let mouseFinger = 9
    /// Fingers 0…7 belong to keys.
    static let fingerPool = 8
    /// W, A, S, D on a US layout. Key codes don't change with the keyboard layout's letters.
    static let up: UInt16 = 13, left: UInt16 = 0, down: UInt16 = 1, right: UInt16 = 2
    /// How long a tap in a combo stays down.
    static let tapMs = 40.0
    /// Swipes move about once a frame.
    static let stepMs = 16.0
    /// A skill let go sooner than this, with quick cast on, taps the button's middle.
    static let quickCastMs = 200.0
    /// The mouse this far from the screen's middle, as a share of the phone's width, aims a skill at full reach.
    static let aimReach = 0.25

    /// One event of a gesture, at a time from its start.
    struct Scheduled: Equatable {
        var at: Double
        var kind: String
        var x: Double
        var y: Double
    }

    private struct Run {
        var finger: Int
        var start: Double
        var timeline: [Scheduled]
        var next = 0
    }

    private struct Repeat {
        var finger: Int
        var x: Double
        var y: Double
        var period: Double
        var nextAt: Double
        var isDown: Bool
    }

    private struct Aim {
        var start: Double
    }

    var keys: [GameKey]
    /// Phone width divided by height, so the joystick reaches as far up as sideways.
    var aspect: Double
    /// The finger each key owns.
    private(set) var fingers: [UUID: Int] = [:]
    private(set) var pressed: Set<UInt16> = []
    /// Every finger that is down on the phone, and where.
    private(set) var down: [Int: (x: Double, y: Double)] = [:]
    /// Where the look finger is while the mouse aims.
    private(set) var lookAt: (x: Double, y: Double)?
    /// The mouse on the phone screen, for aiming skills.
    private(set) var mouse: (x: Double, y: Double)?
    private var firing = false
    private var runs: [UUID: Run] = [:]
    private var repeats: [UUID: Repeat] = [:]
    private var aims: [UUID: Aim] = [:]
    private var stickFor: [UInt16: UUID] = [:]
    private var actionFor: [UInt16: UUID] = [:]
    private var walkKeys: Set<UInt16> = []

    init(keys: [GameKey], aspect: Double) {
        self.keys = keys
        self.aspect = aspect
        let users = keys.filter(\.usesFinger)
        let ordered = users.filter { $0.kind == .joystick } + users.filter { $0.kind != .joystick }
        for (index, key) in ordered.prefix(Self.fingerPool).enumerated() { fingers[key.id] = index }
        // The first key to claim a code gets it; joysticks come first.
        for key in ordered where fingers[key.id] != nil {
            if key.kind == .joystick {
                for code in key.directionKeys where stickFor[code] == nil { stickFor[code] = key.id }
                if key.walk != .off { walkKeys.insert(Self.normalized(key.walkKey)) }
            }
        }
        for key in ordered where fingers[key.id] != nil && key.isAction {
            let code = Self.normalized(key.keyCode)
            if stickFor[code] == nil, actionFor[code] == nil { actionFor[code] = key.id }
        }
    }

    var lookArea: GameKey? { keys.first { $0.kind == .look } }
    var fireSpot: GameKey? { keys.first { $0.kind == .fire } }
    /// True while a swipe, combo, or auto-fire needs `tick`.
    var needsTick: Bool { !runs.isEmpty || !repeats.isEmpty }
    var isAiming: Bool { !aims.isEmpty }

    private func key(_ id: UUID) -> GameKey? { keys.first { $0.id == id } }

    /// Right Shift, Control, and Option count as the left ones.
    static func normalized(_ code: UInt16) -> UInt16 {
        switch code {
        case 60: 56
        case 62: 59
        case 61: 58
        default: code
        }
    }

    func handles(_ code: UInt16) -> Bool {
        let code = Self.normalized(code)
        return stickFor[code] != nil || actionFor[code] != nil || walkKeys.contains(code)
    }

    private mutating func emit(_ kind: String, _ finger: Int, _ x: Double, _ y: Double) -> ControlEvent {
        let x = min(max(x, 0), 1), y = min(max(y, 0), 1)
        if kind == "tup" { down[finger] = nil } else { down[finger] = (x, y) }
        return ControlEvent(kind: kind, x: Float(x), y: Float(y), key: String(finger))
    }

    mutating func keyDown(_ code: UInt16, now: Double = 0) -> [ControlEvent] {
        let code = Self.normalized(code)
        guard handles(code), !pressed.contains(code) else { return [] }
        pressed.insert(code)
        var events: [ControlEvent] = []
        if walkKeys.contains(code) { events += updateSticks() }
        if let id = stickFor[code] {
            events += updateStick(id)
        } else if let id = actionFor[code], let key = key(id) {
            events += press(key, now: now)
        }
        return events
    }

    mutating func keyUp(_ code: UInt16, now: Double = 0) -> [ControlEvent] {
        let code = Self.normalized(code)
        guard pressed.remove(code) != nil else { return [] }
        var events: [ControlEvent] = []
        if walkKeys.contains(code) { events += updateSticks() }
        if let id = stickFor[code] {
            events += updateStick(id)
        } else if let id = actionFor[code], let key = key(id) {
            events += release(key, now: now)
        }
        return events
    }

    private mutating func press(_ key: GameKey, now: Double) -> [ControlEvent] {
        guard let finger = fingers[key.id] else { return [] }
        switch key.kind {
        case .tap:
            switch key.mode {
            case .tap:
                return [emit("tdown", finger, key.x, key.y)]
            case .toggle:
                return [emit(down[finger] == nil ? "tdown" : "tup", finger, key.x, key.y)]
            case .autoFire:
                let period = 1000 / min(max(key.rate, 1), 20)
                repeats[key.id] = Repeat(finger: finger, x: key.x, y: key.y, period: period, nextAt: now + period / 2, isDown: true)
                return [emit("tdown", finger, key.x, key.y)]
            case .combo:
                return start(key.id, finger: finger, timeline: Self.comboTimeline(key), now: now)
            }
        case .swipe:
            return start(key.id, finger: finger, timeline: Self.swipeTimeline(from: (key.x, key.y), to: (key.toX, key.toY), durationMs: key.duration), now: now)
        case .skill:
            aims[key.id] = Aim(start: now)
            var events = [emit("tdown", finger, key.x, key.y)]
            if let mouse {
                let point = Self.aimPoint(button: (key.x, key.y), radius: key.radius, mouse: mouse, aspect: aspect)
                events.append(emit("tmove", finger, point.x, point.y))
            }
            return events
        default:
            return []
        }
    }

    private mutating func release(_ key: GameKey, now: Double) -> [ControlEvent] {
        guard let finger = fingers[key.id] else { return [] }
        switch key.kind {
        case .tap:
            switch key.mode {
            case .tap:
                guard let at = down[finger] else { return [] }
                return [emit("tup", finger, at.x, at.y)]
            case .autoFire:
                repeats[key.id] = nil
                guard let at = down[finger] else { return [] }
                return [emit("tup", finger, at.x, at.y)]
            case .toggle, .combo:
                // A toggle waits for the next press; a combo plays to its end.
                return []
            }
        case .skill:
            guard let aim = aims.removeValue(forKey: key.id), let at = down[finger] else { return [] }
            if key.quickCast && now - aim.start < Self.quickCastMs {
                return [emit("tmove", finger, key.x, key.y), emit("tup", finger, key.x, key.y)]
            }
            return [emit("tup", finger, at.x, at.y)]
        default:
            return []
        }
    }

    private mutating func start(_ id: UUID, finger: Int, timeline: [Scheduled], now: Double) -> [ControlEvent] {
        // A gesture still playing is not started again.
        guard runs[id] == nil, down[finger] == nil, !timeline.isEmpty else { return [] }
        runs[id] = Run(finger: finger, start: now, timeline: timeline)
        return advance(id, now: now)
    }

    private mutating func advance(_ id: UUID, now: Double) -> [ControlEvent] {
        guard var run = runs[id] else { return [] }
        var events: [ControlEvent] = []
        while run.next < run.timeline.count, run.start + run.timeline[run.next].at <= now {
            let step = run.timeline[run.next]
            events.append(emit(step.kind, run.finger, step.x, step.y))
            run.next += 1
        }
        runs[id] = run.next >= run.timeline.count ? nil : run
        return events
    }

    /// Plays whatever swipes, combos, and auto-fire are due by `now`.
    mutating func tick(now: Double) -> [ControlEvent] {
        var events: [ControlEvent] = []
        for key in keys where runs[key.id] != nil { events += advance(key.id, now: now) }
        for key in keys {
            guard var item = repeats[key.id], now >= item.nextAt else { continue }
            events.append(emit(item.isDown ? "tup" : "tdown", item.finger, item.x, item.y))
            item.isDown.toggle()
            item.nextAt += item.period / 2
            // After a stall the rhythm starts again instead of catching up in a burst.
            if now - item.nextAt > item.period { item.nextAt = now + item.period / 2 }
            repeats[key.id] = item
        }
        return events
    }

    // MARK: Joysticks

    /// Where a joystick's finger goes for the held directions, or nil when none is held. Diagonals reach as far as
    /// straight moves; `scale` is 0.5 while walking.
    static func stickPoint(center: (x: Double, y: Double), radius: Double, aspect: Double,
                           up: Bool, left: Bool, down: Bool, right: Bool, scale: Double = 1) -> (x: Double, y: Double)? {
        var dx = 0.0, dy = 0.0
        if left { dx -= 1 }
        if right { dx += 1 }
        if up { dy -= 1 }
        if down { dy += 1 }
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return nil }
        return (center.x + dx / length * radius * scale, center.y + dy / length * radius * scale * aspect)
    }

    private func walkScale(_ stick: GameKey) -> Double {
        let held = pressed.contains(Self.normalized(stick.walkKey))
        switch stick.walk {
        case .off: return 1
        case .fullWithKey: return held ? 1 : 0.5
        case .halfWithKey: return held ? 0.5 : 1
        }
    }

    private mutating func updateSticks() -> [ControlEvent] {
        var events: [ControlEvent] = []
        for key in keys where key.kind == .joystick && key.walk != .off { events += updateStick(key.id) }
        return events
    }

    private mutating func updateStick(_ id: UUID) -> [ControlEvent] {
        guard let stick = key(id), let finger = fingers[id] else { return [] }
        let codes = stick.directionKeys
        let held = codes.map { pressed.contains($0) && stickFor[$0] == id }
        let target = Self.stickPoint(center: (stick.x, stick.y), radius: stick.radius, aspect: aspect,
                                     up: held[0], left: held[1], down: held[2], right: held[3], scale: walkScale(stick))
        guard let target else {
            guard let current = down[finger] else { return [] }
            return [emit("tup", finger, current.x, current.y)]
        }
        var events: [ControlEvent] = []
        if down[finger] == nil { events.append(emit("tdown", finger, stick.x, stick.y)) }
        if let current = down[finger], abs(current.x - target.x) < 1e-9, abs(current.y - target.y) < 1e-9, events.isEmpty { return [] }
        events.append(emit("tmove", finger, target.x, target.y))
        return events
    }

    // MARK: Skills

    /// The skill finger for a mouse point: its direction and distance from the screen's middle, kept within the
    /// skill's reach.
    static func aimPoint(button: (x: Double, y: Double), radius: Double, mouse: (x: Double, y: Double), aspect: Double,
                         reach: Double = aimReach) -> (x: Double, y: Double) {
        // Measured in phone widths, so up and sideways count the same.
        let dx = mouse.x - 0.5, dy = (mouse.y - 0.5) / aspect
        var ox = dx / reach * radius, oy = dy / reach * radius
        let length = (ox * ox + oy * oy).squareRoot()
        if length > radius, length > 0 { ox *= radius / length; oy *= radius / length }
        return (button.x + ox, button.y + oy * aspect)
    }

    /// The mouse moved on the phone screen; held skills follow it.
    mutating func mouseMoved(to point: (x: Double, y: Double)) -> [ControlEvent] {
        mouse = point
        var events: [ControlEvent] = []
        for key in keys where aims[key.id] != nil {
            guard let finger = fingers[key.id] else { continue }
            let at = Self.aimPoint(button: (key.x, key.y), radius: key.radius, mouse: point, aspect: aspect)
            events.append(emit("tmove", finger, at.x, at.y))
        }
        return events
    }

    /// Esc while a skill is held: the finger goes back to the button's middle before lifting, which games take as
    /// a cancel. The key's release later does nothing.
    mutating func cancelAim() -> [ControlEvent] {
        var events: [ControlEvent] = []
        for key in keys where aims[key.id] != nil {
            aims[key.id] = nil
            guard let finger = fingers[key.id], down[finger] != nil else { continue }
            events.append(emit("tmove", finger, key.x, key.y))
            events.append(emit("tup", finger, key.x, key.y))
        }
        return events
    }

    // MARK: Gestures

    /// A finger from `a` to `b` over `durationMs`, moving about every 16 ms.
    static func swipeTimeline(from a: (x: Double, y: Double), to b: (x: Double, y: Double), durationMs: Double,
                              stepMs: Double = stepMs) -> [Scheduled] {
        let duration = max(durationMs, 1)
        let count = max(1, Int((duration / stepMs).rounded(.up)))
        var out = [Scheduled(at: 0, kind: "tdown", x: a.x, y: a.y)]
        for index in 1...count {
            let t = Double(index) / Double(count)
            out.append(Scheduled(at: duration * t, kind: "tmove", x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        out.append(Scheduled(at: duration, kind: "tup", x: b.x, y: b.y))
        return out
    }

    /// A combo's steps in order on one finger. With no steps it taps the key's own spot.
    static func comboTimeline(_ key: GameKey, tapMs: Double = tapMs) -> [Scheduled] {
        let steps = key.steps.isEmpty ? [GameKey.Step(kind: .tap, x: key.x, y: key.y)] : key.steps
        var out: [Scheduled] = []
        var t = 0.0
        for step in steps {
            switch step.kind {
            case .tap:
                out.append(Scheduled(at: t, kind: "tdown", x: step.x, y: step.y))
                out.append(Scheduled(at: t + tapMs, kind: "tup", x: step.x, y: step.y))
                t += tapMs
            case .wait:
                t += max(step.ms, 0)
            case .swipe:
                let start = t
                out += swipeTimeline(from: (step.x, step.y), to: (step.toX, step.toY), durationMs: step.ms).map {
                    Scheduled(at: start + $0.at, kind: $0.kind, x: $0.x, y: $0.y)
                }
                t += max(step.ms, 1)
            }
        }
        return out
    }

    // MARK: Looking with the mouse

    /// Puts the look finger down in the middle of the look area.
    mutating func lookBegin() -> [ControlEvent] {
        guard let area = lookArea, lookAt == nil else { return [] }
        lookAt = (area.x, area.y)
        return [emit("tdown", Self.mouseFinger, area.x, area.y)]
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
            events.append(emit("tup", Self.mouseFinger, current.x, current.y))
            events.append(emit("tdown", Self.mouseFinger, area.x, area.y))
            next = (area.x + dx, area.y + dy)
        }
        lookAt = next
        events.append(emit("tmove", Self.mouseFinger, next.x, next.y))
        return events
    }

    mutating func lookEnd() -> [ControlEvent] {
        guard let current = lookAt else { return [] }
        lookAt = nil
        return [emit("tup", Self.mouseFinger, current.x, current.y)]
    }

    /// The mouse button while looking presses the click spot.
    mutating func fire(_ isDown: Bool) -> [ControlEvent] {
        guard let spot = fireSpot, isDown != firing else { return [] }
        firing = isDown
        return [emit(isDown ? "tdown" : "tup", Self.fireFinger, spot.x, spot.y)]
    }

    /// Where every held finger is, sent again now and then so the phone knows the Mac is still there.
    func held() -> [ControlEvent] {
        down.keys.sorted().compactMap { finger in
            down[finger].map { ControlEvent(kind: "tmove", x: Float($0.x), y: Float($0.y), key: String(finger)) }
        }
    }

    /// Lifts every finger and stops every gesture, auto-fire, and aim.
    mutating func releaseAll() -> [ControlEvent] {
        let events = down.keys.sorted().compactMap { finger in
            down[finger].map { ControlEvent(kind: "tup", x: Float($0.x), y: Float($0.y), key: String(finger)) }
        }
        down = [:]
        pressed = []
        runs = [:]
        repeats = [:]
        aims = [:]
        firing = false
        lookAt = nil
        return events
    }
}

/// Game keys for the phone screen window: the layout per phone, editing, and play.
@MainActor
@Observable
final class GameKeysModel {
    /// What the next key press or click while editing goes to.
    enum Capture: Equatable {
        case key(UUID)
        case stickKeys(UUID, [UInt16], [String])
        case combo(UUID)
    }

    enum Direction: CaseIterable { case up, down, left, right }

    var enabled = false {
        didSet {
            if !enabled { editing = false; release() }
            onChange?()
        }
    }
    var editing = false {
        didSet {
            placing = nil
            pending = nil
            pendingSwipe = nil
            capture = nil
            message = nil
            if !editing { selected = nil }
            if editing { release() }
            if editing != oldValue { onEditingChange?(editing) }
            onChange?()
        }
    }
    /// The window grows for the editing panel and shrinks back.
    @ObservationIgnored var onEditingChange: ((Bool) -> Void)?
    /// A kind picked in the panel's palette: the next click on the picture places it.
    var placing: GameKey.Kind? { didSet { onChange?() } }
    /// What the waiting spot becomes once its key is pressed.
    private(set) var pendingKind: GameKey.Kind = .tap
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
    /// A drag while editing, waiting for a key to become a swipe.
    var pendingSwipe: (from: (x: Double, y: Double), to: (x: Double, y: Double))? { didSet { onChange?() } }
    /// The key the inspector shows.
    var selected: UUID? { didSet { onChange?() } }
    var capture: Capture? { didSet { onChange?() } }
    /// A short note for the bar, such as why a key couldn't be placed.
    var message: String? { didSet { onChange?() } }

    @ObservationIgnored var send: ((ControlEvent) -> Void)?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var aspect = 0.5
    @ObservationIgnored private var peerId = ""
    @ObservationIgnored private var engine = GameKeyEngine(keys: [], aspect: 0.5)
    @ObservationIgnored private var heartbeat: Timer?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var persists = true

    func load(peerId: String) {
        self.peerId = peerId
        persists = true
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

    #if DEBUG
    /// Shows keys without saving them, for snapshots.
    func preview(keys: [GameKey]) {
        persists = false
        profiles = [GameProfile(name: "Preview", keys: keys)]
        current = 0
        self.keys = keys
        rebuild()
    }
    #endif

    private func save() {
        if profiles.indices.contains(current) { profiles[current].keys = keys }
        if persists {
            if let data = try? JSONEncoder().encode(profiles) { UserDefaults.standard.set(data, forKey: "gameprofiles.\(peerId)") }
            UserDefaults.standard.set(current, forKey: "gameprofile.\(peerId)")
        }
        rebuild()
        onChange?()
    }

    // MARK: Profiles

    func selectProfile(_ index: Int) {
        guard profiles.indices.contains(index), index != current else { return }
        current = index
        keys = profiles[index].keys
        selected = nil
        save()
    }

    func addProfile(named name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        profiles.append(GameProfile(name: trimmed.isEmpty ? "Game \(profiles.count + 1)" : trimmed, keys: []))
        current = profiles.count - 1
        keys = []
        selected = nil
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
        selected = nil
        save()
    }

    // MARK: Looking

    var hasLook: Bool { keys.contains { $0.kind == .look } }

    /// Starts or stops aiming with the mouse. Only works with a look area placed.
    func toggleLook() {
        guard enabled, !editing else { return }
        if looking {
            dispatch(engine.lookEnd() + engine.fire(false))
            setLooking(false)
        } else if hasLook {
            dispatch(engine.lookBegin())
            setLooking(true)
        }
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
        dispatch(engine.look(dx: dx * lookSpeed, dy: dy * lookSpeed))
    }

    func fire(_ down: Bool) {
        guard looking else { return }
        dispatch(engine.fire(down))
    }

    func placeLook(x: Double, y: Double) {
        keys.removeAll { $0.kind == .look }
        let key = GameKey(kind: .look, label: "Look", x: x, y: y, radius: 0.12)
        keys.append(key)
        selected = key.id
        save()
    }

    func placeFire(x: Double, y: Double) {
        keys.removeAll { $0.kind == .fire }
        let key = GameKey(kind: .fire, label: "Click", x: x, y: y)
        keys.append(key)
        selected = key.id
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

    var tapCount: Int { keys.filter(\.isAction).count }
    var joystickCount: Int { keys.filter { $0.kind == .joystick }.count }
    var hasJoystick: Bool { joystickCount > 0 }
    var freeFingers: Int { max(0, GameKeyEngine.fingerPool - keys.filter(\.usesFinger).count) }
    var selectedKey: GameKey? { keys.first { $0.id == selected } }

    /// True when there is a finger for one more key; otherwise says why in the bar.
    private func roomForFinger() -> Bool {
        if freeFingers > 0 { return true }
        message = "No free finger: all \(GameKeyEngine.fingerPool) key fingers are used (8 is the click spot, 9 the mouse). Delete a key first."
        return false
    }

    /// True when another key or joystick also uses one of this key's keys.
    func conflicts(_ key: GameKey) -> Bool {
        let mine: Set<UInt16> = key.kind == .joystick ? Set(key.directionKeys) : key.isAction ? [GameKeyEngine.normalized(key.keyCode)] : []
        return keys.contains { other in
            guard other.id != key.id else { return false }
            let theirs: Set<UInt16> = other.kind == .joystick ? Set(other.directionKeys) : other.isAction ? [GameKeyEngine.normalized(other.keyCode)] : []
            return !mine.isDisjoint(with: theirs)
        }
    }

    // MARK: Editing

    static func label(for event: NSEvent) -> String {
        label(code: event.keyCode, characters: event.charactersIgnoringModifiers)
    }

    static func label(code: UInt16, characters: String?) -> String {
        switch code {
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
        default: return (characters ?? "?").uppercased()
        }
    }

    /// A click on the picture while a palette kind is picked.
    func place(_ kind: GameKey.Kind, x: Double, y: Double) {
        placing = nil
        switch kind {
        case .joystick: placeJoystick(x: x, y: y)
        case .look: placeLook(x: x, y: y)
        case .fire: placeFire(x: x, y: y)
        case .tap, .skill, .swipe:
            guard freeFingers > 0 || roomForFinger() else { return }
            pendingSwipe = nil
            pendingKind = kind
            pending = (x, y)
        }
    }

    /// A plain click on the picture: a spot waiting for a tap key.
    func pendTap(x: Double, y: Double) {
        pendingSwipe = nil
        pendingKind = .tap
        pending = (x, y)
    }

    /// Esc while editing: stops recording or picking, or drops the waiting spot, or closes the inspector.
    func cancelEditStep() {
        if placing != nil { placing = nil } else if capture != nil { capture = nil } else if pending != nil || pendingSwipe != nil { pending = nil; pendingSwipe = nil } else { selected = nil }
    }

    /// Gives the waiting spot, swipe, or picked key a keyboard key. Returns false when nothing is waiting.
    func assign(code: UInt16, label: String) -> Bool {
        if let capture {
            switch capture {
            case .key(let id):
                self.capture = nil
                update(id) { $0.keyCode = GameKeyEngine.normalized(code); $0.label = label }
            case .stickKeys(let id, var codes, var labels):
                guard !codes.contains(code) else { return true }
                codes.append(code)
                labels.append(label)
                if codes.count == 4 {
                    self.capture = nil
                    update(id) {
                        $0.keySet = .custom
                        $0.customKeys = codes
                        $0.customLabels = labels
                        $0.label = labels.joined()
                    }
                } else {
                    self.capture = .stickKeys(id, codes, labels)
                }
            case .combo:
                break
            }
            return true
        }
        if let swipe = pendingSwipe {
            pendingSwipe = nil
            let replacing = keys.contains { $0.isAction && $0.keyCode == code }
            guard replacing || roomForFinger() else { return true }
            keys.removeAll { $0.isAction && $0.keyCode == code }
            let key = GameKey(kind: .swipe, keyCode: code, label: label, x: swipe.from.x, y: swipe.from.y,
                              toX: swipe.to.x, toY: swipe.to.y)
            keys.append(key)
            selected = key.id
            message = nil
            save()
            return true
        }
        guard let spot = pending else { return false }
        pending = nil
        let replacing = keys.contains { $0.isAction && $0.keyCode == code }
        guard replacing || roomForFinger() else { return true }
        // A key does one thing, so an older spot for it moves here.
        keys.removeAll { $0.isAction && $0.keyCode == code }
        var key = GameKey(kind: pendingKind, keyCode: code, label: label, x: spot.x, y: spot.y)
        if key.kind == .skill { key.radius = 0.07 }
        if key.kind == .swipe {
            let end = Self.presetEnd(.up, from: spot, aspect: aspect)
            key.toX = end.x
            key.toY = end.y
        }
        pendingKind = .tap
        keys.append(key)
        selected = key.id
        message = nil
        save()
        return true
    }

    /// Adds a joystick, with the first key set no other joystick uses.
    func placeJoystick(x: Double, y: Double) {
        guard roomForFinger() else { return }
        let used = Set(keys.filter { $0.kind == .joystick }.map(\.keySet))
        let set = [GameKey.KeySet.wasd, .arrows, .ijkl].first { !used.contains($0) } ?? .wasd
        var key = GameKey(kind: .joystick, label: "", x: x, y: y, keySet: set)
        key.label = key.directionLabels.joined()
        keys.append(key)
        selected = key.id
        message = nil
        save()
    }

    func update(_ id: UUID, _ change: (inout GameKey) -> Void) {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        var key = keys[index]
        change(&key)
        guard key != keys[index] else { return }
        keys[index] = key
        save()
    }

    /// Turns a tap key into a skill or swipe and back. Joysticks and look areas stay what they are.
    func setKind(_ id: UUID, _ kind: GameKey.Kind) {
        update(id) { key in
            guard key.isAction, [.tap, .skill, .swipe].contains(kind), key.kind != kind else { return }
            key.kind = kind
            if kind == .skill { key.radius = 0.07 }
            if kind == .swipe, abs(key.toX - key.x) + abs(key.toY - key.y) < 0.01 {
                let end = Self.presetEnd(.up, from: (key.x, key.y), aspect: aspect)
                key.toX = end.x
                key.toY = end.y
            }
        }
    }

    /// Where a swipe preset ends: a sixth of the phone's width from the spot.
    static func presetEnd(_ direction: Direction, from point: (x: Double, y: Double), aspect: Double) -> (x: Double, y: Double) {
        let length = 0.16
        let end: (x: Double, y: Double) = switch direction {
        case .up: (point.x, point.y - length * aspect)
        case .down: (point.x, point.y + length * aspect)
        case .left: (point.x - length, point.y)
        case .right: (point.x + length, point.y)
        }
        return (min(max(end.x, 0), 1), min(max(end.y, 0), 1))
    }

    func swipePreset(_ id: UUID, _ direction: Direction) {
        update(id) { key in
            let end = Self.presetEnd(direction, from: (key.x, key.y), aspect: aspect)
            key.toX = end.x
            key.toY = end.y
        }
    }

    /// Starts recording a combo: each click on the picture adds a tap, each drag a swipe.
    func recordCombo(_ id: UUID) {
        update(id) { $0.mode = .combo; $0.steps = [] }
        capture = .combo(id)
        selected = id
    }

    /// Adds a step to the combo being recorded, with an 80 ms wait before it.
    func recordStep(_ step: GameKey.Step) {
        guard case .combo(let id) = capture else { return }
        update(id) { key in
            if let last = key.steps.last, last.kind != .wait { key.steps.append(GameKey.Step(kind: .wait, ms: 80)) }
            key.steps.append(step)
        }
    }

    func move(_ id: UUID, x: Double, y: Double, end: Bool = false) {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        if end {
            keys[index].toX = min(max(x, 0), 1)
            keys[index].toY = min(max(y, 0), 1)
        } else {
            let dx = min(max(x, 0), 1) - keys[index].x, dy = min(max(y, 0), 1) - keys[index].y
            keys[index].x += dx
            keys[index].y += dy
        }
        onChange?()
    }

    func finishMove() { save() }

    func resize(_ id: UUID, by delta: Double) {
        guard let index = keys.firstIndex(where: { $0.id == id }), [.joystick, .look, .skill].contains(keys[index].kind) else { return }
        keys[index].radius = min(max(keys[index].radius + delta, 0.03), 0.25)
        save()
    }

    func remove(_ id: UUID) {
        keys.removeAll { $0.id == id }
        if selected == id { selected = nil }
        if case .combo(let recording)? = capture, recording == id { capture = nil }
        save()
    }

    func clear() {
        keys = []
        selected = nil
        capture = nil
        save()
    }

    // MARK: Playing

    private var now: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    private func dispatch(_ events: [ControlEvent]) {
        events.forEach { send?($0) }
        updateTimers()
    }

    /// Returns true when the key belongs to the game layout.
    func key(_ code: UInt16, down: Bool) -> Bool {
        guard enabled, !editing, engine.handles(code) else { return false }
        dispatch(down ? engine.keyDown(code, now: now) : engine.keyUp(code, now: now))
        return true
    }

    /// The mouse over the phone picture while playing, for aiming skills.
    func mouse(at point: (x: Double, y: Double)) {
        guard enabled, !editing, !looking else { return }
        dispatch(engine.mouseMoved(to: point))
    }

    /// Esc while a skill is held cancels it. Returns true when one was held.
    func cancelSkill() -> Bool {
        guard enabled, !editing, engine.isAiming else { return false }
        dispatch(engine.cancelAim())
        return true
    }

    func release() {
        dispatch(engine.releaseAll())
        setLooking(false)
    }

    /// Gestures play on a fast timer; held fingers are sent again every 1.5 s so the phone doesn't lift them.
    private func updateTimers() {
        if engine.needsTick, ticker == nil {
            let timer = Timer(timeInterval: 1.0 / 125, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.dispatch(self.engine.tick(now: self.now))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !engine.needsTick, let ticker {
            ticker.invalidate()
            self.ticker = nil
        }
        let held = !engine.down.isEmpty
        if held, heartbeat == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.held().forEach { self?.send?($0) } }
            }
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
        } else if !held, let heartbeat {
            heartbeat.invalidate()
            self.heartbeat = nil
        }
    }
}
