import AVFoundation
import AppKit
import SwiftUI

/// Translates key presses on the Mac into commands for the phone.
enum PhoneKeys {
    static func controlEvent(for event: NSEvent) -> ControlEvent? {
        switch event.keyCode {
        case 51: return ControlEvent(kind: "key", key: "backspace")
        case 36, 76: return ControlEvent(kind: "key", key: "enter")
        case 123: return ControlEvent(kind: "key", key: "left")
        case 124: return ControlEvent(kind: "key", key: "right")
        case 53: return ControlEvent(kind: "key", key: "back")
        default: break
        }
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let text = event.characters, !text.isEmpty,
              // This range holds function keys, not letters.
              !text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        return ControlEvent(kind: "text", text: text)
    }

    static func paste() -> ControlEvent? {
        NSPasteboard.general.string(forType: .string).map { ControlEvent(kind: "text", text: $0) }
    }
}

/// Lets a stream of mouse moves through at most once per `interval`. Look moves are added up meanwhile, so nothing
/// of the turn is lost; aim only needs the latest point.
struct MoveThrottle {
    var interval: TimeInterval
    private var lastAt: TimeInterval = -.infinity
    private var dx = 0.0, dy = 0.0

    init(interval: TimeInterval) { self.interval = interval }

    /// True when a move at `time` may be sent, and then counts it as sent.
    mutating func isDue(_ time: TimeInterval) -> Bool {
        guard time - lastAt >= interval || time < lastAt else { return false }
        lastAt = time
        return true
    }

    /// Adds a relative move; the total since the last one sent, when it's due.
    mutating func add(dx: Double, dy: Double, at time: TimeInterval) -> (dx: Double, dy: Double)? {
        self.dx += dx
        self.dy += dy
        guard isDue(time) else { return nil }
        defer { self.dx = 0; self.dy = 0 }
        return (self.dx, self.dy)
    }
}

/// Shows the phone video and forwards mouse and keyboard as touch.
final class ScreenSurface: NSView {
    private static let sendInterval: TimeInterval = 1.0 / 90
    private static let scrollIdle: TimeInterval = 0.12
    private static let scrollMargin: Float = 0.2

    var onControl: ((ControlEvent) -> Void)?
    var videoSize = CGSize(width: 9, height: 16) { didSet { needsLayout = true } }
    /// Turns the picture clockwise in steps of 90 degrees. The phone itself doesn't change.
    var quarterTurns = 0 { didSet { needsLayout = true } }
    /// Flips the shown picture left to right, like a mirror. Used for front cameras.
    var mirrored = false { didSet { needsLayout = true } }
    var onDoubleClick: (() -> Void)?
    /// ⌘B shows or hides the window's button bar, for a clean picture in OBS.
    var onToggleBar: (() -> Void)?
    /// Game keys: when on, mapped keys become fingers and the mouse is one more finger.
    var game: GameKeysModel? {
        didSet {
            overlay.game = game
            game?.onChange = { [weak self] in self?.overlay.needsDisplay = true }
            game?.onLookChange = { [weak self] on in self?.holdPointer(on) }
        }
    }

    /// The share of the phone's width one point of mouse movement turns, before the speed setting.
    static let lookScale = 1.0 / 1400
    /// ` starts and stops aiming with the mouse.
    static let lookKey: UInt16 = 50
    private var holdsPointer = false

