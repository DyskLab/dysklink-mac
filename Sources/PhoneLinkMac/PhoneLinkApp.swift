import AppKit
import SwiftUI

@MainActor
enum Shared {
    static let model = AppModel()
    static let tools = ToolsModel()
}

/// AppKit manages the main window so the app stays alive in the menu bar when it closes,
/// and it can reopen at any time, including for a pairing request.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    private static let observer = CloseObserver()

    static var isVisible: Bool { window?.isVisible == true }

    static func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DyskLink"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(red: 0.035, green: 0.05, blue: 0.075, alpha: 1)
        window.contentView = NSHostingView(rootView: MainView(model: Shared.model))
        window.center()
        window.delegate = observer
        return window
    }

    private final class CloseObserver: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            // The Dock icon goes away, but connections keep running from the menu bar.
            let screenOpen = MainActor.assumeIsolated { ScreenWindow.isVisible }
            if !screenOpen { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stops App Nap from slowing connections while the app is in the background.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keeping device connections alive"
        )
        #if DEBUG
        if CommandLine.arguments.contains("--tools-smoke") {
            MainActor.assumeIsolated { ToolsSelfTest.smoke() }
            return
        }
        #endif
        MainActor.assumeIsolated {
            let model = Shared.model
            model.onNeedsAttention = { MainWindow.show() }
            model.start()
            Shared.tools.monitor.isOnScreen = { MainWindow.isVisible && Shared.model.showsTools }
            Shared.tools.start()
            if model.hasPairedDevices {
                NSApp.setActivationPolicy(.accessory)
            } else {
                MainWindow.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Shared.tools.shutDown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindow.show() }
        return true
    }
}

@main
struct PhoneLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        #if DEBUG
        setvbuf(stdout, nil, _IOLBF, 0)
        if let index = CommandLine.arguments.firstIndex(of: "--render-icon"),
           CommandLine.arguments.count > index + 1 {
            MainActor.assumeIsolated { Snapshots.renderIcon(to: CommandLine.arguments[index + 1]) }
            exit(0)
        }
        if CommandLine.arguments.contains("--ddc-write-test") {
            print(DisplayControl.writeTest())
            exit(0)
        }
        if CommandLine.arguments.contains("--mouse-state") {
            print(MainActor.assumeIsolated { MouseTuner().debugState() })
            exit(0)
        }
        if CommandLine.arguments.contains("--hardware-probe") {
            print(DisplayControl.probe())
            print(MainActor.assumeIsolated { MouseTuner.probe() })
            exit(0)
        }
        if CommandLine.arguments.contains("--tools-selftest") {
            exit(MainActor.assumeIsolated { ToolsSelfTest.run() } ? 0 : 1)
        }
        if CommandLine.arguments.contains("--video-selftest") {
            exit(VideoSelfTest.run() ? 0 : 1)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > index + 1 {
            MainActor.assumeIsolated { Snapshots.render(to: CommandLine.arguments[index + 1]) }
            exit(0)
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: Shared.model)
        } label: {
            Image(nsImage: LogoGlyph.menuBarImage())
        }
        .menuBarExtraStyle(.window)
    }
}
