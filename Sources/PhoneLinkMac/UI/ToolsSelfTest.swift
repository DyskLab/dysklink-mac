#if DEBUG
import AppKit
import CoreText

/// Tests the Advanced tools without touching the real clipboard: `PhoneLinkMac --tools-selftest`.
@MainActor
enum ToolsSelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ passed: Bool) {
        print((passed ? "OK  " : "FAILED ") + name)
        if !passed { failures += 1 }
    }

    static func run() -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dysk-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        testHistory(folder)
        testDecisions()
        testAssertion()
        testMonitor()
        testRecognition()
        testHotKeys()
        testDisplayMessages()
        testBrightnessCurve()
        testShortcutsAndPasswords()
        testWheel()
        testWindowLogic()
        testNotch(folder)
        print(failures == 0 ? "TOOLS_SELFTEST ok" : "TOOLS_SELFTEST failed: \(failures)")
        return failures == 0
    }

    /// Runs the live tools for a few seconds in a real app loop, then turns them off.
    /// Only the debug build runs this, with its own settings and folder.
    static func smoke() {
        let tools = Shared.tools
        let mouseBefore = tools.mouse.debugState()
        tools.isNotchOn = true
        tools.isPreviewsOn = true
        tools.isDisplaysOn = true
        tools.isMouseOn = true
        tools.isClipboardOn = true
        let mouseDuring = tools.mouse.debugState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                print("displays:", tools.displays.displays.map { "\($0.name) \($0.method) \(Int($0.brightness * 100))% vol \($0.volume.map { String(Int($0 * 100)) } ?? "-")" })
                print("sound:", tools.displays.outputName, tools.displays.outputVolume ?? -1)
                print("mice:", tools.mouse.mouseNames)
                print("shortcut problems:", tools.shortcutProblem ?? "none", "/", tools.previews.shortcutProblem ?? "none")
                check("displays were found", !tools.displays.displays.isEmpty)
                check("the mouse setting changes while on", mouseDuring != mouseBefore)
                tools.isNotchOn = false
                tools.isPreviewsOn = false
                tools.isDisplaysOn = false
                tools.isMouseOn = false
                tools.isClipboardOn = false
                let mouseAfter = tools.mouse.debugState()
                print("mouse before:", mouseBefore)
                print("mouse during:", mouseDuring)
                print("mouse after: ", mouseAfter)
                check("the mouse setting goes back", mouseAfter == mouseBefore)
                print(failures == 0 ? "TOOLS_SMOKE ok" : "TOOLS_SMOKE failed: \(failures)")
                exit(failures == 0 ? 0 : 1)
            }
        }
    }

    private static func testHistory(_ folder: URL) {
        let board = NSPasteboard(name: NSPasteboard.Name("dysklink.selftest"))
        defer { board.releaseGlobally() }
        let history = ClipboardHistory(directory: folder)

        board.clearContents()
        board.setString("halo dunia", forType: .string)
        history.capture(from: board)
        check("text is recorded", history.entries.first?.text == "halo dunia")

        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("kata-sandi-rahasia", forType: .string)
        history.capture(from: board)
        check("concealed text is skipped", !history.entries.contains { $0.text == "kata-sandi-rahasia" })

        board.clearContents()
        board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        board.setString("sementara", forType: .string)
        history.capture(from: board)
        check("transient text is skipped", !history.entries.contains { $0.text == "sementara" })

        history.add(text: "   \n ")
        check("blank text is skipped", history.entries.count == 1)

        history.add(text: "kedua")
        history.add(text: "halo dunia")
        check("a repeat moves to the top", history.entries.map(\.text) == ["halo dunia", "kedua"])

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        board.clearContents()
        board.setData(png, forType: .png)
        history.capture(from: board)
        history.add(image: png)
        let images = history.entries.filter { $0.imageFile != nil }
        check("the same image is kept once", images.count == 1)
        let file = images.first.map { history.imageURL($0.imageFile!) }
        check("the image file exists", file.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        check("search finds text", history.matches("HALO").map(\.text) == ["halo dunia"])

        if let kedua = history.entries.first(where: { $0.text == "kedua" }) { history.togglePin(kedua) }
        check("pinned entries sort first", history.matches("").first?.text == "kedua")

        for index in 0..<(ClipboardHistory.maxEntries + 20) { history.add(text: "isi \(index)") }
        check("the limit holds", history.entries.filter { !$0.isPinned }.count == ClipboardHistory.maxEntries)
        check("a pinned entry survives the limit", history.entries.contains { $0.text == "kedua" })
        check("trimmed images are deleted", file.map { !FileManager.default.fileExists(atPath: $0.path) } == true)

        history.saveNow()
        let reloaded = ClipboardHistory(directory: folder)
        check("history reloads from disk", reloaded.entries == history.entries)
        let store = folder.appendingPathComponent("clipboard-history.json").path
        let mode = (try? FileManager.default.attributesOfItem(atPath: store))?[.posixPermissions] as? Int
        check("the history file is private to this user", mode == 0o600)

        reloaded.clearUnpinned()
        check("clearing keeps pinned entries", reloaded.entries.map(\.text) == ["kedua"])
    }

    private static func testDecisions() {
        let now = Date()
        let battery = PowerStatus(percent: 15, isCharging: false, isOnBattery: true)
        let mains = PowerStatus(percent: 15, isCharging: true, isOnBattery: false)
        func decide(_ endsAt: Date?, _ power: PowerStatus, _ onlyOnPower: Bool, _ below: Int) -> AwakeDecision {
            AwakeDecision.decide(now: now, endsAt: endsAt, power: power, onlyOnPower: onlyOnPower, stopBelow: below)
        }
        check("holds with no limits", decide(nil, battery, false, 0) == .hold)
        check("stops when time is up", decide(now.addingTimeInterval(-1), mains, false, 0) == .stop("Time is up."))
        check("holds before the end", decide(now.addingTimeInterval(60), mains, false, 0) == .hold)
        check("stops on low battery", decide(nil, battery, false, 20) == .stop("Stopped because the battery fell below 20%."))
        check("low battery on mains keeps going", decide(nil, mains, false, 20) == .hold)
        check("pauses on battery when asked", decide(nil, battery, true, 0) == .pause)
        check("keeps going before the idle limit", AwakeDecision.decide(now: now, endsAt: nil, power: mains, onlyOnPower: false, stopBelow: 0, idleSeconds: 599, idleLimitMinutes: 10) == .hold)
        check("stops at the idle limit", AwakeDecision.decide(now: now, endsAt: nil, power: mains, onlyOnPower: false, stopBelow: 0, idleSeconds: 600, idleLimitMinutes: 10) == .stop("Stopped after 10 minutes with no activity."))
        check("no idle limit ignores idle time", AwakeDecision.decide(now: now, endsAt: nil, power: mains, onlyOnPower: false, stopBelow: 0, idleSeconds: 99_999, idleLimitMinutes: 0) == .hold)
        let awake = KeepAwake()
        let saved = (awake.minutes, awake.customHours, awake.customMinutes)
        awake.minutes = KeepAwake.customChoice
        awake.customHours = 2
        awake.customMinutes = 45
        check("a custom time adds up", awake.sessionMinutes == 165 && awake.canStart)
        awake.customHours = 0
        awake.customMinutes = 0
        check("a custom time of zero can't start", !awake.canStart)
        awake.customHours = 9999
        check("a custom time has an upper limit", awake.sessionMinutes == KeepAwake.longestMinutes)
        (awake.minutes, awake.customHours, awake.customMinutes) = saved
    }

    private static func assertionListed() -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Only this process counts, because the installed app may be keeping the Mac awake at the same time.
        let mine = "pid \(getpid())("
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .contains { $0.contains(mine) && $0.contains(KeepAwake.assertionName) }
    }

    private static func testAssertion() {
        let awake = KeepAwake()
        let saved = (awake.minutes, awake.onlyOnPower, awake.stopBelow)
        defer { (awake.minutes, awake.onlyOnPower, awake.stopBelow) = saved }
        awake.onlyOnPower = false
        awake.stopBelow = 0
        awake.minutes = 15
        awake.start()
        check("macOS lists the assertion while active", awake.holdsAssertion && assertionListed())
        check("the session has an end", awake.endsAt != nil)
        awake.stop()
        check("the assertion is released on stop", !awake.holdsAssertion && !assertionListed())
    }

    private static func testMonitor() {
        let monitor = SystemMonitor()
        monitor.start()
        Thread.sleep(forTimeInterval: 0.3)
        monitor.refresh()
        let sample = monitor.sample
        check("CPU is in range", (0...1).contains(sample.cpu))
        check("memory is plausible", sample.memoryUsed > 0 && sample.memoryUsed <= sample.memoryTotal)
        check("disk is plausible", sample.diskFree > 0 && sample.diskFree < sample.diskTotal)
        check("rates are not negative", sample.downloadRate >= 0 && sample.uploadRate >= 0)
        monitor.stop()
        let rows = SystemMonitor.parseProcesses("  12  3,5  2048 Some App\nnonsense\n 9 1.0 1024 launchd\n", limit: 5)
        check("process lines parse", rows == [
            ProcessUsage(pid: 12, name: "Some App", cpu: 3.5, memory: 2_097_152),
            ProcessUsage(pid: 9, name: "launchd", cpu: 1, memory: 1_048_576),
        ])
    }

    private static func testRecognition() {
        let width = 900, height = 140
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return check("recognition image", false) }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Selamat pagi DyskLink 2048", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: 30, y: 45)
        CTLineDraw(line, context)
        let text = context.makeImage().map(TextRecognizer.recognize) ?? ""
        print("    recognized: \(text)")
        check("text is recognized from an image", text.contains("Selamat pagi") && text.contains("2048"))
    }

    private static func testDisplayMessages() {
        check("the DDC write message is correct", DDC.writePacket(code: 0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x84 ^ 0x03 ^ 0x10 ^ 0x32 ^ 0x6E ^ 0x51])
        check("the DDC read message is correct", DDC.readPacket(code: 0x62) == [0x82, 0x01, 0x62, 0x82 ^ 0x01 ^ 0x62 ^ 0x6E ^ 0x51])
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x2D, 0xAA, 0x00]
        check("a DDC reply is read", DDC.parseReply(reply, code: 0x10).map { $0.current == 45 && $0.maximum == 100 } == true)
        check("a reply about another setting is refused", DDC.parseReply(reply, code: 0x62) == nil)
        var failed = reply
        failed[3] = 0x01
        check("a failed DDC reply is refused", DDC.parseReply(failed, code: 0x10) == nil)
        check("an empty reply is refused", DDC.parseReply([UInt8](repeating: 0, count: 12), code: 0x10) == nil)
    }

    private static func testWheel() {
        check("the wheel is unchanged by default", WheelSettings().transform(4) == 4)
        check("reverse flips the wheel", WheelSettings(reverses: true).transform(4) == -4)
        check("fixed lines ignore wheel speed", WheelSettings(usesFixedLines: true, lines: 5).transform(-9) == -5)
        check("fixed and reverse combine", WheelSettings(reverses: true, usesFixedLines: true, lines: 2).transform(9) == -2)
        check("no movement stays still", WheelSettings(reverses: true).transform(0) == 0)
        check("Command alone matches", ScrollModifier.exact(.maskCommand) == .command)
        check("Option + Control is its own row", ScrollModifier.exact([.maskAlternate, .maskControl]) == .optionControl)
        check("other keys held don't change the match", ScrollModifier.exact([.maskShift, .maskAlphaShift]) == .shift)
        check("Command + Shift has no row", ScrollModifier.exact([.maskCommand, .maskShift]) == nil)
        check("no modifier has no row", ScrollModifier.exact([]) == nil)
        let mapped = WheelSettings(actions: [.command: .zoom, .shift: .sideways])
        check("an action is found by modifier", mapped.action(for: .maskCommand) == .zoom && mapped.action(for: .maskShift) == .sideways)
        check("an unset modifier is normal", mapped.action(for: .maskControl) == .standard)
        check("an action turns on the wheel handling", mapped.isActive && !WheelSettings().isActive)
        check("slower scrolling still moves", WheelSettings.scaled(1, by: 0.34) == 1 && WheelSettings.scaled(-1, by: 0.34) == -1)
        check("faster scrolling multiplies", WheelSettings.scaled(2, by: 3) == 6)
        check("wheel direction follows natural scrolling", WheelSettings.direction(of: -3, natural: true) == 1 && WheelSettings.direction(of: 3, natural: false) == 1)
    }

    private static func testWindowLogic() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = CGSize(width: 300, height: 200)
        let bottom = WindowCatalog.placement(panel: panel, icon: CGRect(x: 700, y: 4, width: 60, height: 60), screen: screen)
        check("a bottom Dock preview sits above the icon", bottom == CGPoint(x: 580, y: 74))
        let edge = WindowCatalog.placement(panel: panel, icon: CGRect(x: 5, y: 4, width: 60, height: 60), screen: screen)
        check("a preview stays on screen", edge.x == 8)
        let left = WindowCatalog.placement(panel: panel, icon: CGRect(x: 4, y: 400, width: 60, height: 60), screen: screen)
        check("a left Dock preview sits beside the icon", left == CGPoint(x: 74, y: 330))
        let right = WindowCatalog.placement(panel: panel, icon: CGRect(x: 1376, y: 400, width: 60, height: 60), screen: screen)
        check("a right Dock preview sits beside the icon", right == CGPoint(x: 1066, y: 330))
        let rows: [(item: Int, id: CGWindowID, isMinimized: Bool)] = [(1, 10, true), (2, 20, false), (3, 30, false), (4, 40, false)]
        let sorted = WindowCatalog.sortWindows(rows, order: [30, 20]).map(\.item)
        check("windows sort front to back, minimized last", sorted == [3, 2, 4, 1])
        let tab: Int64 = 48, letter: Int64 = 0
        check("Option + Tab opens the switcher", SwitcherKeys.result(keyCode: tab, flags: .maskAlternate, isOpen: false)
            == .init(command: .forward, swallows: true))
        check("Option + Tab moves on while open", SwitcherKeys.result(keyCode: tab, flags: .maskAlternate, isOpen: true)
            == .init(command: .forward, swallows: true))
        check("Option + Shift + Tab goes back while open", SwitcherKeys.result(keyCode: tab, flags: [.maskAlternate, .maskShift], isOpen: true)
            == .init(command: .back, swallows: true))
        check("Option + Shift + Tab stays with the app while closed", SwitcherKeys.result(keyCode: tab, flags: [.maskAlternate, .maskShift], isOpen: false) == .pass)
        check("Tab alone stays with the app", SwitcherKeys.result(keyCode: tab, flags: [], isOpen: false) == .pass)
        check("Command + Option + Tab stays with the system", SwitcherKeys.result(keyCode: tab, flags: [.maskAlternate, .maskCommand], isOpen: false) == .pass)
        check("typing stays with the app while closed", SwitcherKeys.result(keyCode: letter, flags: .maskAlternate, isOpen: false) == .pass)
        check("typing is held back while open", SwitcherKeys.result(keyCode: letter, flags: .maskAlternate, isOpen: true)
            == .init(command: nil, swallows: true))
        check("Escape cancels the switcher", SwitcherKeys.result(keyCode: 53, flags: .maskAlternate, isOpen: true).command == .cancel)
        check("Return chooses in the switcher", SwitcherKeys.result(keyCode: 36, flags: .maskAlternate, isOpen: true).command == .commit)
        check("Escape stays with the app while closed", SwitcherKeys.result(keyCode: 53, flags: [], isOpen: false) == .pass)
        let icon = CGRect(x: 700, y: 4, width: 60, height: 60)
        let box = CGRect(x: 580, y: 74, width: 300, height: 200)
        check("the preview stays on the icon", WindowCatalog.keepsPreview(pointer: CGPoint(x: 730, y: 30), icon: icon, panel: box))
        check("the preview stays on the panel", WindowCatalog.keepsPreview(pointer: CGPoint(x: 600, y: 200), icon: icon, panel: box))
        check("the preview stays while crossing the gap", WindowCatalog.keepsPreview(pointer: CGPoint(x: 730, y: 69), icon: icon, panel: box))
        check("the preview leaves beside the gap", !WindowCatalog.keepsPreview(pointer: CGPoint(x: 600, y: 69), icon: icon, panel: box))
        check("the preview leaves on the desktop", !WindowCatalog.keepsPreview(pointer: CGPoint(x: 200, y: 500), icon: icon, panel: box))
        check("the preview leaves on the next icon", !WindowCatalog.keepsPreview(pointer: CGPoint(x: 800, y: 30), icon: icon, panel: box))
        let one = WindowStrip.size(count: 1, cardWidth: 250, isSwitcher: false, showsHint: false)
        check("one card has a fixed size", one == CGSize(width: 288, height: 244))
        check("a card count sets the width", WindowStrip.size(count: 2, cardWidth: 250, isSwitcher: false, showsHint: false).width == 562)
        let five = WindowStrip.size(count: 5, cardWidth: 250, isSwitcher: false, showsHint: false)
        check("a fifth card starts a new row", five == CGSize(width: 1110, height: 448))
    }

    private static func testNotch(_ folder: URL) {
        let frame = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let notched = NotchGeometry.make(frame: frame, safeTop: 37,
                                         leftArea: CGRect(x: 0, y: 919, width: 640, height: 37),
                                         rightArea: CGRect(x: 830, y: 919, width: 640, height: 37))
        check("the notch is measured from the screen", notched.hasNotch && notched.closed == CGRect(x: 640, y: 919, width: 190, height: 37))
        check("the trigger covers the notch", notched.trigger().contains(CGPoint(x: 735, y: 955)))
        check("the trigger leaves the menu bar alone", !notched.trigger().contains(CGPoint(x: 300, y: 940)))
        let plain = NotchGeometry.make(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), safeTop: 0, leftArea: nil, rightArea: nil)
        check("a screen with no notch gets a thin bar", !plain.hasNotch && plain.closed.height == 6 && plain.closed.midX == 960)

        let file = folder.appendingPathComponent("shelf-test.txt")
        try? "isi".write(to: file, atomically: true, encoding: .utf8)
        let added = ShelfStore.adding([file, file, URL(string: "https://example.com")!], to: [])
        check("the shelf keeps one copy of a file and no web links", added.count == 1)
        let store = folder.appendingPathComponent("shelf.json")
        ShelfStore.save(added + [ShelfItem(path: "/tidak/ada/berkas.txt")], to: store)
        check("the shelf forgets files that are gone", ShelfStore.load(from: store) == added)
        check("the shelf doesn't touch the file", FileManager.default.fileExists(atPath: file.path))

        let model = NotchModel(directory: folder)
        model.hasNotch = true
        model.closedSize = CGSize(width: 179, height: 32)
        check("the menu starts below the camera", NotchModel.contentTop(hasNotch: true, notchHeight: 32) > 32)
        check("a camera makes the panel taller by its height", model.openSize.height == 272)
        model.hasNotch = false
        check("no camera needs no extra room", model.openSize.height == 236)
        let wasHiding = model.hidesBar
        model.closedSize = CGSize(width: 170, height: 6)
        model.hidesBar = true
        check("the bar disappears on a screen with no camera", model.closedHeight(statusHeight: 24) == 0)
        model.hidesBar = false
        check("the bar can stay visible", model.closedHeight(statusHeight: 24) == 6)
        model.hasNotch = true
        model.hidesBar = true
        check("the option doesn't affect a camera screen", model.closedHeight(statusHeight: 24) == 6)
        model.hasNotch = false
        model.startFocus(minutes: 25)
        check("a running timer still shows with the bar hidden", model.closedHeight(statusHeight: 24) == 30)
        model.stopFocus()
        model.hidesBar = wasHiding
        check("focus starts idle", !model.isFocusing && model.focusText == "25:00")
        model.startFocus(minutes: 25)
        check("focus counts down", model.isFocusing && (model.focusText == "25:00" || model.focusText == "24:59"))
        model.stopFocus()
        check("focus stops", !model.isFocusing)
    }

    private static func testBrightnessCurve() {
        let curve = BrightnessCurve.extended
        check("the top of the slider is full backlight", curve.backlight(1) == 1 && curve.picture(1) == 1)
        check("the normal minimum has no extra dimming", curve.backlight(0.25) == 0 && curve.picture(0.25) == 1)
        check("below the minimum only the picture dims", curve.backlight(0.1) == 0 && curve.picture(0.1) < 1)
        check("the bottom never goes fully black", curve.picture(0) == BrightnessCurve.floor)
        check("a backlight value maps back to the slider", abs(curve.backlight(curve.slider(backlight: 0.5)) - 0.5) < 0.0001)
        let plain = BrightnessCurve.normal
        check("without extra dimming the slider is the backlight", plain.backlight(0.4) == 0.4 && plain.picture(0) == 1)
    }

    private static func testShortcutsAndPasswords() {
        let combo = KeyCombo(keyCode: 9, modifiers: KeyCombo.carbon([.control, .command]))
        check("a shortcut label reads well", combo.label == "⌃⌘V" && combo == .historyDefault)
        check("a letter alone is refused", !KeyCombo(keyCode: 9, modifiers: 0).isUsable)
        check("Shift and a letter is refused", !KeyCombo(keyCode: 9, modifiers: KeyCombo.carbon(.shift)).isUsable)
        check("Option and a letter is allowed", KeyCombo(keyCode: 9, modifiers: KeyCombo.carbon(.option)).isUsable)
        check("a function key alone is allowed", KeyCombo(keyCode: 96, modifiers: 0).isUsable)
        for sample in ["Kucing#2024", "Abc12345", "p@ssW0rd!", "x7$kQ9!mZ"] {
            check("looks like a password: \(sample)", PasswordFilter.looksLikePassword(sample))
        }
        for sample in ["Meeting moved to 3 PM", "https://Example.com/A1", "budi.Santoso1@mail.com", "/Users/Budi/File1.txt",
                       "550e8400-e29b-41d4-a716-446655440000", "kucing", "halodunia", "12345678", "Ab1!"] {
            check("not a password: \(sample)", !PasswordFilter.looksLikePassword(sample))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dysk-pw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = ClipboardHistory(directory: folder)
        let wasIgnoring = history.ignoresPasswords
        defer { history.ignoresPasswords = wasIgnoring }
        let board = NSPasteboard(name: NSPasteboard.Name("dysklink.selftest.pw"))
        defer { board.releaseGlobally() }
        func copy(_ text: String, from app: String? = nil) {
            board.clearContents()
            board.setString(text, forType: .string)
            history.capture(from: board, frontApp: app)
        }
        history.ignoresPasswords = true
        copy("Kucing#2024")
        check("a password-like copy is skipped", history.entries.isEmpty)
        copy("teks biasa dari aplikasi sandi", from: "com.bitwarden.desktop")
        check("anything from a password app is skipped", history.entries.isEmpty)
        copy("teks biasa", from: "com.apple.TextEdit")
        check("normal text is still recorded", history.entries.count == 1)
        history.ignoresPasswords = false
        copy("Kucing#2024")
        check("turning it off records it", history.passwordLikeCount == 1)
        history.removePasswordLike()
        check("saved password-like items can be removed", history.passwordLikeCount == 0 && history.entries.count == 1)
    }

    private static func testHotKeys() {
        let registered = HotKeys.register(id: 99, keyCode: 111) {}
        check("a global shortcut registers", registered)
        HotKeys.remove(id: 99)
    }
}
#endif