    /// While aiming, the pointer stays still and hidden, and only its movement is read.
    private func holdPointer(_ on: Bool) {
        guard on != holdsPointer else { return }
        holdsPointer = on
        if on {
            if let window {
                let middle = window.convertPoint(toScreen: convert(CGPoint(x: pictureRect.midX, y: pictureRect.midY), to: nil))
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                CGWarpMouseCursorPosition(CGPoint(x: middle.x, y: top - middle.y))
            }
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            window?.acceptsMouseMovedEvents = true
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    /// Aim and look send a move at most about 90 times a second, as drags do.
    private var aimThrottle = MoveThrottle(interval: sendInterval)
    private var lookThrottle = MoveThrottle(interval: sendInterval)

    /// A mouse movement turned into a move on the phone, following the picture's rotation.
    private func lookMove(_ event: NSEvent) {
        guard let game, game.looking else { return }
        let dx = Float(event.deltaX * Self.lookScale), dy = Float(event.deltaY * Self.lookScale)
        let origin = Self.phonePoint((0.5, 0.5), quarterTurns: quarterTurns)
        let moved = Self.phonePoint((0.5 + dx, 0.5 + dy), quarterTurns: quarterTurns)
        guard let total = lookThrottle.add(dx: Double(moved.x - origin.x), dy: Double(moved.y - origin.y) * game.aspect,
                                           at: event.timestamp) else { return }
        game.look(dx: total.dx, dy: total.dy)
    }

    override func mouseMoved(with event: NSEvent) {
        lookMove(event)
        aimMove(event)
    }

    /// The mouse over the picture aims held skill keys.
    private func aimMove(_ event: NSEvent) {
        guard let game, game.enabled, !game.editing, !game.looking, aimThrottle.isDue(event.timestamp) else { return }
        let phone = phonePoint(atView: convert(event.locationInWindow, from: nil))
        game.mouse(at: (Double(phone.x), Double(phone.y)))
    }
    var showsGameKeys = true { didSet { overlay.needsDisplay = true } }
    let overlay = GameKeysOverlay()

    private let video = CALayer()

    private var isPressed = false
    private var dragThrottle = MoveThrottle(interval: sendInterval)
    private var scrollStart: (x: Float, y: Float)?
    private var scrollFinger: (x: Float, y: Float)?
    private var scrollEnd: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        video.contentsGravity = .resizeAspect
        layer?.addSublayer(video)
        overlay.surface = self
        addSubview(overlay)
    }

    /// Where the picture sits in this view.
    var pictureRect: CGRect { AVMakeRect(aspectRatio: displaySize, insideRect: bounds) }

    /// A point in this view, as 0…1 on the phone screen.
    func phonePoint(atView point: CGPoint) -> (x: Float, y: Float) {
        let rect = pictureRect
        let x = (point.x - rect.minX) / max(rect.width, 1)
        let y = 1 - (point.y - rect.minY) / max(rect.height, 1)
        return Self.phonePoint((Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1))), quarterTurns: quarterTurns)
    }

    /// A point on the phone screen, in this view.
    func viewPoint(fromPhone point: (x: Double, y: Double)) -> CGPoint {
        // Turning back is the same mapping with the opposite turn.
        let picture = Self.phonePoint((Float(point.x), Float(point.y)), quarterTurns: 4 - (quarterTurns % 4 + 4) % 4)
        let rect = pictureRect
        return CGPoint(x: rect.minX + CGFloat(picture.x) * rect.width, y: rect.maxY - CGFloat(picture.y) * rect.height)
    }

    /// How long the phone's width is in this view.
    var phoneWidthInView: CGFloat { quarterTurns % 2 == 0 ? pictureRect.width : pictureRect.height }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The size of the picture as it appears, after turning.
    var displaySize: CGSize {
        quarterTurns % 2 == 0 ? videoSize : CGSize(width: videoSize.height, height: videoSize.width)
    }

    func display(_ buffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        show(surface)
    }

    func show(_ contents: Any) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.contents = contents
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let rect = AVMakeRect(aspectRatio: displaySize, insideRect: bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.bounds = CGRect(origin: .zero, size: quarterTurns % 2 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width))
        video.position = CGPoint(x: rect.midX, y: rect.midY)
        // The layer's y axis points up, so a negative angle turns clockwise.
        var transform = CGAffineTransform(rotationAngle: -CGFloat(quarterTurns) * .pi / 2)
        if mirrored { transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        video.setAffineTransform(transform)
        CATransaction.commit()
        overlay.frame = bounds
        overlay.needsDisplay = true
    }

    /// Maps a point on the turned picture, from the top left, back to the phone screen.
    static func phonePoint(_ point: (x: Float, y: Float), quarterTurns: Int) -> (x: Float, y: Float) {
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: return (point.y, 1 - point.x)
        case 2: return (1 - point.x, 1 - point.y)
        case 3: return (1 - point.y, point.x)
        default: return point
        }
    }

    private func normalized(_ event: NSEvent) -> (x: Float, y: Float) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: displaySize, insideRect: bounds)
        let x = (point.x - rect.minX) / max(rect.width, 1)
        let y = 1 - (point.y - rect.minY) / max(rect.height, 1)
        return (Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }

    private var playing: Bool { game?.enabled == true && game?.editing != true }

    private func touch(_ kind: String, _ point: (x: Float, y: Float)) {
        let phone = Self.phonePoint(point, quarterTurns: quarterTurns)
        if playing, let game {
            // In game mode the mouse is its own finger, so it works while keys are held. The engine keeps it, so
            // the heartbeat holds it down and aiming takes the finger over cleanly.
            let multi = ["down": "tdown", "drag": "tmove", "up": "tup"][kind] ?? kind
            game.mouseTouch(multi, at: (Double(phone.x), Double(phone.y)))
        } else {
            onControl?(ControlEvent(kind: kind, x: phone.x, y: phone.y))
        }
    }

    /// Movement is sent while it happens, at most about 90 times a second.
    private func isDue(_ event: NSEvent) -> Bool { dragThrottle.isDue(event.timestamp) }

    override func mouseDown(with event: NSEvent) {
        if let game, game.looking { return game.fire(true) }
        if event.clickCount == 2, let onDoubleClick { return onDoubleClick() }
        guard onControl != nil else { return }
        finishScroll()
        window?.makeFirstResponder(self)
        isPressed = true
        touch("down", normalized(event))
    }

    override func mouseDragged(with event: NSEvent) {
        if game?.looking == true { return lookMove(event) }
        aimMove(event)
        if isPressed && isDue(event) { touch("drag", normalized(event)) }
    }

    override func mouseUp(with event: NSEvent) {
        if let game, game.looking { return game.fire(false) }
        guard isPressed else { return }
        isPressed = false
        touch("up", normalized(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        if game?.looking == true { return }
        onControl?(ControlEvent(kind: "key", key: "back"))
    }

    override func rightMouseDragged(with event: NSEvent) { lookMove(event) }

    /// The wheel and trackpad act as a finger dragging on the phone, so scrolling follows them directly.
    override func scrollWheel(with event: NSEvent) {
        let rect = AVMakeRect(aspectRatio: displaySize, insideRect: bounds)
        guard !isPressed, rect.width > 0, rect.height > 0 else { return }
        if scrollFinger == nil {
            let at = normalized(event)
            let start = (x: min(max(at.x, Self.scrollMargin), 1 - Self.scrollMargin),
                         y: min(max(at.y, Self.scrollMargin), 1 - Self.scrollMargin))
            scrollStart = start
            scrollFinger = start
            touch("down", start)
        }
        guard let finger = scrollFinger, let start = scrollStart else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let moved = (x: finger.x + Float(event.scrollingDeltaX * scale / rect.width),
                     y: finger.y + Float(event.scrollingDeltaY * scale / rect.height))
        if (0.02...0.98).contains(moved.x) && (0.02...0.98).contains(moved.y) {
            scrollFinger = moved
            if isDue(event) { touch("drag", moved) }
        } else {
            // The finger reached the edge of the screen, so it lifts and starts over.
            touch("up", finger)
            scrollFinger = start
            touch("down", start)
        }
        scrollEnd?.cancel()
        let end = DispatchWorkItem { [weak self] in self?.finishScroll() }
        scrollEnd = end
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollIdle, execute: end)
    }

    private func finishScroll() {
        scrollEnd?.cancel()
        scrollEnd = nil
        if let finger = scrollFinger { touch("up", finger) }
        scrollFinger = nil
        scrollStart = nil
    }

    override func keyDown(with event: NSEvent) {
        if let game, game.enabled {
            if game.editing {
                if event.keyCode == 53 { return game.cancelEditStep() }
                if event.isARepeat { return }
                _ = game.assign(code: event.keyCode, label: GameKeysModel.label(for: event))
                return
            }
            if game.looking, event.keyCode == 53 { return game.toggleLook() }
            // Esc while a skill is held cancels it instead of going back on the phone.
            if event.keyCode == 53, game.cancelSkill() { return }
            // Held keys repeat; the engine ignores repeats but they still belong to the game.
            if game.key(event.keyCode, down: true) { return }
            if event.keyCode == Self.lookKey, game.hasLook {
                if !event.isARepeat { game.toggleLook() }
                return
            }
        }
        if let control = PhoneKeys.controlEvent(for: event) { onControl?(control) }
    }

    override func keyUp(with event: NSEvent) {
        if let game, game.enabled { _ = game.key(event.keyCode, down: false) }
    }

    private var keyUpMonitor: Any?

    /// AppKit doesn't send a key up to the view while ⌘ is down, so a game key let go then would keep its finger.
    /// A local monitor sees those key ups first. Started with the window and stopped when it closes.
    func startKeyMonitor() {
        guard keyUpMonitor == nil else { return }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if let self, event.window === self.window, event.modifierFlags.contains(.command),
               let game = self.game, game.enabled { _ = game.key(event.keyCode, down: false) }
            return event
        }
    }

    func stopKeyMonitor() {
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        keyUpMonitor = nil
    }

    /// Whether the keyboard holds this key now.
    static func keyIsHeld(_ code: UInt16) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
    }

    /// Shift, Control, and Option only arrive as flag changes.
    override func flagsChanged(with event: NSEvent) {
        guard let game, game.enabled else { return super.flagsChanged(with: event) }
        // ⌘ let go: keys released while it was down get their release now.
        if [54, 55].contains(event.keyCode), !event.modifierFlags.contains(.command) {
            return game.releaseLifted(isHeld: Self.keyIsHeld)
        }
        let flag: NSEvent.ModifierFlags? = switch event.keyCode {
        case 56, 60: .shift
        case 59, 62: .control
        case 58, 61: .option
        default: nil
        }
        guard let flag else { return }
        let down = event.modifierFlags.contains(flag)
        if game.editing {
            if down { _ = game.assign(code: event.keyCode, label: GameKeysModel.label(for: event)) }
            return
        }
        _ = game.key(event.keyCode, down: down)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "b", let onToggleBar {
            onToggleBar()
            return true
        }
        guard event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v",
              window?.firstResponder === self, let control = PhoneKeys.paste()
        else { return super.performKeyEquivalent(with: event) }
        onControl?(control)
        return true
    }
}

