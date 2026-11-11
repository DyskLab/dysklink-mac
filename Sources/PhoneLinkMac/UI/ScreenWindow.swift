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

    /// A mouse movement turned into a move on the phone, following the picture's rotation.
    private func lookMove(_ event: NSEvent) {
        guard let game, game.looking else { return }
        let dx = Float(event.deltaX * Self.lookScale), dy = Float(event.deltaY * Self.lookScale)
        let origin = Self.phonePoint((0.5, 0.5), quarterTurns: quarterTurns)
        let moved = Self.phonePoint((0.5 + dx, 0.5 + dy), quarterTurns: quarterTurns)
        game.look(dx: Double(moved.x - origin.x), dy: Double(moved.y - origin.y) * game.aspect)
    }

    override func mouseMoved(with event: NSEvent) { lookMove(event) }
    var showsGameKeys = true { didSet { overlay.needsDisplay = true } }
    private let overlay = GameKeysOverlay()

    private let video = CALayer()

    private var isPressed = false
    private var lastSentAt: TimeInterval = 0
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
        if playing {
            // In game mode the mouse is its own finger, so it works while keys are held.
            let multi = ["down": "tdown", "drag": "tmove", "up": "tup"][kind] ?? kind
            onControl?(ControlEvent(kind: multi, x: phone.x, y: phone.y, key: String(GameKeyEngine.mouseFinger)))
        } else {
            onControl?(ControlEvent(kind: kind, x: phone.x, y: phone.y))
        }
    }

    /// Movement is sent while it happens, at most about 90 times a second.
    private func isDue(_ event: NSEvent) -> Bool {
        guard event.timestamp - lastSentAt >= Self.sendInterval else { return false }
        lastSentAt = event.timestamp
        return true
    }

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
                if event.keyCode == 53 { game.pending = nil; return }
                _ = game.assign(code: event.keyCode, label: GameKeysModel.label(for: event))
                return
            }
            if game.looking, event.keyCode == 53 { return game.toggleLook() }
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

    /// Shift, Control, and Option only arrive as flag changes.
    override func flagsChanged(with event: NSEvent) {
        guard let game, game.enabled else { return super.flagsChanged(with: event) }
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
        VStack(spacing: 0) {
            SurfaceHost(surface: surface)
            if state.showsBar {
                if game.enabled { gameBar }
                bar
            }
        }
        .preferredColorScheme(.dark)
    }

    private var gameBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill").foregroundStyle(Theme.mint)
            Text(game.editing
                 ? (game.pending != nil ? "Press the key for this spot. Esc cancels." : "Click a spot, then press a key. ⌥-click: WASD joystick. ⇧-click: look area. ⌘-click: mouse-click spot. Drag to move, right-click to delete, scroll to resize.")
                 : game.looking ? "Aiming with the mouse. Click presses the click spot. ` or Esc stops."
                 : (game.keys.isEmpty ? "No keys yet. Click Edit keys to place them on the picture." : "Game keys on: \(game.tapCount) key\(game.tapCount == 1 ? "" : "s")\(game.hasJoystick ? " + WASD joystick" : "")\(game.hasLook ? ". Press ` to aim with the mouse" : ". The mouse taps too")."))
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(2)
            Spacer(minLength: 4)
            profileMenu
            if game.editing && !game.keys.isEmpty {
                Button("Clear") { game.clear() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.coral)
            }
            Button(game.editing ? "Done" : "Edit keys") { game.editing.toggle(); ScreenWindow.focusSurface() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.panelRaised)
    }

    /// Each game keeps its own layout.
    private var profileMenu: some View {
        Menu {
            ForEach(Array(game.profiles.enumerated()), id: \.offset) { index, profile in
                Button { game.selectProfile(index) } label: {
                    if index == game.current { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) }
                }
            }
            Divider()
            Button("New game…") { if let name = GameProfileNames.ask("New game", value: "") { game.addProfile(named: name) } }
            Button("Rename \(game.profileName)…") {
                if let name = GameProfileNames.ask("Rename game", value: game.profileName) { game.renameProfile(name) }
            }
            Button(game.profiles.count > 1 ? "Delete \(game.profileName)" : "Clear keys", role: .destructive) { game.deleteProfile() }
            if game.hasLook {
                Divider()
                Picker("Aim speed", selection: Binding(get: { game.lookSpeed }, set: { game.lookSpeed = $0 })) {
                    Text("Slow").tag(0.6)
                    Text("Normal").tag(1.0)
                    Text("Fast").tag(1.7)
                }
            }
        } label: {
            Text(game.profileName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Game profile: each game keeps its own keys")
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
                        .foregroundStyle(game.enabled ? Theme.ink : Theme.textPrimary)
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
                        .foregroundStyle(state.floats ? Theme.ink : Theme.textPrimary)
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
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.coral)
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
        window.setContentSize(contentSize(for: surface.displaySize, bar: state.showsBar))
    }

    static func show(model: AppModel, peerId: String, name: String, info: ScreenInfo) {
        let videoSize = CGSize(width: info.width, height: info.height)
        game.setAspect(Double(info.width) / Double(max(info.height, 1)))
        if let window, let surface {
            surface.videoSize = videoSize
            window.setContentSize(contentSize(for: surface.displaySize, bar: state.showsBar))
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
        created.contentView = NSHostingView(rootView: ScreenWindowContent(model: model, peerId: peerId, surface: view, state: state, game: game))
        created.level = state.floats ? .floating : .normal
        created.delegate = observer
        observer.onUserClose = { [weak model] in model?.stopScreen() }
        created.center()
        window = created
        surface = view
        NSApp.setActivationPolicy(.regular)
        created.makeKeyAndOrderFront(nil)
        created.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func display(_ buffer: CVPixelBuffer) {
        surface?.display(buffer)
    }

    static func close() {
        game.enabled = false
        closingFromModel = true
        window?.close()
        closingFromModel = false
        window = nil
        surface = nil
    }

    private final class Observer: NSObject, NSWindowDelegate {
        var onUserClose: (() -> Void)?

        /// Keys held when the window loses focus never get their release, so fingers are lifted now.
        func windowDidResignKey(_ notification: Notification) {
            MainActor.assumeIsolated { game.release() }
        }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
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
    private var dragging: UUID?

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard game?.editing == true else { return nil }
        return super.hitTest(point)
    }

    private func hit(_ point: CGPoint) -> GameKey? {
        guard let surface, let game else { return nil }
        return game.keys.last { key in
            let center = surface.viewPoint(fromPhone: (key.x, key.y))
            let reach = [.joystick, .look].contains(key.kind) ? max(20, key.radius * surface.phoneWidthInView) : 18
            return hypot(center.x - point.x, center.y - point.y) <= reach
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface, let game else { return }
        window?.makeFirstResponder(surface)
        let point = convert(event.locationInWindow, from: nil)
        guard surface.pictureRect.contains(point) else { return }
        if let key = hit(point) {
            dragging = key.id
            return
        }
        let phone = surface.phonePoint(atView: point)
        if event.modifierFlags.contains(.option) {
            game.placeJoystick(x: Double(phone.x), y: Double(phone.y))
        } else if event.modifierFlags.contains(.shift) {
            game.placeLook(x: Double(phone.x), y: Double(phone.y))
        } else if event.modifierFlags.contains(.command) {
            game.placeFire(x: Double(phone.x), y: Double(phone.y))
        } else {
            game.pending = (Double(phone.x), Double(phone.y))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging, let surface, let game else { return }
        let phone = surface.phonePoint(atView: convert(event.locationInWindow, from: nil))
        game.move(dragging, x: Double(phone.x), y: Double(phone.y))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging != nil { game?.finishMove() }
        dragging = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if let key = hit(convert(event.locationInWindow, from: nil)) { game?.remove(key.id) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let key = hit(convert(event.locationInWindow, from: nil)), [.joystick, .look].contains(key.kind) else { return }
        game?.resize(key.id, by: Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.0005 : 0.005))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let surface, let game, game.enabled, surface.showsGameKeys || game.editing else { return }
        let alpha: CGFloat = game.editing ? 0.9 : 0.4
        for key in game.keys {
            let center = surface.viewPoint(fromPhone: (key.x, key.y))
            if key.kind == .joystick {
                let radius = max(14, key.radius * surface.phoneWidthInView)
                let ring = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                NSColor.white.withAlphaComponent(alpha * 0.25).setFill()
                ring.fill()
                NSColor.white.withAlphaComponent(alpha).setStroke()
                ring.lineWidth = 2
                ring.stroke()
                label("WASD", at: center, alpha: alpha)
            } else if key.kind == .look {
                let radius = max(14, key.radius * surface.phoneWidthInView)
                let ring = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                ring.setLineDash([6, 4], count: 2, phase: 0)
                ring.lineWidth = 2
                NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: alpha).setStroke()
                ring.stroke()
                label(game.looking ? "Aiming" : "Look  `", at: center, alpha: alpha)
            } else if key.kind == .fire {
                let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))
                NSColor(calibratedRed: 1, green: 0.45, blue: 0.4, alpha: alpha * 0.85).setFill()
                dot.fill()
                label("Click", at: center, alpha: 1, dark: true)
            } else {
                let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32))
                NSColor(calibratedRed: 0.31, green: 0.89, blue: 0.69, alpha: alpha * 0.85).setFill()
                dot.fill()
                label(key.label, at: center, alpha: 1, dark: true)
            }
        }
        if let pending = game.pending {
            let center = surface.viewPoint(fromPhone: pending)
            let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32))
            ring.setLineDash([4, 3], count: 2, phase: 0)
            ring.lineWidth = 2
            NSColor.white.setStroke()
            ring.stroke()
            label("Press a key", at: CGPoint(x: center.x, y: center.y + 28), alpha: 1)
        }
    }

    private func label(_ text: String, at point: CGPoint, alpha: CGFloat, dark: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: (dark ? NSColor.black : NSColor.white).withAlphaComponent(alpha),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }
}
