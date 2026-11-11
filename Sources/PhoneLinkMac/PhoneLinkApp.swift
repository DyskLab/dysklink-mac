import AppKit
import SwiftUI

@MainActor
enum Shared {
    static let model = AppModel()
    static let tools = ToolsModel()
    static let care = MacCareModel()
    static let updates = UpdateChecker()
    static let callPauser = CallMusicPauser()
    static let menuBar = MenuBarLayout()
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
        // The page is let go while the window is closed, so its animations and views don't keep running.
        if !(window.contentView is NSHostingView<MainView>) {
            window.contentView = NSHostingView(rootView: MainView(model: Shared.model))
        }
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
        window.center()
        window.delegate = observer
        return window
    }

    private final class CloseObserver: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            // The Dock icon goes away, but connections keep running from the menu bar.
            let otherOpen = MainActor.assumeIsolated { ScreenWindow.isVisible || CameraWindow.isVisible }
            if !otherOpen { NSApp.setActivationPolicy(.accessory) }
            // Released after the window is gone, and made again by show().
            let window = notification.object as? NSWindow
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let window, !window.isVisible else { return }
                    window.contentView = nil
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?
    private var notchSyncTimer: Timer?
    private var lastNotchSignature: NotchState?

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
            ChargeControl.shared.start()
            model.onNeedsAttention = { MainWindow.show() }
            model.onPeerInfo = { id, name, info in
                Shared.tools.notch.model.phoneInfo(peer: id, name: name, info: info)
            }
            model.notchState = { NotchSync.state(of: Shared.tools.notch.model) }
            model.clipboardHistoryProvider = {
                guard Shared.tools.isClipboardOn else { return nil }
                return Shared.tools.clipboard.entries.compactMap { entry in
                    entry.text.map { SyncedClip(text: $0, time: Int64(entry.date.timeIntervalSince1970 * 1000)) }
                }
            }
            model.onClipboardHistory = { clips in
                guard Shared.tools.isClipboardOn else { return }
                _ = Shared.tools.clipboard.importClips(clips.map {
                    ImportedClip(text: $0.text, date: Date(timeIntervalSince1970: TimeInterval($0.time) / 1000))
                })
            }
            model.onNotchAction = { action in
                NotchSync.apply(action, to: Shared.tools.notch.model)
                self.syncNotch(force: true)
            }
            model.onCall = { Shared.callPauser.handle($0) }
            model.keepAwakeState = {
                guard Shared.tools.isAwakeOn else { return "unavailable" }
                return Shared.tools.awake.isActive ? "active" : "idle"
            }
            model.chargeState = { ChargeControl.shared.phoneState }
            ChargeControl.shared.onChange = { Shared.model.infoChanged() }
            model.onMacAction = { action in
                switch action {
                case "lock": MacActions.lockScreen()
                case "awake.start": if Shared.tools.isAwakeOn, !Shared.tools.awake.isActive, Shared.tools.awake.canStart { Shared.tools.awake.start() }
                case "awake.stop": if Shared.tools.isAwakeOn { Shared.tools.awake.stop() }
                case "charge.topup.start": if ChargeControl.shared.installed { ChargeControl.shared.topUp = true }
                case "charge.topup.stop": ChargeControl.shared.topUp = false
                case "charge.limit.on": if ChargeControl.shared.installed { ChargeControl.shared.settings.limiter = true }
                case "charge.limit.off": ChargeControl.shared.settings.limiter = false
                default: break
                }
            }
            Shared.tools.notch.model.alertsAvailable = { Shared.model.hasPhoneAlerts }
            // Shown even when the notch is off in settings would need its window, so it follows the notch.
            model.onMacScreenWatchers = { names in Shared.tools.notch.model.screenWatchers = names }
            model.onAudioListeners = { names in Shared.tools.notch.model.audioListeners = names }
            // Saved window layouts can be restored from the phone, like a Mac command.
            model.toolCommands = { Shared.tools.isLayoutOn ? Shared.tools.layout.commands : [] }
            model.runToolCommand = { id in
                guard id.hasPrefix(WindowLayout.commandPrefix) else { return nil }
                guard Shared.tools.isLayoutOn else { return "Turn on Window Layouts in DyskLink on the Mac." }
                return Shared.tools.layout.runCommand(id)
            }
            Shared.tools.layout.onChange = { [weak model] in model?.toolCommandsChanged() }
            model.onCode = { code in
                guard Shared.tools.isNotchOn else { return }
                Shared.tools.notch.model.showCode(code)
            }
            model.onPhoneNotification = { alert in
                let notch = Shared.tools.notch.model
                guard Shared.tools.isNotchOn, notch.isShown(.alerts) else { return }
                notch.showNotice(alert)
            }
            model.start()
            startNotchSync()
            Shared.tools.monitor.isOnScreen = { MainWindow.isVisible && Shared.model.showsTools }
            Shared.tools.start()
            Shared.updates.start()
            if model.hasPairedDevices {
                NSApp.setActivationPolicy(.accessory)
            } else {
                MainWindow.show()
            }
        }
    }

    /// Checks once a second whether the notch's data changed, and sends it to the phones if so.
    @MainActor
    private func startNotchSync() {
        lastNotchSignature = NotchSync.signature(of: Shared.tools.notch.model)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNotch(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        notchSyncTimer = timer
    }

    @MainActor
    private func syncNotch(force: Bool) {
        let model = Shared.tools.notch.model
        let signature = NotchSync.signature(of: model)
        guard force || signature != lastNotchSignature else { return }
        lastNotchSignature = signature
        Shared.model.broadcastNotch(NotchSync.state(of: model))
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            Shared.tools.shutDown()
            ChargeControl.shared.shutDown()
        }
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
        LegacyMigration.run()
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
        if let index = CommandLine.arguments.firstIndex(of: "--update-check"),
           CommandLine.arguments.count > index + 1 {
            print(UpdateChecker.liveCheck(as: CommandLine.arguments[index + 1]))
            exit(0)
        }
        if CommandLine.arguments.contains("--tools-selftest") {
            exit(MainActor.assumeIsolated { ToolsSelfTest.run() } ? 0 : 1)
        }
        // Makes an extra display for two seconds and checks macOS lists it, then removes it.
        if CommandLine.arguments.contains("--virtual-display-test") {
            let before = Set(VirtualDisplayCheck.activeDisplays())
            let args = CommandLine.arguments
            let at = args.firstIndex(of: "--virtual-display-test")!
            let wantW = args.count > at + 2 ? Int(args[at + 1]) ?? 1334 : 1334
            let wantH = args.count > at + 2 ? Int(args[at + 2]) ?? 600 : 600
            var display = SecondDisplay.make(name: "DyskLink test", width: wantW, height: wantH, serial: UInt32(wantW * 10000 + wantH))
            let id = display?.displayID ?? 0
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            if ProcessInfo.processInfo.environment["DYSKLINK_DEBUG_DISPLAY"] != nil {
                let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
                let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
                print("MODES " + modes.filter { $0.isUsableForDesktopGUI() }.map { "\($0.width)x\($0.height)@\($0.pixelWidth)" }.joined(separator: " "))
            }
            let during = VirtualDisplayCheck.activeDisplays()
            let bounds = CGDisplayBounds(id)
            let pixels = CGDisplayCopyDisplayMode(id).map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
            display = nil
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            let after = Set(VirtualDisplayCheck.activeDisplays())
            print("VIRTUAL_DISPLAY id=\(id) listed=\(during.contains(id)) bounds=\(Int(bounds.width))x\(Int(bounds.height)) pixels=\(pixels) removed=\(after == before)")
            exit(id != 0 && during.contains(id) && after == before && Int(bounds.width) == wantW ? 0 : 1)
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
            MenuBarLabel(model: Shared.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon, with the number of phone notifications next to it.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: LogoGlyph.menuBarImage())
            if model.alertCount > 0 { Text("\(model.alertCount)").monospacedDigit() }
        }
    }
}

enum VirtualDisplayCheck {
    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