private struct SurfaceHost: NSViewRepresentable {
    let surface: ScreenSurface
    func makeNSView(context: Context) -> ScreenSurface { surface }
    func updateNSView(_ view: ScreenSurface, context: Context) {}
}

/// Window settings the bar changes.
@MainActor
@Observable
final class ScreenWindowState {
    var showsBar = true
    var floats = UserDefaults.standard.bool(forKey: "screen.floats")
}

private struct ScreenWindowContent: View {
    let model: AppModel
    let peerId: String
    let surface: ScreenSurface
    let state: ScreenWindowState
    let game: GameKeysModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SurfaceHost(surface: surface)
                if state.showsBar {
                    if game.enabled { gameBar }
                    bar
                }
            }
            .environment(\.colorScheme, .dark)
            // The window grows by the panel's width while editing, so the picture keeps its size.
            // The panel follows the Appearance setting; only the picture and its bars stay dark.
            if game.enabled && game.editing {
                Group {
                    Divider().overlay(Theme.stroke)
                    GameKeysPanel(game: game)
                }
                .environment(\.colorScheme, AppearanceStore.shared.resolvedScheme)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var gameBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill").foregroundStyle(Theme.mint)
            Text(gameHelp)
                .font(.system(size: 11)).foregroundStyle(game.message != nil ? Theme.coralText : Theme.textSecondary).lineLimit(3)
            Spacer(minLength: 4)
            if !game.editing {
                GameProfileMenu(game: game)
                Button("Edit keys") { game.editing = true; ScreenWindow.focusSurface() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mintText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .background(Theme.panelRaised)
    }

    private var gameHelp: String {
        if let message = game.message { return message }
        if game.editing {
            switch game.capture {
            case .key: return "Press the new key for this button. Esc cancels."
            case .stickKeys(_, let codes, _): return "Press the joystick's \(["up", "left", "down", "right"][min(codes.count, 3)]) key. Esc cancels."
            case .combo: return "Recording a combo: click spots in order, drag for a swipe. Esc or Stop recording ends."
            case nil: break
            }
            if game.pendingSwipe != nil { return "Press the key for this swipe. Esc cancels." }
            if game.pending != nil { return "Press the key for this spot. Esc cancels." }
            if let placing = game.placing {
                return "Click the picture to place the \(GameKeysPanel.palette.first { $0.0 == placing }?.1.lowercased() ?? "control"). Esc cancels."
            }
            return "Pick a control in the panel, or: click + key = tap key, drag + key = swipe, ⌥-click joystick, ⇧-click look area, "
                + "⌘-click click spot. Click a control to edit it; drag moves, right-click deletes, scroll resizes."
        }
        if game.looking { return "Aiming with the mouse. Click presses the click spot. ` or Esc stops." }
        if game.keys.isEmpty { return "No keys yet. Click Edit keys to place them on the picture." }
        let sticks = game.joystickCount
        return "Game keys on: \(game.tapCount) key\(game.tapCount == 1 ? "" : "s")"
            + (sticks > 0 ? " + \(sticks) joystick\(sticks == 1 ? "" : "s")" : "")
            + (game.keys.contains { $0.kind == .skill } ? ". Hold a skill key and point with the mouse; Esc cancels" : "")
            + (game.hasLook ? ". Press ` to aim with the mouse" : ". The mouse taps too") + "."
    }

    private var bar: some View {
            HStack(spacing: 6) {
                if model.phone(peerId).features.contains("control") {
                    keyButton("chevron.backward", "Back", key: "back")
                    keyButton("circle", "Home", key: "home")
                    keyButton("square.on.square", "Recent apps", key: "recents")
                } else {
                    Text("View only. Turn on Control from Mac on the phone to control it.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { game.enabled.toggle(); ScreenWindow.focusSurface() } label: {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(game.enabled ? Theme.onAccent : Theme.textPrimary)
                        .frame(width: 34, height: 28).background(game.enabled ? Theme.mint : Theme.panelRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Game keys: keyboard keys tap places on the phone screen")
                if model.phoneAudioFrom == peerId {
                    Button { model.phoneAudioMuted.toggle() } label: {
                        Image(systemName: model.phoneAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(model.phoneAudioMuted ? Theme.coral : Theme.textPrimary)
                            .frame(width: 34, height: 28).background(Theme.panelRaised, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(model.phoneAudioMuted ? "Unmute the phone's sound" : "Mute the phone's sound on this Mac")
                }
                Button { ScreenWindow.rotate(by: -1) } label: {
                    Image(systemName: "rotate.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 34, height: 28).background(Theme.panelRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Rotate left. The phone doesn't rotate.")
                Button { ScreenWindow.rotate(by: 1) } label: {
                    Image(systemName: "rotate.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 34, height: 28).background(Theme.panelRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Rotate right. The phone doesn't rotate.")
                Button { ScreenWindow.toggleFloat() } label: {
                    Image(systemName: state.floats ? "pin.fill" : "pin").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.floats ? Theme.onAccent : Theme.textPrimary)
                        .frame(width: 34, height: 28).background(state.floats ? Theme.mint : Theme.panelRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Keep on top")
                Button { ScreenWindow.setBar(false) } label: {
                    Image(systemName: "rectangle.dashed").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 34, height: 28).background(Theme.panelRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Clean view for OBS: hides this bar. Press ⌘B in the window to bring it back.")
                Button("Stop") { model.stopScreen() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.coralText)
            }
            .padding(.horizontal, 12)
            .frame(height: ScreenWindow.barHeight)
            .background(Theme.panel)
    }

    private func keyButton(_ icon: String, _ label: String, key: String) -> some View {
        Button { model.sendControl(ControlEvent(kind: "key", key: key), to: peerId) } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .frame(width: 34, height: 28).background(Theme.panelRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

/// Asks for a game's name.
@MainActor
enum GameProfileNames {
    static func ask(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The keys you place are kept under this name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        field.placeholderString = "Game name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        defer { ScreenWindow.focusSurface() }
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

/// A separate window for the phone screen, so it can sit beside other work.
@MainActor
enum ScreenWindow {
    static let barHeight: CGFloat = 44

    private static var window: NSWindow?
    private static var surface: ScreenSurface?
    private static var closingFromModel = false
    private static let observer = Observer()
    private static let state = ScreenWindowState()
    private static let game = GameKeysModel()
    /// True while the window holds the game keys panel's extra width.
    private static var panelShown = false

    static var isVisible: Bool { window?.isVisible == true }
    static var showsBar: Bool { state.showsBar }

    private static let turnsKey = "screen.quarterTurns"

    /// The window follows the picture's aspect ratio, portrait or landscape.
    static func contentSize(for picture: CGSize, bar: Bool = true) -> CGSize {
        let extra = bar ? barHeight : 0
        return picture.height >= picture.width
            ? CGSize(width: 720 * picture.width / picture.height, height: 720 + extra)
            : CGSize(width: 960, height: 960 * picture.height / picture.width + extra)
    }

    /// Hiding the bar keeps the picture's width, so OBS gets only the phone screen.
    static func focusSurface() {
        if let surface { window?.makeFirstResponder(surface) }
    }

    /// The window's content size for the picture, with the bars and, while editing game keys, the panel.
    private static func windowSize(for picture: CGSize) -> CGSize {
        var size = contentSize(for: picture, bar: state.showsBar)
        if game.enabled && game.editing { size.width += GameKeysPanel.width + 1 }
        return size
    }

    /// Editing game keys adds the panel beside the picture; the left edge stays put.
    private static func editingChanged(_ editing: Bool) {
        guard let window, let surface, editing != panelShown else { return }
        panelShown = editing
        var frame = window.frame
        frame.size.width += (editing ? 1 : -1) * (GameKeysPanel.width + 1)
        window.setFrame(frame, display: true, animate: false)
        window.makeFirstResponder(surface)
    }

    static func setBar(_ shown: Bool) {
        guard let window, let surface, state.showsBar != shown else { return }
        state.showsBar = shown
        // The clean view for OBS hides the key markers too.
        surface.showsGameKeys = shown
        var size = window.contentRect(forFrameRect: window.frame).size
        size.height += shown ? barHeight : -barHeight
        window.setContentSize(size)
        window.makeFirstResponder(surface)
    }

    static func toggleFloat() {
        state.floats.toggle()
        UserDefaults.standard.set(state.floats, forKey: "screen.floats")
        window?.level = state.floats ? .floating : .normal
    }

    /// The turn is remembered for the next session.
    /// [steps] is +1 for a quarter turn right, -1 for left.
    static func rotate(by steps: Int = 1) {
        guard let window, let surface else { return }
        surface.quarterTurns = ((surface.quarterTurns + steps) % 4 + 4) % 4
        UserDefaults.standard.set(surface.quarterTurns, forKey: turnsKey)
        window.setContentSize(windowSize(for: surface.displaySize))
    }

    static func show(model: AppModel, peerId: String, name: String, info: ScreenInfo) {
        let videoSize = CGSize(width: info.width, height: info.height)
        game.setAspect(Double(info.width) / Double(max(info.height, 1)))
        if let window, let surface {
            surface.videoSize = videoSize
            window.setContentSize(windowSize(for: surface.displaySize))
            return
        }
        state.showsBar = true
        let view = ScreenSurface(frame: .zero)
        view.videoSize = videoSize
        view.quarterTurns = UserDefaults.standard.integer(forKey: turnsKey) % 4
        let content = contentSize(for: view.displaySize)
        view.onControl = { [weak model] event in model?.sendControl(event, to: peerId) }
        view.onToggleBar = { setBar(!state.showsBar) }
        game.load(peerId: peerId)
        game.enabled = false
        game.onEditingChange = { _ in DispatchQueue.main.async { editingChanged(game.editing) } }
        game.send = { [weak model] event in model?.sendControl(event, to: peerId) }
        view.game = game
        view.showsGameKeys = true
        let created = NSWindow(
            contentRect: NSRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        created.title = "\(name) screen"
        created.isReleasedWhenClosed = false
        // Video windows stay dark in every appearance, so the picture has a dark frame.
        created.appearance = NSAppearance(named: .darkAqua)
        created.contentView = NSHostingView(rootView: ScreenWindowContent(model: model, peerId: peerId, surface: view, state: state, game: game))
        created.level = state.floats ? .floating : .normal
        // Skill keys follow the mouse without a button held.
        created.acceptsMouseMovedEvents = true
        created.delegate = observer
        observer.onUserClose = { [weak model] in model?.stopScreen() }
        created.center()
        window = created
        surface = view
        NSApp.setActivationPolicy(.regular)
        created.makeKeyAndOrderFront(nil)
        created.makeFirstResponder(view)
        view.startKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
    }

    static func display(_ buffer: CVPixelBuffer) {
        surface?.display(buffer)
    }

    static func close() {
        surface?.stopKeyMonitor()
        game.enabled = false
        closingFromModel = true
        window?.close()
        closingFromModel = false
        window = nil
        surface = nil
        panelShown = false
    }

    private final class Observer: NSObject, NSWindowDelegate {
        var onUserClose: (() -> Void)?

        /// Keys held when the window loses focus never get their release, so fingers are lifted now.
        func windowDidResignKey(_ notification: Notification) {
            MainActor.assumeIsolated { game.release() }
        }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                surface?.stopKeyMonitor()
                game.release()
                if !closingFromModel { onUserClose?() }
                if !MainWindow.isVisible && !CameraWindow.isVisible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

/// Draws game keys on the phone picture, and lets them be placed while editing.
final class GameKeysOverlay: NSView {
    weak var surface: ScreenSurface?
    weak var game: GameKeysModel?
    /// The key being dragged, and whether it's a swipe's end.
    private var dragging: (id: UUID, end: Bool)?
    /// Where a press on empty picture started, to tell a click from a drag.
    private var pressedAt: CGPoint?
    private var draggedTo: CGPoint?
    private static let dragDistance: CGFloat = 12

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard game?.editing == true else { return nil }
        return super.hitTest(point)
    }

    private static func hasReach(_ key: GameKey) -> Bool { [.joystick, .look].contains(key.kind) }

    private func hit(_ point: CGPoint) -> (key: GameKey, end: Bool)? {
        guard let surface, let game else { return nil }
        for key in game.keys.reversed() {
            if key.kind == .swipe {
                let end = surface.viewPoint(fromPhone: (key.toX, key.toY))
                if hypot(end.x - point.x, end.y - point.y) <= 14 { return (key, true) }
            }
            let center = surface.viewPoint(fromPhone: (key.x, key.y))
            let reach = Self.hasReach(key) ? max(20, key.radius * surface.phoneWidthInView) : 18
            if hypot(center.x - point.x, center.y - point.y) <= reach { return (key, false) }
        }
        return nil
    }

    private func phone(_ point: CGPoint) -> (x: Double, y: Double) {
        guard let surface else { return (0, 0) }
        let p = surface.phonePoint(atView: point)
        return (Double(p.x), Double(p.y))
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface, let game else { return }
        window?.makeFirstResponder(surface)
        let point = convert(event.locationInWindow, from: nil)
        guard surface.pictureRect.contains(point) else { return }
        // Recording a combo: every click is a step, even on a key.
        if case .combo? = game.capture {
            pressedAt = point
            draggedTo = nil
            return
        }
        let at = phone(point)
        if let placing = game.placing { return game.place(placing, x: at.x, y: at.y) }
        if let found = hit(point) {
            game.selected = found.key.id
            dragging = (found.key.id, found.end)
            return
        }
        if event.modifierFlags.contains(.option) {
            game.placeJoystick(x: at.x, y: at.y)
        } else if event.modifierFlags.contains(.shift) {
            game.placeLook(x: at.x, y: at.y)
        } else if event.modifierFlags.contains(.command) {
            game.placeFire(x: at.x, y: at.y)
        } else {
            game.selected = nil
            pressedAt = point
            draggedTo = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let game else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let dragging {
            let at = phone(point)
            return game.move(dragging.id, x: at.x, y: at.y, end: dragging.end)
        }
        guard let start = pressedAt else { return }
        if draggedTo != nil || hypot(point.x - start.x, point.y - start.y) > Self.dragDistance {
            draggedTo = point
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragging = nil; pressedAt = nil; draggedTo = nil; needsDisplay = true }
        guard let game else { return }
        if dragging != nil { return game.finishMove() }
        guard let start = pressedAt else { return }
        let a = phone(start)
        if case .combo? = game.capture {
            if let end = draggedTo {
                let b = phone(end)
                game.recordStep(GameKey.Step(kind: .swipe, x: a.x, y: a.y, toX: b.x, toY: b.y, ms: 120))
            } else {
                game.recordStep(GameKey.Step(kind: .tap, x: a.x, y: a.y))
            }
            return
        }
        if let end = draggedTo {
            game.pending = nil
            game.pendingSwipe = (a, phone(end))
        } else {
            game.pendTap(x: a.x, y: a.y)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let found = hit(convert(event.locationInWindow, from: nil)) { game?.remove(found.key.id) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let found = hit(convert(event.locationInWindow, from: nil)), [.joystick, .look, .skill].contains(found.key.kind) else { return }
        game?.resize(found.key.id, by: Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.0005 : 0.005))
    }

    // MARK: Drawing

    private static let mint = NSColor(calibratedRed: 0.31, green: 0.89, blue: 0.69, alpha: 1)
    private static let skillColor = NSColor(calibratedRed: 1, green: 0.76, blue: 0.36, alpha: 1)
    private static let swipeColor = NSColor(calibratedRed: 0.55, green: 0.48, blue: 1, alpha: 1)
    private static let selectColor = NSColor(calibratedRed: 1, green: 0.9, blue: 0.3, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let surface, let game, game.enabled, surface.showsGameKeys || game.editing else { return }
        let alpha: CGFloat = game.editing ? 0.9 : 0.4
        let width = surface.phoneWidthInView
        for key in game.keys {
            let center = surface.viewPoint(fromPhone: (key.x, key.y))
            let selected = game.editing && game.selected == key.id
            switch key.kind {
            case .joystick:
                let radius = max(14, key.radius * width)
                let ring = circle(center, radius)
                NSColor.white.withAlphaComponent(alpha * 0.2).setFill()
                ring.fill()
                NSColor.white.withAlphaComponent(alpha).setStroke()
                ring.lineWidth = 2
                ring.stroke()
                circle(center, 4).fill()
                // Each direction's key sits at its edge of the ring.
                let labels = key.directionLabels
                let inset = max(radius - 10, 8)
                let spots = [CGPoint(x: 0, y: inset), CGPoint(x: -inset, y: 0), CGPoint(x: 0, y: -inset), CGPoint(x: inset, y: 0)]
                for (label, offset) in zip(labels, spots) {
                    self.label(label, at: CGPoint(x: center.x + offset.x, y: center.y + offset.y), alpha: alpha)
                }
                if key.walk != .off {
                    let mod = ["56": "⇧", "59": "⌃", "58": "⌥"][String(key.walkKey)] ?? "⇧"
                    badge(mod + (key.walk == .fullWithKey ? "↑" : "½"), at: CGPoint(x: center.x + radius * 0.75, y: center.y + radius * 0.75),
                          color: NSColor.white.withAlphaComponent(alpha))
                }
                if selected { highlight(center, radius + 4) }
            case .look:
                let radius = max(14, key.radius * width)
                let ring = circle(center, radius)
                ring.setLineDash([6, 4], count: 2, phase: 0)
                ring.lineWidth = 2
                NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: alpha).setStroke()
                ring.stroke()
                label(game.looking ? "Aiming" : "Look  `", at: center, alpha: alpha)
                if selected { highlight(center, radius + 4) }
            case .fire:
                NSColor(calibratedRed: 1, green: 0.45, blue: 0.4, alpha: alpha * 0.85).setFill()
                circle(center, 18).fill()
                label("Click", at: center, alpha: 1, dark: true)
                if selected { highlight(center, 22) }
            case .skill:
                // The dashed ring shows how far the finger can be pulled to aim.
                let reach = circle(center, max(18, key.radius * width))
                reach.setLineDash([3, 3], count: 2, phase: 0)
                reach.lineWidth = 1.5
                Self.skillColor.withAlphaComponent(alpha).setStroke()
                reach.stroke()
                Self.skillColor.withAlphaComponent(alpha * 0.85).setFill()
                circle(center, 16).fill()
                symbol("target", at: CGPoint(x: center.x, y: center.y + 4), size: 12, color: NSColor.black.withAlphaComponent(0.8))
                label(key.label, at: CGPoint(x: center.x, y: center.y - 7), alpha: 1, dark: true, size: 9)
                if key.quickCast { badge("Q", at: CGPoint(x: center.x + 14, y: center.y + 14), color: Self.skillColor) }
                if selected { highlight(center, max(22, key.radius * width + 4)) }
            case .swipe:
                let end = surface.viewPoint(fromPhone: (key.toX, key.toY))
                arrow(from: center, to: end, color: Self.swipeColor.withAlphaComponent(alpha))
                Self.swipeColor.withAlphaComponent(alpha * 0.9).setFill()
                circle(center, 15).fill()
                label(key.label, at: center, alpha: 1)
                if selected { highlight(center, 19); highlight(end, 9) }
            case .tap:
                Self.mint.withAlphaComponent(alpha * 0.85).setFill()
                circle(center, 16).fill()
                label(key.label, at: center, alpha: 1, dark: true)
                let corner = CGPoint(x: center.x + 14, y: center.y + 14)
                switch key.mode {
                case .tap: break
                case .toggle: symbolBadge("lock.fill", at: corner, color: NSColor.white)
                case .autoFire: symbolBadge("bolt.fill", at: corner, color: Self.selectColor)
                case .combo:
                    let taps = key.steps.filter { $0.kind != .wait }.count
                    badge("\(max(taps, 1))", at: corner, color: Self.swipeColor)
                    if selected || game.capture == .combo(key.id) { drawSteps(key, surface: surface) }
                }
                if selected { highlight(center, 20) }
            }
        }
        if let pending = game.pending {
            let center = surface.viewPoint(fromPhone: pending)
            let ring = circle(center, 16)
            ring.setLineDash([4, 3], count: 2, phase: 0)
            ring.lineWidth = 2
            NSColor.white.setStroke()
            ring.stroke()
            label("Press a key", at: CGPoint(x: center.x, y: center.y + 28), alpha: 1)
        }
        if let swipe = game.pendingSwipe {
            let a = surface.viewPoint(fromPhone: swipe.from), b = surface.viewPoint(fromPhone: swipe.to)
            arrow(from: a, to: b, color: NSColor.white, dashed: true)
            label("Press a key", at: CGPoint(x: a.x, y: a.y + 24), alpha: 1)
        }
        if let start = pressedAt, let end = draggedTo { arrow(from: start, to: end, color: NSColor.white, dashed: true) }
    }

    /// A combo's taps as numbered dots, joined in order.
    private func drawSteps(_ key: GameKey, surface: ScreenSurface) {
        var number = 0
        var last: CGPoint?
        for step in key.steps where step.kind != .wait {
            number += 1
            let at = surface.viewPoint(fromPhone: (step.x, step.y))
            if let last {
                let line = NSBezierPath()
                line.move(to: last)
                line.line(to: at)
                line.setLineDash([3, 3], count: 2, phase: 0)
                line.lineWidth = 1
                NSColor.white.withAlphaComponent(0.6).setStroke()
                line.stroke()
            }
            if step.kind == .swipe {
                arrow(from: at, to: surface.viewPoint(fromPhone: (step.toX, step.toY)), color: Self.swipeColor)
            }
            badge("\(number)", at: at, color: Self.swipeColor)
            last = step.kind == .swipe ? surface.viewPoint(fromPhone: (step.toX, step.toY)) : at
        }
    }

    private func circle(_ center: CGPoint, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func highlight(_ center: CGPoint, _ radius: CGFloat) {
        let ring = circle(center, radius)
        ring.lineWidth = 2
        Self.selectColor.setStroke()
        ring.stroke()
    }

    private func arrow(from a: CGPoint, to b: CGPoint, color: NSColor, dashed: Bool = false) {
        let line = NSBezierPath()
        line.move(to: a)
        line.line(to: b)
        line.lineWidth = 3
        line.lineCapStyle = .round
        if dashed { line.setLineDash([6, 4], count: 2, phase: 0) }
        color.setStroke()
        line.stroke()
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = NSBezierPath()
        head.move(to: b)
        head.line(to: CGPoint(x: b.x - 12 * cos(angle - 0.45), y: b.y - 12 * sin(angle - 0.45)))
        head.line(to: CGPoint(x: b.x - 12 * cos(angle + 0.45), y: b.y - 12 * sin(angle + 0.45)))
        head.close()
        color.setFill()
        head.fill()
    }

    private func badge(_ text: String, at point: CGPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.black]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let width = max(14, size.width + 6)
        let rect = CGRect(x: point.x - width / 2, y: point.y - 7, width: width, height: 14)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        string.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    private func symbolBadge(_ name: String, at point: CGPoint, color: NSColor) {
        NSColor.black.withAlphaComponent(0.75).setFill()
        circle(point, 8).fill()
        symbol(name, at: point, size: 9, color: color)
    }

    private func symbol(_ name: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold)) else { return }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: point.x - base.size.width / 2, y: point.y - base.size.height / 2, width: base.size.width, height: base.size.height))
    }

    private func label(_ text: String, at point: CGPoint, alpha: CGFloat, dark: Bool = false, size: CGFloat = 11) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: (dark ? NSColor.black : NSColor.white).withAlphaComponent(alpha),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }
}
