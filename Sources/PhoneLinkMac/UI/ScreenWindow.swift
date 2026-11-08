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
    }

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
        video.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(quarterTurns) * .pi / 2))
        CATransaction.commit()
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

    private func touch(_ kind: String, _ point: (x: Float, y: Float)) {
        let phone = Self.phonePoint(point, quarterTurns: quarterTurns)
        onControl?(ControlEvent(kind: kind, x: phone.x, y: phone.y))
    }

    /// Movement is sent while it happens, at most about 90 times a second.
    private func isDue(_ event: NSEvent) -> Bool {
        guard event.timestamp - lastSentAt >= Self.sendInterval else { return false }
        lastSentAt = event.timestamp
        return true
    }

    override func mouseDown(with event: NSEvent) {
        finishScroll()
        window?.makeFirstResponder(self)
        isPressed = true
        touch("down", normalized(event))
    }

    override func mouseDragged(with event: NSEvent) {
        if isPressed && isDue(event) { touch("drag", normalized(event)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        touch("up", normalized(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        onControl?(ControlEvent(kind: "key", key: "back"))
    }

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
        if let control = PhoneKeys.controlEvent(for: event) { onControl?(control) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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

private struct ScreenWindowContent: View {
    let model: AppModel
    let peerId: String
    let surface: ScreenSurface

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHost(surface: surface)
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
                Button { ScreenWindow.rotate() } label: {
                    Image(systemName: "rotate.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 34, height: 28).background(Theme.panelRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Rotate the picture. The phone doesn't rotate.")
                Button("Stop") { model.stopScreen() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.coral)
            }
            .padding(.horizontal, 12)
            .frame(height: ScreenWindow.barHeight)
            .background(Theme.panel)
        }
        .preferredColorScheme(.dark)
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

/// A separate window for the phone screen, so it can sit beside other work.
@MainActor
enum ScreenWindow {
    static let barHeight: CGFloat = 44

    private static var window: NSWindow?
    private static var surface: ScreenSurface?
    private static var closingFromModel = false
    private static let observer = Observer()

    static var isVisible: Bool { window?.isVisible == true }

    private static let turnsKey = "screen.quarterTurns"

    /// The window follows the picture's aspect ratio, portrait or landscape.
    static func contentSize(for picture: CGSize) -> CGSize {
        picture.height >= picture.width
            ? CGSize(width: 720 * picture.width / picture.height, height: 720 + barHeight)
            : CGSize(width: 960, height: 960 * picture.height / picture.width + barHeight)
    }

    /// The turn is remembered for the next session.
    static func rotate() {
        guard let window, let surface else { return }
        surface.quarterTurns = (surface.quarterTurns + 1) % 4
        UserDefaults.standard.set(surface.quarterTurns, forKey: turnsKey)
        window.setContentSize(contentSize(for: surface.displaySize))
    }

    static func show(model: AppModel, peerId: String, name: String, info: ScreenInfo) {
        let videoSize = CGSize(width: info.width, height: info.height)
        if let window, let surface {
            surface.videoSize = videoSize
            window.setContentSize(contentSize(for: surface.displaySize))
            return
        }
        let view = ScreenSurface(frame: .zero)
        view.videoSize = videoSize
        view.quarterTurns = UserDefaults.standard.integer(forKey: turnsKey) % 4
        let content = contentSize(for: view.displaySize)
        view.onControl = { [weak model] event in model?.sendControl(event, to: peerId) }
        let created = NSWindow(
            contentRect: NSRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        created.title = "\(name) screen"
        created.isReleasedWhenClosed = false
        created.contentView = NSHostingView(rootView: ScreenWindowContent(model: model, peerId: peerId, surface: view))
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
        closingFromModel = true
        window?.close()
        closingFromModel = false
        window = nil
        surface = nil
    }

    private final class Observer: NSObject, NSWindowDelegate {
        var onUserClose: (() -> Void)?

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                if !closingFromModel { onUserClose?() }
                if !MainWindow.isVisible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}
