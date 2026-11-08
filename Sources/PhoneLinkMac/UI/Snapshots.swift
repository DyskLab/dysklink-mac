#if DEBUG
import AppKit
import SwiftUI

/// Renders PNGs of the main screens: `PhoneLinkMac --snapshot <folder>`.
@MainActor
enum Snapshots {
    static func render(to folder: String) {
        let phone = Peer(
            id: "demo-1", name: "Sample Phone", platform: "android", model: "Android 36",
            isPaired: true, isConnected: true,
            info: DeviceInfo(batteryPercent: 76, isCharging: true, network: "Wi-Fi",
                             storageFreeBytes: 82_000_000_000, storageTotalBytes: 256_000_000_000,
                             osVersion: "Android 16", model: "Android 36"),
            lastSeen: nil
        )
        let offline = Peer(
            id: "demo-2", name: "Second Phone", platform: "android", model: "Android 34",
            isPaired: true, isConnected: false, info: nil, lastSeen: nil
        )
        let fresh = Peer(
            id: "demo-3", name: "New Phone", platform: "android", model: "Android 35",
            isPaired: false, isConnected: true, info: nil, lastSeen: nil
        )
        let prompt = PairingPrompt(peerId: "demo-3", peerName: "New Phone", code: "482915", startedByPeer: true)

        save([], nil, "1-empty", folder)
        save([phone, offline, fresh], nil, "2-devices", folder)
        save([fresh, phone], nil, "3-new", folder)
        save([fresh, phone], prompt, "4-pairing", folder)
        var demo = PhoneSnapshot()
        demo.apply(features: ["notifications", "sms", "calls", "contacts", "files", "screen", "control"])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        demo.setContacts([
            ContactItem(id: "1", name: "Ayu Lestari", phones: ["+6281200000001"]),
            ContactItem(id: "2", name: "Budi Santoso", phones: ["081200000002", "+6221000000"]),
            ContactItem(id: "3", name: "Citra Dewi", phones: ["+6281200000003"]),
        ])
        demo.upsert(NotificationItem(key: "1", app: "Messages", title: "Ayu Lestari", text: "Still meeting at three?", time: now - 60_000))
        demo.upsert(NotificationItem(key: "2", app: "Calendar", title: "Team meeting", text: "Starts in 15 minutes", time: now - 900_000))
        demo.merge([
            SmsItem(id: 3, threadId: 1, address: "+6281200000001", body: "Still meeting at three?", time: now - 60_000, outgoing: false),
            SmsItem(id: 2, threadId: 1, address: "+6281200000001", body: "Okay, leaving now.", time: now - 400_000, outgoing: true),
            SmsItem(id: 1, threadId: 2, address: "081200000002", body: "Thanks!", time: now - 7_200_000, outgoing: false),
        ])
        demo.lastCall = CallEvent(state: "missed", number: "081200000002", time: now - 300_000)
        demo.folder = "Download"
        demo.entries = [
            FsEntry(name: "Photos", isDirectory: true, size: 0, modified: now - 86_400_000),
            FsEntry(name: "laporan.pdf", isDirectory: false, size: 2_400_000, modified: now - 3_600_000),
        ]
        var off = PhoneSnapshot()
        off.apply(features: [])
        save([phone], nil, "5-overview", folder, phone: demo, tab: .overview)
        save([phone], nil, "6-notifications", folder, phone: demo, tab: .notifications)
        save([phone], nil, "7-messages", folder, phone: demo, tab: .messages)
        save([phone], nil, "8-contacts", folder, phone: demo, tab: .contacts)
        save([phone], nil, "9-files", folder, phone: demo, tab: .files)
        save([phone], nil, "11-screen", folder, phone: demo, tab: .screen)
        save([phone], nil, "10-off", folder, phone: off, tab: .messages)
        renderTools(to: folder)
        renderTurns(to: folder)
    }

