import AppKit
import SwiftUI

/// Settings for the camera window that the bar changes.
@MainActor
@Observable
final class CameraWindowState {
    var showsBar = true
    var floats = UserDefaults.standard.bool(forKey: "camera.floats")
    /// Extra quarter turns chosen on the Mac, on top of what the phone reports.
    var extraTurns = UserDefaults.standard.integer(forKey: "camera.extraTurns") % 4
    var mirrorFront = UserDefaults.standard.object(forKey: "camera.mirrorFront") as? Bool ?? true
    var torch = false
}

private struct CameraWindowContent: View {
    let model: AppModel
    let surface: ScreenSurface
    let state: CameraWindowState

    var body: some View {
        VStack(spacing: 0) {
            CameraSurfaceHost(surface: surface)
            if state.showsBar {
                HStack(spacing: 6) {
                    let camera = model.camera
                    Text(camera?.facing == "front" ? "Front camera" : "Back camera")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 4)
                    barButton("arrow.triangle.2.circlepath.camera", "Switch camera") {
                        state.torch = false
                        model.cameraControl("switch")
                    }
                    if camera?.facing != "front" {
                        barButton(state.torch ? "flashlight.on.fill" : "flashlight.off.fill", "Light", active: state.torch) {
                            state.torch.toggle()
                            model.cameraControl("torch")
                        }
                    }
                    if camera?.facing == "front" {
                        barButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Mirror", active: state.mirrorFront) {
                            state.mirrorFront.toggle()
                            UserDefaults.standard.set(state.mirrorFront, forKey: "camera.mirrorFront")
                            CameraWindow.apply()
                        }
                    }
                    barButton("rotate.left", "Rotate left") { CameraWindow.rotate(by: -1) }
                    barButton("rotate.right", "Rotate right") { CameraWindow.rotate(by: 1) }
                    barButton(state.floats ? "pin.fill" : "pin", "Keep on top", active: state.floats) { CameraWindow.toggleFloat() }
                    barButton("rectangle.dashed", "Clean view for OBS. Double-click the picture or press ⌘B to bring the bar back.") {
                        CameraWindow.setBar(false)
                    }
                    Button("Stop") { model.stopCamera() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.coralText)
                        .padding(.leading, 4)
                }
                .padding(.horizontal, 12)
                .frame(height: CameraWindow.barHeight)
                .background(Theme.panel)
            }
        }
        .environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }

    private func barButton(_ icon: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(active ? Theme.onAccent : Theme.textPrimary)
                .frame(width: 32, height: 28)
                .background(active ? Theme.mint : Theme.panelRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct CameraSurfaceHost: NSViewRepresentable {
    let surface: ScreenSurface
    func makeNSView(context: Context) -> ScreenSurface { surface }
    func updateNSView(_ view: ScreenSurface, context: Context) {}
}

/// The phone camera in its own window. OBS can capture it with Window Capture; the clean view hides the bar.
@MainActor
enum CameraWindow {
    static let barHeight: CGFloat = 44

    private static var window: NSWindow?
    private static var surface: ScreenSurface?
    private static var session: CameraSession?
    private static let state = CameraWindowState()
    private static var closingFromModel = false
    private static let observer = Observer()

    static var isVisible: Bool { window?.isVisible == true }

    static func turns(phoneRotation: Int, extra: Int) -> Int { (phoneRotation / 90 + extra) % 4 }

    /// About 640 points on the long side, keeping the picture's shape.
    static func contentSize(for picture: CGSize, bar: Bool) -> CGSize {
        let scale = 640 / max(picture.width, picture.height, 1)
        return CGSize(width: picture.width * scale, height: picture.height * scale + (bar ? barHeight : 0))
    }

    static func show(model: AppModel, session: CameraSession) {
        self.session = session
        if window == nil {
            let view = ScreenSurface(frame: .zero)
            view.onDoubleClick = { setBar(!state.showsBar) }
            view.onToggleBar = { setBar(!state.showsBar) }
            let created = NSWindow(
                contentRect: NSRect(origin: .zero, size: CGSize(width: 640, height: 400)),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            created.isReleasedWhenClosed = false
            // Video windows stay dark in every appearance, so the picture has a dark frame.
            created.appearance = NSAppearance(named: .darkAqua)
            created.contentView = NSHostingView(rootView: CameraWindowContent(model: model, surface: view, state: state))
            created.delegate = observer
            observer.onUserClose = { [weak model] in model?.stopCamera() }
            window = created
            surface = view
            state.torch = false
            apply()
            created.center()
            NSApp.setActivationPolicy(.regular)
            created.makeKeyAndOrderFront(nil)
            created.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            apply()
        }
        window?.title = "\(session.peerName) camera"
    }

    /// Applies turns, mirroring, floating, and the window size from the current settings.
    static func apply() {
        guard let window, let surface, let session else { return }
        surface.videoSize = CGSize(width: session.info.width, height: session.info.height)
        surface.quarterTurns = turns(phoneRotation: session.rotation, extra: state.extraTurns)
        surface.mirrored = session.facing == "front" && state.mirrorFront
        window.level = state.floats ? .floating : .normal
        let size = contentSize(for: surface.displaySize, bar: state.showsBar)
        // Keep the user's width when only the shape changes a little.
        window.setContentSize(size)
        window.contentAspectRatio = NSSize(width: surface.displaySize.width, height: surface.displaySize.height + (state.showsBar ? barHeight : 0))
    }

    static func rotate(by steps: Int = 1) {
        state.extraTurns = ((state.extraTurns + steps) % 4 + 4) % 4
        UserDefaults.standard.set(state.extraTurns, forKey: "camera.extraTurns")
        apply()
    }

    static func toggleFloat() {
        state.floats.toggle()
        UserDefaults.standard.set(state.floats, forKey: "camera.floats")
        apply()
    }

    static func setBar(_ shown: Bool) {
        state.showsBar = shown
        apply()
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
        session = nil
        state.showsBar = true
    }

    private final class Observer: NSObject, NSWindowDelegate {
        var onUserClose: (() -> Void)?

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                if !closingFromModel { onUserClose?() }
                if !MainWindow.isVisible && !ScreenWindow.isVisible { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}
