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
        save([fresh, phone], PairingPrompt(peerId: "demo-3", peerName: "New Phone", code: "", startedByPeer: false), "4b-pairing-enter", folder)
        save([fresh, phone], PairingPrompt(peerId: "demo-3", peerName: "New Phone", code: "", startedByPeer: false,
                                           error: "That code isn't right. Check the code on New Phone and try again."), "4c-pairing-wrong", folder)
        var demo = PhoneSnapshot()
        demo.apply(features: ["notifications", "sms", "calls", "contacts", "files", "screen", "control", "screentime"])
        demo.usage = UsageReport(since: 0, totalMs: 4 * 3_600_000 + 12 * 60_000, apps: [
            UsageApp(pkg: "chat", name: "WhatsApp", ms: 92 * 60_000), UsageApp(pkg: "video", name: "YouTube", ms: 71 * 60_000),
            UsageApp(pkg: "social", name: "Instagram", ms: 38 * 60_000), UsageApp(pkg: "maps", name: "Maps", ms: 9 * 60_000),
        ], unlocks: 47)
        demo.usageTime = Date()
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
        saveHistory(folder)
        saveCare(folder)
        var off = PhoneSnapshot()
        off.apply(features: [])
        save([phone], nil, "5-overview", folder, phone: demo, tab: .overview)
        save([phone], nil, "6-notifications", folder, phone: demo, tab: .notifications)
        save([phone], nil, "7-messages", folder, phone: demo, tab: .messages)
        save([phone], nil, "8-contacts", folder, phone: demo, tab: .contacts)
        save([phone], nil, "8b-contacts-search", folder, phone: demo, tab: .contacts) { $0.contactQuery = "0812" }
        save([phone], nil, "7b-messages-search", folder, phone: demo, tab: .messages) { $0.smsQuery = "leaving" }
        save([phone], nil, "7c-messages-new", folder, phone: demo, tab: .messages) { $0.smsThread = nil; $0.smsAddress = "a" }
        save([phone], nil, "7d-messages-picked", folder, phone: demo, tab: .messages) { $0.smsThread = nil; $0.smsAddress = "081200000002"; $0.smsDraft = "Halo Budi" }
        save([phone], nil, "5b-overview-commands", folder, phone: demo, tab: .overview) { $0.newCommandName = "Sleep" }
        save([phone], nil, "5c-overview-narrow", folder, phone: demo, tab: .overview)
        save([phone], nil, "7e-messages-narrow", folder, phone: demo, tab: .messages)
        save([phone], nil, "8c-contacts-narrow", folder, phone: demo, tab: .contacts)
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
        AdvancedLayout.shared.persists = false
        AdvancedLayout.shared.category = .overview
        write(AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 1300, alignment: .top)
            .background(Theme.ink).toggleStyle(.dyskSwitch).preferredColorScheme(.dark), "12-advanced", folder)
        AdvancedLayout.shared.category = .productivity
        write(AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 1900, alignment: .top)
            .background(Theme.ink).toggleStyle(.dyskSwitch).preferredColorScheme(.dark), "12b-advanced-productivity", folder)
        AdvancedLayout.shared.category = .screen
        write(AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 1900, alignment: .top)
            .background(Theme.ink).toggleStyle(.dyskSwitch).preferredColorScheme(.dark), "12c-advanced-screen", folder)
        AdvancedLayout.shared.category = .general
        let release = UpdateChecker.Release(version: "0.1.4", url: UpdateChecker.pageURL)
        UpdateChecker.versionOverride = "0.1.3"
        Shared.updates.showForSnapshot(release)
        write(VStack(alignment: .leading, spacing: 14) {
            UpdateBanner(release: release, updates: Shared.updates).frame(width: 236).padding(18)
            AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 1700, alignment: .top).clipped()
        }.frame(width: 708, height: 520, alignment: .top).background(Theme.ink).preferredColorScheme(.dark),
              "25-updates", folder)
        write(AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 1500, alignment: .top)
            .background(Theme.ink).toggleStyle(.dyskSwitch).preferredColorScheme(.dark), "29-advanced-top", folder)
        tools.isNotchOn = true
        AdvancedLayout.shared.category = .notch
        write(AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 2300, alignment: .top)
            .background(Theme.ink).toggleStyle(.dyskSwitch).preferredColorScheme(.dark), "30-advanced-notch-collapsed", folder)
        AdvancedLayout.shared.setOpen(["pages", "music", "pomodoro", "prayer", "weather", "battery", "screen"])
        write(AdvancedView(tools: tools, scrolls: false).frame(width: 708, height: 2300, alignment: .top)
            .background(Theme.ink).toggleStyle(.dyskSwitch).preferredColorScheme(.dark), "22-advanced-notch", folder)
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
        notch.showPeek("Sample Phone · 18% low")
        write(notchFrame(notch), "28-notch-phone-low", folder)
        let sampleNotice = NotificationItem(key: "n", app: "WhatsApp", title: "Ayu Lestari", text: "Fotonya sudah aku kirim ya, cek dulu", time: Int64(Date().timeIntervalSince1970 * 1000), color: 0x25D366)
        notch.showNotice(PhoneAlert(peerId: "demo", phone: "Sample Phone", item: sampleNotice))
        write(notchFrame(notch), "28b-notch-notice", folder)
        notch.hideNotice()
        notch.showCode(CodeNotice(code: "482915", source: "BCA", phone: "Sample Phone"))
        write(notchFrame(notch), "28c-notch-code", folder)
        notch.hideCode()
        // Prayer times and weather use their own model, so nothing is saved or fetched.
        let places = NotchModel(directory: directory, isInert: true)
        places.isOpen = true
        places.closedSize = CGSize(width: 179, height: 32)
        let jakarta = PrayerLocation(province: "DKI Jakarta", city: "Kota Jakarta")
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = jakarta.timeZone
        let days = (-1...1).compactMap { offset in
            zoned.date(byAdding: .day, value: offset, to: Date()).map {
                PrayerDay(date: PrayerSchedule.key($0, in: zoned), subuh: "04:09", dzuhur: "11:52", ashar: "15:12",
                          maghrib: "17:48", isya: "19:01")
            }
        }
        places.prayer.loadForSnapshot(location: jakarta, months: [PrayerMonth(location: jakarta, year: 2026, month: 11, days: days)])
        let bandung = WeatherPlace(name: "Kota Bandung", region: "Jawa Barat", latitude: -6.92, longitude: 107.6)
        places.weather.loadForSnapshot(place: bandung, report: WeatherReport(
            temperature: 31.6, code: 2, isDay: true,
            days: [.init(date: "2026-11-09", code: 53, high: 32.4, low: 21.4, rainChance: 92),
                   .init(date: "2026-11-10", code: 81, high: 31, low: 20.3, rainChance: 96),
                   .init(date: "2026-11-11", code: 95, high: 30.3, low: 20.2, rainChance: 100)],
            fetchedAt: Date()))
        places.todos.loadForSnapshot([("Revise the report", true), ("Reply to Dina", true), ("Post weekly update", false),
                                      ("Book the meeting room", false)], now: Date())
        places.page = .todo
        write(notchFrame(places), "31-notch-todo", folder)
        places.todos.isEditing = true
        write(notchFrame(places), "32-notch-todo-edit", folder)
        places.todos.isEditing = false
        let drinkTimes = [(9, 300), (10, 200), (11, 200), (12, 150), (13, 150), (14, 200), (15, 200)]
        places.water.settings.reminds = true
        places.water.loadForSnapshot(drinkTimes.compactMap { hour, ml in
            zoned.date(bySettingHour: hour, minute: 10, second: 0, of: Date()).map { WaterEntry(date: $0, ml: ml) }
        })
        places.page = .water
        write(notchFrame(places), "33-notch-water", folder)
        places.note.set("Alamat kantor: Jl. Merdeka No. 10, Lt. 3\nBeli: telur, susu, roti tawar\nWi-Fi tamu: dysk-guest / 4821-merdeka", at: Date().addingTimeInterval(-300))
        places.page = .note
        write(notchFrame(places), "33b-notch-note", folder)
        places.water.showsSettings = true
        write(notchFrame(places), "34-notch-water-settings", folder)
        places.water.showsSettings = false
        places.page = .prayer
        write(notchFrame(places), "26-notch-prayer", folder)
        places.page = .weather
        write(notchFrame(places), "27-notch-weather", folder)
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
        // The menu bar with more parts on, and its settings.
        let suite = "dysklink.snapshot.menubar"
        let menuDefaults = UserDefaults(suiteName: suite)!
        menuDefaults.removePersistentDomain(forName: suite)
        let menu = MenuBarLayout(defaults: menuDefaults)
        [.lock, .pomodoro, .note].forEach { menu.setShown($0, true) }
        menu.move(.note, by: -1)
        tools.notch.model.note.set("Wi-Fi tamu: dysk-guest / 4821-merdeka\nBeli: telur, susu")
        tools.isAwakeOn = true
        menu.setShown(.awake, true)
        write(MenuBarView(model: AppModel(), layout: menu, tools: tools).fixedSize(), "50-menubar-custom", folder)
        write(MenuBarSettings(layout: menu).frame(width: 640).padding(20).background(Theme.ink).preferredColorScheme(.dark),
              "51-menubar-settings", folder)
        // Every part turned off.
        MenuBarLayout.Section.allCases.forEach { menu.setShown($0, false) }
        write(MenuBarView(model: AppModel(), layout: menu, tools: tools).fixedSize(), "52-menubar-empty", folder)
        menuDefaults.removePersistentDomain(forName: suite)
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

    private static func saveCare(_ folder: String) {
        let home = URL(fileURLWithPath: "/Users/sample")
        let day: TimeInterval = 86_400
        func item(_ path: String, _ size: Int64, _ detail: String = "") -> CareItem {
            CareItem(url: home.appendingPathComponent(path), size: size, detail: detail, date: Date().addingTimeInterval(-40 * day))
        }
        func render(_ care: MacCareModel, _ name: String, height: CGFloat = 1100) {
            care.loadsOnShow = false
            write(MacCareView(care: care, scrolls: false).frame(width: 760, height: height, alignment: .top).clipped()
                .background(Theme.ink).toggleStyle(.dyskSwitch).preferredColorScheme(.dark), name, folder)
        }

        let cleaner = MacCareModel(home: home)
        cleaner.cleanGroups = [
            .caches: [item("Library/Caches/com.spotify.client", 2_400_000_000), item("Library/Caches/com.google.Chrome", 1_100_000_000),
                      item("Library/Caches/com.tinyspeck.slackmacgap", 640_000_000), item("Library/Caches/Homebrew", 420_000_000),
                      item("Library/Caches/org.videolan.vlc", 12_000_000), item("Library/Caches/com.figma.Desktop", 8_000_000)],
            .logs: [item("Library/Logs/JetBrains", 180_000_000)],
            .developer: [item("Library/Developer/Xcode/DerivedData", 9_800_000_000, "~/Library/Developer/Xcode"),
                         item(".gradle/caches", 3_200_000_000, "~/.gradle")],
            .installers: [item("Downloads/Docker.dmg", 610_000_000, "Added 3 months ago")],
            .oldDownloads: [item("Downloads/footage-2023.zip", 2_100_000_000, "Last used 7 months ago")],
        ]
        cleaner.cleanSelected = Set(cleaner.cleanGroups.filter { $0.key.selectedByDefault }.flatMap { $0.value.map(\.id) })
        cleaner.cleanScanned = true
        render(cleaner, "40-care-cleaner", height: 1500)

        let dups = MacCareModel(home: home)
        dups.tab = .duplicates
        dups.dupScanned = true
        dups.dupGroups = [
            DuplicateGroup(id: "a", size: 48_000_000, files: [item("Documents/Video/intro.mp4", 48_000_000), item("Downloads/intro.mp4", 48_000_000), item("Desktop/intro copy.mp4", 48_000_000)]),
            DuplicateGroup(id: "b", size: 3_200_000, files: [item("Documents/scan-ktp.pdf", 3_200_000), item("Downloads/scan-ktp (1).pdf", 3_200_000)]),
        ]
        dups.dupSelected = Set(dups.dupGroups.flatMap { $0.files.dropFirst().map(\.id) })
        render(dups, "41-care-duplicates")

        let apps = MacCareModel(home: home)
        apps.tab = .uninstall
        apps.apps = [
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Docker.app"), name: "Docker", bundleId: "com.docker.docker", version: "4.30", size: 2_100_000_000),
            InstalledApp(url: URL(fileURLWithPath: "/Applications/Figma.app"), name: "Figma", bundleId: "com.figma.Desktop", version: "124.1", size: 410_000_000),
            InstalledApp(url: URL(fileURLWithPath: "/Applications/VLC.app"), name: "VLC", bundleId: "org.videolan.vlc", version: "3.0.20", size: 160_000_000),
        ]
        render(apps, "42-care-apps", height: 700)

        let power = MacCareModel(home: home)
        power.tab = .battery
        // Sailing down from the limit: plugged in, with the charger input switched off.
        power.battery = BatteryReading(percent: 80, cycles: 163, designCycles: 1000, designMah: 4629, fullMah: 4421, voltageMv: 12401,
                                       amperageMa: -700, isCharging: false, isPluggedIn: false, isFull: false, adapterWatts: 30,
                                       minutesToFull: nil, minutesToEmpty: 198, temperatureC: 37.9, appleMaxCapacity: 97, condition: "Good")
        power.batteryHistory = (0..<40).map { i in
            BatteryDay(day: String(format: "2026-%02d-%02d", 9 + i / 30, 1 + i % 30), health: 100 - i / 12, fullMah: 4500, cycles: 120 + i)
        }
        ChargeControl.shared.preview(temperature: 37.9, lastCalibration: Date(timeIntervalSince1970: 1_775_606_400))
        PowerMonitor.shared.preview(battery: power.battery)
        render(power, "45-care-battery", height: 1150)
        // The same in the menu bar, as its own part.
        let batteryMenuSuite = "dysklink.snapshot.menubar.battery"
        let batteryMenuDefaults = UserDefaults(suiteName: batteryMenuSuite)!
        batteryMenuDefaults.removePersistentDomain(forName: batteryMenuSuite)
        let batteryMenu = MenuBarLayout(defaults: batteryMenuDefaults)
        let batteryParts: [MenuBarLayout.Section] = [.batteryLimit, .batteryStatus, .powerFlow, .energyApps, .batteryLevel, .batteryDetails, .powerUse]
        batteryParts.forEach { batteryMenu.setShown($0, true) }
        batteryMenu.setShown(.devices, false)
        batteryMenu.setShown(.login, false)
        write(MenuBarView(model: AppModel(), layout: batteryMenu, tools: Shared.tools).fixedSize(), "53-menubar-battery", folder)
        let chosen = apps.apps[0]
        apps.chosenApp = chosen
        apps.leftovers = [
            .init(item: item("Library/Containers/com.docker.docker", 1_300_000_000, "~/Library/Containers"), byId: true),
            .init(item: item("Library/Preferences/com.docker.docker.plist", 4_000, "~/Library/Preferences"), byId: true),
            .init(item: item("Library/Application Support/Docker", 22_000_000, "~/Library/Application Support"), byId: false),
        ]
        apps.leftoverSelected = Set(apps.leftovers.filter(\.byId).map(\.id))
        render(apps, "43-care-uninstall", height: 800)

        let startup = MacCareModel(home: home)
        startup.tab = .startup
        startup.startupItems = [
            StartupItem(url: home.appendingPathComponent("Library/LaunchAgents/com.spotify.webhelper.plist"), label: "com.spotify.webhelper",
                        program: "/Applications/Spotify.app/Contents/MacOS/SpotifyWebHelper", scope: .user, runsAtLoad: true, keepsAlive: false, isOff: false),
            StartupItem(url: home.appendingPathComponent("Library/LaunchAgents/com.google.keystone.agent.plist"), label: "com.google.keystone.agent",
                        program: "/Users/sample/Library/Google/GoogleSoftwareUpdate/Agent", scope: .user, runsAtLoad: true, keepsAlive: false, isOff: true),
            StartupItem(url: URL(fileURLWithPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist"), label: "com.docker.vmnetd",
                        program: "/Library/PrivilegedHelperTools/com.docker.vmnetd", scope: .daemon, runsAtLoad: true, keepsAlive: true, isOff: false),
        ]
        render(startup, "44-care-startup", height: 900)
    }

    private static func saveHistory(_ folder: String) {
        let now = Date()
        let records = [
            FileRecord(id: "1", device: "Sample Phone", name: "IMG_2041.jpg", size: 3_400_000, outgoing: false, date: now.addingTimeInterval(-300), ok: true),
            FileRecord(id: "2", device: "Sample Phone", name: "laporan-bulanan.pdf", size: 1_200_000, outgoing: true, date: now.addingTimeInterval(-3_600), ok: true),
            FileRecord(id: "3", device: "Second Phone", name: "rekaman.m4a", size: 8_100_000, outgoing: false, date: now.addingTimeInterval(-86_400), ok: false, detail: "Connection lost"),
        ]
        for (filter, name) in [(FileHistoryView.Filter.all, "20-history"), (.received, "21-history-received")] {
            let model = AppModel()
            model.loadSnapshotHistory(records, filter: filter)
            write(FileHistoryView(model: model, scrolls: false).frame(width: 760).background(Theme.ink), name, folder)
        }
    }

    private static func save(_ peers: [Peer], _ prompt: PairingPrompt?, _ name: String, _ folder: String,
                             phone: PhoneSnapshot = PhoneSnapshot(), tab: PeerTab = .overview,
                             setup: (AppModel) -> Void = { _ in }) {
        let model = AppModel()
        model.loadSnapshotState(peers, prompt: prompt, addresses: ["192.168.1.20"], phone: phone, tab: tab)
        setup(model)
        let tall = name == "2-devices" || name == "5-overview" || name == "5b-overview-commands"
        let narrow = name.hasSuffix("-narrow")
        let view = MainView(model: model, animated: false).frame(width: narrow ? 860 : 980, height: tall ? 1280 : 800)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.5
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return print("Failed: \(name)") }
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
#endif