    /// The phone picture at each quarter turn. The phone's top left corner is red and its top edge is green.
    private static func renderTurns(to folder: String) {
        let phone = CGSize(width: 90, height: 160)
        guard let draw = CGContext(data: nil, width: Int(phone.width), height: Int(phone.height), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        draw.setFillColor(NSColor.darkGray.cgColor); draw.fill(CGRect(origin: .zero, size: phone))
        draw.setFillColor(NSColor.green.cgColor); draw.fill(CGRect(x: 0, y: phone.height - 12, width: phone.width, height: 12))
        draw.setFillColor(NSColor.red.cgColor); draw.fill(CGRect(x: 0, y: phone.height - 30, width: 30, height: 30))
        guard let picture = draw.makeImage() else { return }
        let side = 200
        guard let sheet = CGContext(data: nil, width: side * 4, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        for turns in 0..<4 {
            let view = ScreenSurface(frame: CGRect(x: 0, y: 0, width: side, height: side))
            view.videoSize = phone
            view.quarterTurns = turns
            view.show(picture)
            view.layout()
            sheet.saveGState()
            sheet.translateBy(x: CGFloat(turns * side), y: 0)
            view.layer?.render(in: sheet)
            sheet.restoreGState()
        }
        guard let image = sheet.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("20-screen-turns.png"))
    }

    private static func renderTools(to folder: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dysk-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = ToolsModel(directory: directory, isInert: true)
        tools.displays.loadSnapshot([
            DisplayItem(id: 1, name: "Built-in Display", method: .builtIn, brightness: 0.7),
            DisplayItem(id: 2, name: "Monitor with DDC", method: .monitor, brightness: 0.45, volume: 0.3),
            DisplayItem(id: 3, name: "Monitor without DDC", method: .dimming, brightness: 0.8),
        ], output: "MacBook Air Speakers", volume: 0.4)
        tools.isMonitorOn = true
        tools.isAwakeOn = true
        tools.isClipboardOn = true
        tools.isDisplaysOn = true
        tools.isMouseOn = true
        tools.mouse.isLinear = true
        tools.isPreviewsOn = false
        tools.monitor.isOnScreen = { false }
        for _ in 0..<40 {
            tools.monitor.refresh()
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        tools.clipboard.add(text: "Meeting moved to 3 PM, see you in room B")
        tools.clipboard.add(text: "https://buymeacoffee.com/fannydevz")
        tools.clipboard.add(text: "A much longer note that runs past the end of one row, so this checks how two lines are cut off when the text keeps on going for a while longer than fits.")
        if let first = tools.clipboard.entries.last { tools.clipboard.togglePin(first) }
        write(AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 1700)
            .background(Theme.ink).preferredColorScheme(.dark), "12-advanced", folder)
        tools.isNotchOn = true
        write(AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 2300)
            .background(Theme.ink).preferredColorScheme(.dark), "22-advanced-notch", folder)
        tools.isNotchOn = false
        let notch = NotchModel(directory: directory)
        notch.isOpen = true
        notch.closedSize = CGSize(width: 179, height: 32)
        let start = Date()
        var timer = Pomodoro()
        timer.start(at: start)
        _ = timer.advance(at: start.addingTimeInterval(1500))
        _ = timer.advance(at: start.addingTimeInterval(1800))
        let snapshotNow = start.addingTimeInterval(3300 - 1122)
        notch.loadSnapshot(playing: NowPlaying(title: "Paper Birds", artist: "Sample Artist", isPlaying: false,
                                               duration: 256, position: 193),
                           pomodoro: timer, now: snapshotNow)
        let samplePeer = Peer(id: "demo", name: "Sample Phone", platform: "android", model: "", isPaired: true,
                              isConnected: true, info: DeviceInfo(batteryPercent: 76, isCharging: true), lastSeen: nil)
        let notchFrame = { (model: NotchModel) in
            // The magenta block shows where the real camera sits, to check nothing is under it.
            NotchView(model: model, tools: tools, phoneProvider: { [samplePeer] },
                      transfersProvider: { [Transfer(id: "t", peerId: "demo", name: "Holiday photos.zip",
                                                     size: 100, transferred: 62, outgoing: true)] },
                      sendFile: { _, _ in }, scrolls: false).frame(width: 640, height: 292)
                .overlay(alignment: .top) { Rectangle().fill(Color(hex: 0xC2185B)).frame(width: 179, height: 32) }
                .background(Color(hex: 0x3A4658)).preferredColorScheme(.dark)
        }
        write(notchFrame(notch), "14-notch-music", folder)
        notch.page = .shelf
        notch.shelfMode = .clipboard
        write(notchFrame(notch), "15-notch-clipboard", folder)
        notch.shelfMode = .files
        write(notchFrame(notch), "16-notch-shelf", folder)
        notch.page = .focus
        write(notchFrame(notch), "21-notch-pomodoro", folder)
        notch.pomodoroSettings = PomodoroSettings(focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 30, sessions: 3)
        notch.resetPomodoro()
        write(notchFrame(notch), "23-notch-pomodoro-custom", folder)
        notch.pomodoroSettings = PomodoroSettings()
        notch.resetPomodoro()
        notch.loadSnapshot(playing: nil, pomodoro: timer, now: snapshotNow)
        notch.setShown(.music, false)
        notch.setShown(.files, false)
        write(notchFrame(notch), "24-notch-two-pages", folder)
        notch.setShown(.music, true)
        notch.setShown(.files, true)
        notch.page = .focus
        notch.isOpen = false
        write(notchFrame(notch), "17-notch-focus", folder)
        notch.loadSnapshot(playing: nil, pomodoro: Pomodoro(), now: Date())
        write(notchFrame(notch), "18-notch-closed", folder)
        let strip = WindowListState()
        let sampleWindow = AXUIElementCreateApplication(getpid())
        strip.appName = "Sample App"
        strip.windows = [
            WindowItem(id: 1, title: "Project notes", appName: "Sample App", pid: getpid(), icon: NSApp.applicationIconImage, isMinimized: false, element: sampleWindow),
            WindowItem(id: 2, title: "A window with quite a long title to check how it is cut", appName: "Sample App", pid: getpid(), icon: NSApp.applicationIconImage, isMinimized: true, element: sampleWindow),
        ]
        let stripSize = WindowStrip.size(count: 2, cardWidth: 250, isSwitcher: false, showsHint: !CGPreflightScreenCaptureAccess())
        write(WindowStrip(state: strip, cardWidth: 250, isSwitcher: false, onChoose: { _ in }, onClose: { _ in }, onMinimize: { _ in })
            .frame(width: stripSize.width, height: stripSize.height), "19-dock-preview", folder)
        write(ClipboardPanelView(history: tools.clipboard, state: ClipboardPanelState(), onChoose: { _ in }, scrolls: false),
              "13-clipboard", folder)
        tools.isMonitorOn = false
        tools.isDisplaysOn = false
        tools.isMouseOn = false
        tools.isClipboardOn = false
        tools.isAwakeOn = false
    }

    private static func write<V: View>(_ view: V, _ name: String, _ folder: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.5
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return print("Failed: \(name)") }
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// Renders a 1024x1024 PNG for the app icon, with the standard macOS icon margin.
    static func renderIcon(to path: String) {
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 198).fill(Theme.logo)
            LogoGlyph().fill(Color.white).frame(width: 824, height: 824)
        }
        .frame(width: 824, height: 824)
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return print("Failed to create the icon") }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func save(_ peers: [Peer], _ prompt: PairingPrompt?, _ name: String, _ folder: String,
                             phone: PhoneSnapshot = PhoneSnapshot(), tab: PeerTab = .overview) {
        let model = AppModel()
        model.loadSnapshotState(peers, prompt: prompt, addresses: ["192.168.1.20"], phone: phone, tab: tab)
        let tall = name == "2-devices" || name == "5-overview"
        let view = MainView(model: model, animated: false).frame(width: 980, height: tall ? 1280 : 800)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.5
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return print("Failed: \(name)") }
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
#endif
