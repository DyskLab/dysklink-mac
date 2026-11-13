import PDFKit
#if DEBUG
import AppKit
import Compression
import CoreText
import SQLite3

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
        testPrayerAndWeather()
        testRecognition()
        testHotKeys()
        testDisplayMessages()
        testBrightnessCurve()
        testShortcutsAndPasswords()
        testWheel()
        testWindowLogic()
        testLayout()
        testLauncher()
        testClipboardImport()
        testMacSync()
        testShortcuts()
        testLauncherWeb()
        testPhoneSearch()
        testNotificationImages()
        testFastFrames()
        testTerminal()
        testNotch(folder)
        testMacCare(folder)
        testOneTimeCode()
        testBattery()
        testPowerSplit()
        testMenuBarLayout()
        testGameKeys()
        testGameKeysMore()
        testGameKeysTiming()
        testChargePolicy()
        testPlayerDetails()
        testPowerSettings()
        testHeldByMacOS()
        testAdaptiveQuality()
        testMouseLook()
        testSameFile()
        testSearchablePDF()
        testLayoutCommands()
        testEmojiExtras()
        testMenuAnchor()
        testGallerySnapshot()
        testAudioPCM()
        testSharedInputEdges()
        testCoreSafety()
        testProcessRunner()
        testFirewallCheck()
        CpaceSelfTest.run(check)
        BinaryFrameSelfTest.run(check)
        // A laptop with a monitor above it, offset to the left, like a common desk.
        let laptop = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let monitor = CGRect(x: -204, y: -1080, width: 1920, height: 1080)
        let up = DeviceInput.keepOnDisplays(CGPoint(x: 700, y: -40), from: CGPoint(x: 700, y: 10), displays: [laptop, monitor])
        check("pointer moves up onto the monitor above", up == CGPoint(x: 700, y: -40))
        let gap = DeviceInput.keepOnDisplays(CGPoint(x: 1600, y: 500), from: CGPoint(x: 1460, y: 500), displays: [laptop, monitor])
        check("pointer stops at the edge beside a gap", gap == CGPoint(x: 1469, y: 500))
        let left = DeviceInput.keepOnDisplays(CGPoint(x: -150, y: -500), from: CGPoint(x: 10, y: -500), displays: [laptop, monitor])
        check("pointer reaches the monitor's left part", left == CGPoint(x: -150, y: -500))
        let phoneSize = SecondDisplay.size(requested: ScreenInfo(width: 1120, height: 504))
        check("second display grows to 600 points tall", phoneSize?.height == 600 && phoneSize?.width == 1332)
        check("second display keeps a fitting size", SecondDisplay.size(requested: ScreenInfo(width: 1600, height: 720))! == (1600, 720))
        check("larger text keeps a small 1x size", SecondDisplay.size(requested: ScreenInfo(width: 1000, height: 450), large: true)! == (1000, 450)
            && SecondDisplay.size(requested: ScreenInfo(width: 600, height: 270), large: true)! == (800, 360))
        check("second display works upright", SecondDisplay.size(requested: ScreenInfo(width: 504, height: 1120))! == (600, 1332))
        check("second display refuses odd shapes", SecondDisplay.size(requested: ScreenInfo(width: 500, height: 2100)) == nil
            && SecondDisplay.size(requested: ScreenInfo(width: 3000, height: 600)) == nil)
        let adbList = "List of devices attached\nR58N91ABCDE        device usb:1-1 product:demo model:Demo_Phone device:demo transport_id:3\nZY22 unauthorized usb:1-2 transport_id:4\n\n"
        let devices = UsbBridge.parseDevices(adbList)
        check("adb devices parsed", devices.count == 2 && devices[0].serial == "R58N91ABCDE" && devices[0].state == "device"
            && devices[0].model == "Demo Phone" && devices[1].state == "unauthorized")
        check("adb server noise skipped", UsbBridge.parseDevices("* daemon not running; starting now at tcp:5037\n* daemon started successfully\nList of devices attached\n").isEmpty)
        check("adb reverse found", UsbBridge.hasReverse("UsbFfs tcp:47823 tcp:47821\n", port: 47821)
            && !UsbBridge.hasReverse("UsbFfs tcp:47823 tcp:50000\n", port: 47821))
        check("wake on lan from pmset", LocalDevice.parseWake(" displaysleep 10\n womp                 1\n") == true
              && LocalDevice.parseWake(" womp 0") == false && LocalDevice.parseWake("") == nil
              && LocalDevice.parseWake("Battery Power:\n womp 0\nAC Power:\n womp 1\n") == true
              && LocalDevice.parseWake("Battery Power:\n womp 1\nAC Power:\n womp 0\n") == false)
        check("ether from ifconfig", LocalDevice.parseEther("en0: flags=8863<UP>\n\tether C6:3A:1E:42:7F:A0\n\tinet 192.168.1.4") == "c6:3a:1e:42:7f:a0")
        // The main thread only reads the cache, so it's filled off main first, as the app does at start.
        let warmed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = LocalDevice.wakeForNetwork; _ = LocalDevice.wake; warmed.signal() }
        check("local device warms up off main", warmed.wait(timeout: .now() + 5) == .success)
        let mainStart = Date()
        _ = LocalDevice.etherAddress("en-not-there")
        check("local device never runs ifconfig on main", Date().timeIntervalSince(mainStart) < 0.05)
        if let wake = LocalDevice.wake {
            print("WAKE live \(wake.macs) \(wake.broadcast) enabled=\(String(describing: LocalDevice.wakeForNetwork))")
            check("wake address looks right", wake.macs.allSatisfy { $0.split(separator: ":").count == 6 && $0 != "02:00:00:00:00:00" } && wake.broadcast.hasSuffix(".255"))
        }
        let note = NotchModel(directory: folder, isInert: true)
        NotchSync.apply(NotchAction(kind: "note.set", id: nil, text: "Jl. Merdeka 10"), to: note)
        let noteState = NotchSync.state(of: note)
        check("note from the phone", noteState.note == "Jl. Merdeka 10" && noteState.noteTime != nil)
        note.note.set(String(repeating: "a", count: 5000))
        check("note is capped", note.note.text.count == QuickNoteModel.maxLength)
        check("autolock gone", AutoLock.shouldLock(phoneConnected: false, screenLocked: false, macOnline: true))
        check("autolock back", !AutoLock.shouldLock(phoneConnected: true, screenLocked: false, macOnline: true))
        check("autolock already locked", !AutoLock.shouldLock(phoneConnected: false, screenLocked: true, macOnline: true))
        check("autolock mac offline", !AutoLock.shouldLock(phoneConnected: false, screenLocked: false, macOnline: false))
        check("autolock label", AutoLock.label(30) == "30 sec" && AutoLock.label(120) == "2 min")
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

    private static func testAudioPCM() {
        let pcm = AudioPCM.int16(channels: [[0, 0.5, -1, 2], [1, -0.5, 0, -2]])
        check("stereo interleaves to 16-bit", pcm.count == 16)
        let back = AudioPCM.floats(pcm, channels: 2)
        check("16-bit comes back close", abs(back[0][1] - 0.5) < 0.001 && abs(back[1][1] + 0.5) < 0.001)
        check("loud samples are clipped", abs(back[0][3] - 1) < 0.001 && abs(back[1][3] + 1) < 0.001)
        check("mono goes to both sides", AudioPCM.floats(AudioPCM.int16(channels: [[0.25]]), channels: 2).map { $0[0] }.allSatisfy { abs($0 - 0.25) < 0.001 })
        check("a chunk is 40 ms", AudioPCM.chunkBytes == 7_680)
        let notch = NotchModel(directory: FileManager.default.temporaryDirectory.appendingPathComponent("dysklink-audio-notch"), isInert: true)
        notch.audioListeners = ["Pixel"]
        check("a listening phone shows under the notch", notch.isWatched && notch.watchText == "Pixel is listening")
        notch.screenWatchers = ["Pixel"]
        check("viewing is shown before listening", notch.watchText == "Pixel is viewing")
    }

    /// Pairing limits, numbers from another Mac, and what decides a device's kind.
    /// The runner must never spin the run loop, never stall on a full pipe, and stop tools that hang.
    private static func testProcessRunner() {
        let basic = ProcessRunner.run("/bin/sh", ["-c", "echo hello; echo oops >&2; exit 3"], errorOutput: .capture)
        check("process runner returns output and status", basic?.text == "hello\n" && basic?.errorText == "oops\n"
              && basic?.status == 3 && basic?.timedOut == false && basic?.succeeded == false)
        let merged = ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2"], errorOutput: .merge)
        check("process runner merges errors", merged?.text.contains("out") == true && merged?.text.contains("err") == true)
        check("process runner reports a tool that can't start", ProcessRunner.run("/nonexistent/dysklink-tool") == nil)
        let slowStart = Date()
        let slow = ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3)
        let slowTook = Date().timeIntervalSince(slowStart)
        check("process runner times out and stops the tool", slow?.timedOut == true && slow?.status != 0 && slowTook < 2)
        let big = ProcessRunner.run("/bin/sh", ["-c", "yes a | head -c 300000; yes b | head -c 200000 >&2"],
                                    timeout: 10, errorOutput: .capture)
        check("process runner reads more than a pipe holds", big?.output.count == 300_000 && big?.errorOutput.count == 200_000
              && big?.timedOut == false && big?.status == 0)
        let childStart = Date()
        let child = ProcessRunner.run("/bin/sh", ["-c", "sleep 5 & echo done"], timeout: 4)
        check("process runner returns while a child holds the pipe", child?.text == "done\n" && child?.status == 0
              && Date().timeIntervalSince(childStart) < 3)

        // From the main thread with a timer and a queued block waiting: neither may run during the call.
        final class Calls: @unchecked Sendable {
            var depth = 0, deepest = 0, ranInside = false, count = 0
        }
        let calls = Calls()
        let call = {
            if calls.depth > 0 { calls.ranInside = true }
            calls.depth += 1
            calls.deepest = max(calls.deepest, calls.depth)
            calls.count += 1
            _ = ProcessRunner.run("/bin/sleep", ["0.2"], timeout: 2)
            calls.depth -= 1
        }
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in call() }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.async { call() }
        call()
        let alone = calls.count == 1
        let drained = Date().addingTimeInterval(1.5)
        while calls.count < 3, Date() < drained { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check("process runner on main lets nothing re-enter", alone && !calls.ranInside && calls.deepest == 1 && calls.count == 3)
    }

    private static func testCoreSafety() {
        check("key codes 0...127 pass", RemoteLimits.keyCode(0) == 0 && RemoteLimits.keyCode(127) == 127)
        check("key codes outside 0...127 are refused", RemoteLimits.keyCode(70000) == nil && RemoteLimits.keyCode(-1) == nil && RemoteLimits.keyCode(128) == nil)
        check("buttons 0...31 pass, others don't", RemoteLimits.button(31) == 31 && RemoteLimits.button(32) == nil && RemoteLimits.button(-1) == nil)
        check("huge movement is clamped", RemoteLimits.delta(1e12, limit: 4000) == 4000 && RemoteLimits.delta(-1e12, limit: 4000) == -4000)
        check("NaN and infinity are refused", RemoteLimits.delta(.nan, limit: 10) == nil && RemoteLimits.delta(.infinity, limit: 10) == nil)
        check("a missing delta is zero", RemoteLimits.delta(nil, limit: 10) == 0)
        check("edge fraction is kept in 0...1", RemoteLimits.fraction(7) == 1 && RemoteLimits.fraction(-3) == 0 && RemoteLimits.fraction(.nan) == 0.5)
        check("a bad key event is dropped", RemoteLimits.sanitize(RemoteEvent(kind: "key", keyCode: 70000, keyDown: true)) == nil)
        check("a bad button event is dropped", RemoteLimits.sanitize(RemoteEvent(kind: "down", button: -1)) == nil)
        check("a huge scroll is clamped", RemoteLimits.sanitize(RemoteEvent(kind: "scroll", dx: 1e12, dy: -5))?.dx == RemoteLimits.maxScroll)
        check("an unknown event kind is dropped", RemoteLimits.sanitize(RemoteEvent(kind: "teleport")) == nil)

        check("pairing cooldown doubles", PairingGuard.cooldown(lockouts: 1) == 60 && PairingGuard.cooldown(lockouts: 2) == 120
            && PairingGuard.cooldown(lockouts: 3) == 240)
        check("pairing cooldown stops at an hour", PairingGuard.cooldown(lockouts: 7) == 3600 && PairingGuard.cooldown(lockouts: 500) == 3600)
        var guardian = PairingGuard()
        let start = Date(timeIntervalSince1970: 1_000_000)
        check("a first request is allowed", guardian.admit("a", now: start) == .allowed)
        check("a quick repeat is ignored", guardian.admit("a", now: start.addingTimeInterval(1)) == .ignored)
        let locked = (1...5).map { guardian.wrongCode("a", now: start.addingTimeInterval(Double($0))) }
        check("the fifth wrong code locks out", locked == [false, false, false, false, true])
        if case .refused = guardian.admit("a", now: start.addingTimeInterval(30)) { check("locked out device is refused", true) }
        else { check("locked out device is refused", false) }
        check("another device can still ask", guardian.admit("b", now: start.addingTimeInterval(30)) == .allowed)
        check("allowed again after 60 s", guardian.admit("a", now: start.addingTimeInterval(66)) == .allowed)
        _ = (1...5).map { guardian.wrongCode("a", now: start.addingTimeInterval(70 + Double($0))) }
        check("the second lockout is 120 s", guardian.admit("a", now: start.addingTimeInterval(75 + 100)) != .allowed
            && guardian.admit("a", now: start.addingTimeInterval(75 + 121)) == .allowed)
        guardian.succeeded("a")
        check("the right code clears the count", guardian.waiting("a", now: start.addingTimeInterval(200)) == nil)
        var crowd = PairingGuard()
        check("new certificates can't each start a prompt at once", crowd.admit("n1", now: start) == .allowed
              && crowd.admit("n2", now: start.addingTimeInterval(0.5)) == .deferred(1.5)
              && crowd.admit("n3", now: start.addingTimeInterval(1.9)) != .allowed
              && crowd.admit("n4", now: start.addingTimeInterval(2.1)) == .allowed)
        crowd.succeeded("n4")
        check("after a pairing that worked the next device may ask at once", crowd.admit("n5", now: start.addingTimeInterval(2.2)) == .allowed)
        check("connections that aren't paired are capped per address",
              InboundLimits.admits(address: "10.0.0.5", isLoopback: false, unpaired: ["10.0.0.5"])
              && !InboundLimits.admits(address: "10.0.0.5", isLoopback: false, unpaired: ["10.0.0.5", "10.0.0.5"])
              && InboundLimits.admits(address: "10.0.0.6", isLoopback: false, unpaired: ["10.0.0.5", "10.0.0.5"]))
        let crowded = (0..<InboundLimits.maxUnpaired).map { "10.0.1.\($0)" }
        check("connections that aren't paired are capped in all", !InboundLimits.admits(address: "10.0.2.1", isLoopback: false, unpaired: crowded)
              && !InboundLimits.admits(address: "127.0.0.1", isLoopback: true, unpaired: crowded)
              && InboundLimits.admits(address: "127.0.0.1", isLoopback: true, unpaired: ["127.0.0.1", "127.0.0.1"]))
        check("a hello is due within 10 s", InboundLimits.helloTimeout == 10)
        check("a gallery copy is only taken from a phone that was asked",
              IncomingFileRule.destination(kind: "gallery", fromPhone: true, wanted: true) == .gallery
              && IncomingFileRule.destination(kind: "gallery", fromPhone: true, wanted: false) == .downloads
              && IncomingFileRule.destination(kind: "gallery", fromPhone: false, wanted: true) == .downloads)
        check("photos and scans only come from phones", IncomingFileRule.destination(kind: "photo", fromPhone: true, wanted: false) == .photos
              && IncomingFileRule.destination(kind: "photo", fromPhone: false, wanted: false) == .downloads
              && IncomingFileRule.destination(kind: "scan", fromPhone: true, wanted: false) == .scan
              && IncomingFileRule.destination(kind: "scan", fromPhone: false, wanted: false) == .downloads
              && IncomingFileRule.destination(kind: nil, fromPhone: true, wanted: true).kind == nil)
        var everyone = PairingGuard()
        var globalLock = false
        for index in 0..<PairingGuard.globalLimit { globalLock = everyone.wrongCode("peer\(index)", now: start) }
        check("many wrong codes from many devices close pairing", globalLock
            && everyone.admit("new", now: start.addingTimeInterval(60)) != .allowed
            && everyone.admit("new", now: start.addingTimeInterval(PairingGuard.globalCooldown + 1)) == .allowed)

        check("a paired PC can't say it's a phone", !PeerClass.helloMatches(record: "windows", hello: "android"))
        check("a paired phone can't say it's a Mac", !PeerClass.helloMatches(record: "android", hello: "macos"))
        check("a paired PC can't say it's a Mac", !PeerClass.helloMatches(record: "linux", hello: "macos"))
        check("the same platform matches", PeerClass.helloMatches(record: "macos", hello: "macos") && PeerClass.helloMatches(record: "android", hello: "android"))
        check("the record decides the platform", PeerClass.platform(record: "windows", hello: "macos") == "windows"
            && PeerClass.platform(record: nil, hello: "android") == "android")
        check("usb polls slowly without phones", UsbBridge.interval(sinceDevice: 3600) == 30 && UsbBridge.interval(sinceDevice: 10) == 4)
        var phone = PhoneSnapshot()
        phone.apply(features: ["sms", "contacts"])
        phone.setContacts([ContactItem(id: "1", name: "Budi", phones: ["0812"]), ContactItem(id: "2", name: "Ani", phones: [])])
        check("contacts are sorted and grouped once", phone.sortedContacts.map(\.name) == ["Ani", "Budi"] && phone.contactSections.map(\.letter) == ["A", "B"])
        phone.merge([SmsItem(id: 1, threadId: 9, address: "0812", body: "a", time: 1, outgoing: false),
                     SmsItem(id: 2, threadId: 9, address: "0812", body: "b", time: 2, outgoing: false)])
        check("threads are kept with the messages", phone.threads.count == 1 && phone.threads[0].latest.id == 2 && phone.threads[0].name == "Budi")
    }

    private static func testSharedInputEdges() {
        // A laptop at 0,0 1440×900 with an external display to its right, a little higher.
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        let displays = [laptop, external]
        check("the right edge of the laptop isn't outer, the external display is there",
              EdgeMath.hit(CGPoint(x: 1439, y: 450), edge: .right, displays: displays) == nil)
        let hit = EdgeMath.hit(CGPoint(x: 3359, y: 340), edge: .right, displays: displays)
        check("the external display's right edge is outer", hit?.display == external && abs((hit?.at ?? 0) - 0.5) < 0.01)
        check("the laptop's left edge is outer", EdgeMath.hit(CGPoint(x: 0, y: 225), edge: .left, displays: displays).map { abs($0.at - 0.25) < 0.01 } == true)
        check("the middle of a screen isn't an edge", EdgeMath.hit(CGPoint(x: 700, y: 450), edge: .left, displays: displays) == nil)
        check("the outermost display on the right", EdgeMath.outermost(.right, displays: displays) == external)
        check("the outermost display on the left", EdgeMath.outermost(.left, displays: displays) == laptop)
        let entry = EdgeMath.point(on: .left, of: laptop, at: 0.5)
        check("the pointer appears just inside the left edge, halfway down", entry.x == 2 && abs(entry.y - 449.5) < 0.01)
        check("the opposite of right is left", ScreenEdge.right.opposite == .left && ScreenEdge.top.opposite == .bottom)
        check("pushing right is toward the right edge", ScreenEdge.right.pushes(dx: 3, dy: 0) && !ScreenEdge.right.pushes(dx: -3, dy: 0))
        check("Control-Option-Command brings the pointer home", EdgeMath.isHomeChord([.maskControl, .maskAlternate, .maskCommand]))
        check("Shift too isn't the home chord", !EdgeMath.isHomeChord([.maskControl, .maskAlternate, .maskCommand, .maskShift]))
        check("Command alone isn't the home chord", !EdgeMath.isHomeChord([.maskCommand]))
        let event = RemoteEvent(kind: "key", keyCode: 0, keyDown: true, flags: CGEventFlags.maskCommand.rawValue)
        let back = try? JSONDecoder().decode(RemoteEvent.self, from: JSONEncoder().encode(event))
        check("a key survives the trip as JSON", back == event)
    }

    private static func testGallerySnapshot() {
        var data = PhoneSnapshot()
        data.apply(features: ["gallery"])
        let a = GalleryItem(id: 1, name: "a.jpg", date: 2, size: 10), b = GalleryItem(id: 2, name: "b.mp4", date: 1, size: 20, video: true)
        data.galleryLoading = true
        data.receiveGallery([a], more: true, end: false, error: nil)
        check("a page with more keeps loading", data.galleryLoading && data.gallery.count == 1)
        data.receiveGallery([a, b], more: false, end: true, error: nil)
        check("photos aren't shown twice", data.gallery.map(\.id) == [1, 2] && !data.galleryLoading && data.galleryEnd)
        data.apply(features: [])
        check("turning gallery off clears it", data.gallery.isEmpty && !data.galleryEnd)
    }

    private static func testMenuAnchor() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        check("a menu that shrank goes back under the menu bar", MenuWindowAnchor.top(frame: CGRect(x: 1200, y: 200, width: 280, height: 560), visible: visible) == 944)
        check("a menu in place stays", MenuWindowAnchor.top(frame: CGRect(x: 1200, y: 384, width: 280, height: 560), visible: visible) == 944)
    }

    private static func testEmojiExtras() {
        check("flags by English name", LauncherEmoji.search("japan").contains { $0.emoji == "🇯🇵" })
        check("flags by Indonesian name", LauncherEmoji.search("jepang").contains { $0.emoji == "🇯🇵" })
        check("the Indonesian flag is still there", LauncherEmoji.search("indonesia").first?.emoji == "🇮🇩")
        check("joined family emoji", LauncherEmoji.search("keluarga").contains { $0.emoji == "👨‍👩‍👧‍👦" })
        check("job emoji", LauncherEmoji.search("programmer").contains { $0.emoji == "🧑‍💻" })
        check("a tone word is taken out", LauncherEmoji.splitTone("jempol sawo") == ("jempol", 3))
        check("a thumb takes a tone", LauncherEmoji.toned("👍", 3) == "👍🏽")
        check("a tone replaces the text-style selector", LauncherEmoji.toned("✌️", 1) == "✌🏻")
        check("one person in a joined emoji takes it", LauncherEmoji.toned("🧑‍💻", 5) == "🧑🏿‍💻")
        check("a family stays plain", LauncherEmoji.toned("👨‍👩‍👧", 2) == "👨‍👩‍👧")
        check("things don't take tones", LauncherEmoji.toned("🔥", 4) == "🔥")
        check("tone 0 is plain", LauncherEmoji.toned("👍", 0) == "👍")
    }

    private static func testLayoutCommands() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dysklink-layouts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let layout = WindowLayout(directory: folder)
        check("no layouts, no commands", layout.commands.isEmpty)
        check("other commands aren't layouts", layout.runCommand("abc") == nil)
        check("a deleted layout says so", layout.runCommand(WindowLayout.commandPrefix + UUID().uuidString) == "That layout was deleted.")
    }

    private static func testSearchablePDF() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dysklink-scan-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        // A "scan": a picture of printed words, with no text in the PDF.
        let size = CGSize(width: 1240, height: 1754)
        guard let bitmap = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return check("scan picture", false) }
        bitmap.setFillColor(.white)
        bitmap.fill(CGRect(origin: .zero, size: size))
        let words = NSAttributedString(string: "Invoice DyskLink 2026", attributes: [.init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 90, nil)])
        bitmap.textPosition = CGPoint(x: 120, y: 1400)
        CTLineDraw(CTLineCreateWithAttributedString(words), bitmap)
        guard let picture = bitmap.makeImage() else { return check("scan picture", false) }
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return check("scan pdf", false) }
        pdf.beginPDFPage(nil)
        pdf.draw(picture, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        check("a fresh scan has no text", (PDFDocument(url: url)?.string ?? "").isEmpty)
        check("one page gets text", SearchablePDF.addText(to: url) == 1)
        let text = PDFDocument(url: url)?.string ?? ""
        check("the scan can be searched", text.contains("DyskLink") && text.contains("2026"))
        check("the page size stays", PDFDocument(url: url)?.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 595, height: 842))
        check("a PDF with text is left alone", SearchablePDF.addText(to: url) == 0)
    }

    private static func testSameFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dysklink-same-\(UUID().uuidString).txt")
        try? Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        check("the same photo is recognised", FileNames.sameFile(url, size: 3, sha256: abc))
        check("a different size isn't", !FileNames.sameFile(url, size: 4, sha256: abc))
        check("different contents aren't", !FileNames.sameFile(url, size: 3, sha256: String(repeating: "0", count: 64)))
    }

    private static func testMouseLook() {
        let look = GameKey(kind: .look, label: "Look", x: 0.7, y: 0.5, radius: 0.1)
        let fire = GameKey(kind: .fire, label: "Click", x: 0.9, y: 0.8)
        var engine = GameKeyEngine(keys: [look, fire], aspect: 0.5)
        let begin = engine.lookBegin(now: 0)
        check("aiming puts the look finger in the middle", begin.count == 1 && begin[0].kind == "tdown" && begin[0].key == "9")
        let small = engine.look(dx: 0.05, dy: 0, now: 30)
        check("a small move drags the finger", small.count == 1 && small[0].kind == "tmove" && abs(Double(small[0].x ?? 0) - 0.75) < 0.001)
        let far = engine.look(dx: 0.2, dy: 0, now: 40)
        let farMove = engine.tick(now: 60)
        check("at the edge the finger lifts and starts again", far.map(\.kind) == ["tup", "tdown"]
            && farMove.map(\.kind) == ["tmove"] && abs(Double(farMove[0].x ?? 0) - 0.9) < 0.001)
        let shot = engine.fire(true)
        check("clicking presses the click spot", shot.count == 1 && shot[0].key == "8" && shot[0].kind == "tdown")
        check("a second press does nothing", engine.fire(true).isEmpty)
        let all = engine.releaseAll()
        check("letting go lifts the click and look fingers", Set(all.compactMap(\.key)) == ["8", "9"] && all.allSatisfy { $0.kind == "tup" })
        check("profiles round-trip", (try? JSONDecoder().decode([GameProfile].self, from: JSONEncoder().encode([GameProfile(name: "PUBG", keys: [look])])))?.first?.keys.first?.kind == .look)
    }

    private static func testAdaptiveQuality() {
        check("many dropped frames lower the bitrate", MacScreenViewer.nextBitrate(current: 5_000_000, sent: 30, dropped: 15, max: 5_000_000) == 3_500_000)
        check("the bitrate never goes under the floor", MacScreenViewer.nextBitrate(current: 1_100_000, sent: 1, dropped: 40, max: 5_000_000) == 1_000_000)
        check("a clear network raises it back to the cap", MacScreenViewer.nextBitrate(current: 2_000_000, sent: 45, dropped: 0, max: 5_000_000) == 2_300_000
            && MacScreenViewer.nextBitrate(current: 4_900_000, sent: 45, dropped: 0, max: 5_000_000) == 5_000_000)
        check("a few drops keep it", MacScreenViewer.nextBitrate(current: 3_000_000, sent: 44, dropped: 1, max: 5_000_000) == 3_000_000)
    }

    private static func testHeldByMacOS() {
        var settings = ChargeSettings()
        settings.limiter = true
        settings.limit = 80
        func decide(_ percent: Int, native: Int?, previous: ChargeReason = .normal) -> ChargeReason {
            ChargePolicy.decide(percent: percent, charging: true, temperature: 30, settings: settings, calibration: .off,
                                previous: previous, now: Date(), native: native).reason
        }
        check("macOS's limit holds 80% with the charger on", decide(80, native: 80) == .held && ChargeReason.held.adapterOn)
        check("below macOS's limit it charges", decide(70, native: 80) == .normal)
        check("without macOS's limit the charger is switched off", decide(80, native: 100) == .limit && decide(80, native: nil) == .limit)
        check("a higher macOS limit leaves it to DyskLink", decide(80, native: 90) == .limit)
    }

    private static func testPowerSettings() {
        let custom = "Battery Power:\n lowpowermode         1\n sleep 1\nAC Power:\n lowpowermode         0\n"
        check("low power mode per power source is read", PowerSettings.parse(custom: custom) == .battery
            && PowerSettings.parse(custom: custom.replacingOccurrences(of: "         0", with: "         1")) == .always
            && PowerSettings.parse(custom: "nothing") == nil)
        check("low power mode running now is read", PowerSettings.parseActive(" lowpowermode         1\n") && !PowerSettings.parseActive(" lowpowermode 0"))
        // A real PNG of 10001 × 10001 black-and-white pixels: tiny on disk, 100 MP decoded. Its size is read from
        // the header, never decoded.
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }
        func be(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return be(UInt32(body.count)) + typed + be(crc32(typed))
        }
        let side: UInt32 = 10_001
        let rawCount = Int(side) * (1 + (Int(side) + 7) / 8)
        let deflated = (try? (Data(count: rawCount) as NSData).compressed(using: .zlib) as Data).map { [UInt8]($0) } ?? []
        let zlibStream: [UInt8] = [0x78, 0x01] + deflated + be(UInt32(rawCount % 65_521) << 16 | 1)
        let huge = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", be(side) + be(side) + [1, 0, 0, 0, 0])
                        + chunk("IDAT", zlibStream) + chunk("IEND", []))
        let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:])
        check("a clipboard picture's size is read from its header", ClipboardWatcher.pixelCount(huge) == 100_020_001
              && small.flatMap(ClipboardWatcher.pixelCount) == 200 && ClipboardWatcher.pixelCount(Data(repeating: 7, count: 5_000)) == nil)
        check("a picture over 100 megapixels is refused for the clipboard", (ClipboardWatcher.pixelCount(huge) ?? 0) > ClipboardWatcher.maxImagePixels)
        let rule = ChargeHelper.installScript(user: "me")
        check("sudo rule allows only the four low power choices", rule.contains("dysklink-power lowpower never") && rule.contains("dysklink-power lowpower always")
            && !rule.contains("lowpower *"))
        check("settings search finds pages by Indonesian words", LauncherSettings.all.contains { $0.id == "battery" && $0.words.contains("baterai") }
            && LauncherSettings.system.allSatisfy { $0.pane.flatMap(LauncherSettings.url) != nil })
    }

    private static func testPlayerDetails() {
        let video = PlayerDetails.parseVideo(#"{"t":61.5,"d":245.2,"p":true,"c":"Some Channel","i":"dQw4w9WgXcQ"}"#)
        check("video details are read", video?.position == 61.5 && video?.duration == 245.2 && video?.isPlaying == true
            && video?.channel == "Some Channel" && video?.thumbnail?.absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg")
        let live = PlayerDetails.parseVideo(#"{"t":10,"d":null,"p":false,"c":"","i":"bad id!"}"#)
        check("live video has no length, odd ids are dropped", live?.duration == nil && live?.channel == nil && live?.thumbnail == nil && live?.isPlaying == false)
        check("non-YouTube page gives nothing", PlayerDetails.parseVideo("") == nil)
        check("images only from player servers", PlayerDetails.isAllowedImage(URL(string: "https://i.scdn.co/image/ab67")!)
            && !PlayerDetails.isAllowedImage(URL(string: "http://i.scdn.co/image/ab67")!)
            && !PlayerDetails.isAllowedImage(URL(string: "https://example.com/a.jpg")!))
        check("video script fits in an AppleScript string", !PlayerDetails.videoScript.contains("\""))
        let message = #"{"v":1,"browser":"Firefox","state":{"title":"A Song","channel":"Chan","t":12.5,"d":200,"p":true,"i":"dQw4w9WgXcQ","music":false}}"#
        if case .some(.some(let track)) = BrowserExtension.parse(message) {
            check("extension message is read", track.title == "A Song" && track.artist == "Chan · YouTube in Firefox"
                && track.position == 12.5 && track.duration == 200 && track.isPlaying && track.videoID == "dQw4w9WgXcQ")
        } else {
            check("extension message is read", false)
        }
        if case .some(.none) = BrowserExtension.parse(#"{"v":1,"browser":"Firefox","state":null}"#) {
            check("extension says nothing plays", true)
        } else {
            check("extension says nothing plays", false)
        }
        check("other messages are ignored", BrowserExtension.parse(#"{"v":2}"#) == nil && BrowserExtension.parse("junk") == nil)
        let manifest = (try? JSONSerialization.jsonObject(with: BrowserExtension.manifest(hostPath: "/x/host"))) as? [String: Any]
        check("host manifest only allows the DyskLink extension", manifest?["allowed_extensions"] as? [String] == ["dysklink@dysklink.id"]
            && manifest?["name"] as? String == "id.dysklink.browser" && manifest?["type"] as? String == "stdio")
        let jp = ["君の名は希望と今知った", "東京は雨、僕を待っている！"]
        check("Japanese lyrics become romaji", Romanizer.romanize(jp[0], japanese: true) == "kimi no na wa kibou to ima shitta"
            && Romanizer.romanize(jp[1], japanese: true) == "toukyou wa ame, boku wo matte iru!")
        check("Latin lyrics stay as they are", Romanizer.romanize("Love me do", japanese: true) == "Love me do"
            && LyricsModel.romanized(.plain(["Hello", "world"])) == nil)
        check("Korean lyrics are romanized", !Romanizer.needs(Romanizer.romanize("사랑해요", japanese: false)))
        let steady = LyricsModel(isInert: true)
        let timedLines = [LyricLine(time: 0, text: "a"), LyricLine(time: 10, text: "b"), LyricLine(time: 20, text: "c")]
        let first = steady.line(in: timedLines, at: 10.5)
        let corrected = steady.line(in: timedLines, at: 9.6)
        let missing = steady.line(in: timedLines, at: nil)
        let seek = steady.line(in: timedLines, at: 2)
        check("lyrics don't hop back on small corrections", first == 1 && corrected == 1 && missing == 1 && seek == 0)
        func lyricSong(_ title: String, _ artist: String) -> String {
            let song = LyricsParser.song(for: NowPlaying(title: title, artist: artist, isPlaying: true))
            return "\(song.artist)|\(song.title)"
        }
        check("YouTube title gives artist and song", lyricSong("Coldplay - Yellow (Official Video)", "ColdplayVEVO · YouTube in Firefox") == "Coldplay|Yellow")
        check("YouTube topic channel is the artist", lyricSong("Yellow", "Coldplay - Topic · YouTube in Chrome") == "Coldplay|Yellow")
        check("YouTube Music keeps its artist", lyricSong("Yellow", "Coldplay · YouTube Music in Firefox") == "Coldplay|Yellow")
        check("YouTube without channel splits the title", lyricSong("Coldplay - Yellow Official Music Video", "YouTube in Safari") == "Coldplay|Yellow")
        check("featured artists are dropped", lyricSong("Artist - Song ft. Other", "YouTube in Firefox") == "Artist|Song")
        check("Spotify is unchanged", lyricSong("Yellow", "Coldplay") == "Coldplay|Yellow")
        let a = NowPlaying(title: "Song", artist: "A", isPlaying: true, source: PlayerDetails.music)
        let b = NowPlaying(title: "Song", artist: "A", isPlaying: true, source: PlayerDetails.spotify)
        check("art is matched to the player and song", a.key != b.key)
    }

    private static func testChargePolicy() {
        let now = Date()
        var settings = ChargeSettings()
        func decide(_ percent: Int, charging: Bool = true, temp: Double? = 30, calibration: CalibrationPhase = .off, previous: ChargeReason = .normal) -> ChargeDecision {
            ChargePolicy.decide(percent: percent, charging: charging, temperature: temp, settings: settings, calibration: calibration, previous: previous, now: now)
        }
        check("charging is normal with nothing on", decide(50).reason == .normal)
        var sleepy = ChargeSettings()
        sleepy.limiter = true
        sleepy.limit = 80
        func offBeforeSleep(_ percent: Int, reason: ChargeReason, topUp: Bool = false, calibration: CalibrationPhase = .off) -> Bool {
            ChargePolicy.offBeforeSleep(percent: percent, settings: sleepy, calibration: calibration, reason: reason, topUp: topUp, adapterOff: false)
        }
        check("at the limit the charger goes off before sleep", offBeforeSleep(80, reason: .normal) && offBeforeSleep(80, reason: .limit))
        check("below the limit it keeps charging before sleep", !offBeforeSleep(78, reason: .normal) && !offBeforeSleep(79, reason: .limit))
        check("far below the limit it stays on before sleep", !offBeforeSleep(60, reason: .normal))
        check("a top-up keeps charging through sleep", !offBeforeSleep(90, reason: .topUp, topUp: true) && !offBeforeSleep(90, reason: .normal, topUp: true))
        check("macOS holding the level keeps the charger on in sleep", !offBeforeSleep(80, reason: .held))
        check("a heat pause or calibration isn't changed by sleep",
              !offBeforeSleep(80, reason: .heat) && !offBeforeSleep(80, reason: .calibrationCharge, calibration: .charging)
              && !offBeforeSleep(80, reason: .lowBattery) && !offBeforeSleep(85, reason: .discharge))
        let start = Date(timeIntervalSince1970: 1_000_000)
        let even = ChargeControl.evenLevels([.init(time: start, percent: 50), .init(time: start.addingTimeInterval(600), percent: 55)],
                                            until: start.addingTimeInterval(900))
        check("level history is spread evenly for the chart", even.count == 6 && even.first?.percent == 50 && even.last?.percent == 55)
        settings.limiter = true
        settings.limit = 80
        settings.sail = 5
        check("limit turns the charger off", decide(80).reason == .limit && !decide(80).reason.adapterOn)
        check("below the limit keeps charging", decide(79).reason == .normal)
        check("sailing holds off until the gap", decide(76, previous: .limit).reason == .limit && decide(75, previous: .limit).reason == .normal)
        settings.heat = true
        settings.heatLimit = 42
        check("heat pauses charging", decide(50, temp: 42.5).reason == .heat)
        check("heat pause lasts until it cools by two degrees", decide(50, charging: false, temp: 40.5, previous: .heat).reason == .heat
            && decide(50, charging: false, temp: 39.9, previous: .heat).reason == .normal)
        check("heat ignored while not charging", decide(50, charging: false, temp: 45).reason == .normal)
        settings.discharge = true
        check("discharge runs above the limit", decide(90).reason == .discharge && !decide(90).reason.adapterOn)
        check("discharge stops at the limit", decide(80).reason == .limit && decide(50).reason == .normal && decide(50).reason.adapterOn)
        settings.limiter = false
        check("discharge without a limit keeps running on battery", decide(50).reason == .discharge)
        settings.limiter = true
        check("low battery always charges", decide(11).reason == .lowBattery && decide(11).reason.adapterOn)
        settings = ChargeSettings()
        check("calibration drains first", decide(60, calibration: .draining).reason == .calibrationDrain)
        let drained = decide(15, calibration: .draining)
        check("calibration charges after draining", drained.calibration == .charging && drained.reason == .calibrationCharge)
        let full = decide(100, calibration: .charging)
        check("calibration rests at full", full.reason == .calibrationHold && full.calibration == .holding(until: now.addingTimeInterval(CalibrationPhase.holdFor)))
        check("calibration ends after resting", decide(100, calibration: .holding(until: now.addingTimeInterval(-1))).calibration == .off)
        check("calibration never drains below 10%", decide(10, calibration: .draining).reason == .lowBattery)
        settings.limiter = true
        let top = ChargePolicy.decide(percent: 85, charging: true, temperature: 30, settings: settings, calibration: .off, previous: .limit, now: now, topUp: true)
        check("top up charges past the limit", top.reason == .topUp && top.reason.adapterOn && top.topUp)
        let topped = ChargePolicy.decide(percent: 100, charging: false, temperature: 30, settings: settings, calibration: .off, previous: .topUp, now: now, topUp: true)
        check("top up ends at full", !topped.topUp && topped.reason == .limit)
        settings.limiter = false
        let pmset = "Battery level limits:\n(\n    {\n        chargeSocLimitReason = manualChargeLimit;\n        chargeSocLimitSoc = 85;\n    }\n)"
        check("system charge limit is read", NativeChargeLimit.parse(pmset) == 85 && NativeChargeLimit.parse("No battery level limits set") == nil)
        let script = ChargeHelper.installScript(user: "someone")
        check("sudo rule only allows the helper's commands", script.contains("someone ALL=(root) NOPASSWD: /usr/local/libexec/dysklink-power adapter on, /usr/local/libexec/dysklink-power adapter off, /usr/local/libexec/dysklink-power status")
            && script.contains("visudo -cf"))
        check("the install script takes the helper as an argument, not in its text",
              script.contains(#"helper_src="$1""#) && script.contains(#"/bin/cp "$helper_src" "$work/helper""#)
              && script.contains(#"install -o root -g wheel -m 755 "$work/helper""#) && !script.contains("'/"  + "tmp"))
        check("the install script checks the copy's hash and signature in a root folder",
              script.contains("mktemp -d /private/var/tmp/") && script.contains(#"[ "$sum" != "$helper_sha" ]"#)
              && script.contains(#"codesign --verify --strict -R="$helper_req" "$work/helper""#)
              && script.contains(#"rm -rf "${work:?}""#))
        check("the install script parses", (try? Shell.run("/bin/sh", ["-n", "-c", script])) != nil)
        check("arguments reach the root script quoted", ChargeHelper.adminRunner.contains("quoted form of (item index of argv)")
              && ChargeHelper.adminRunner.contains("quoted form of (item 1 of argv)"))
        // The same runner without the admin prompt: a path with quotes and $() stays one argument.
        let tricky = "/Volumes/it's $(echo injected) `echo x` \"q\" ; true"
        let unprivileged = ChargeHelper.adminRunner.replacingOccurrences(of: " with administrator privileges", with: "")
        check("a path with quotes and $() is passed as plain text",
              (try? Shell.run("/usr/bin/osascript", ["-e", unprivileged, #"printf '%s' "$1""#, tricky]))?.trimmingCharacters(in: .newlines) == tricky)
        check("plain user names go into the sudo rule", ChargeHelper.isPlainUserName("fanny") && ChargeHelper.isPlainUserName("a.b_c-1")
              && !ChargeHelper.isPlainUserName("x ALL") && !ChargeHelper.isPlainUserName("a'b") && !ChargeHelper.isPlainUserName("")
              && !ChargeHelper.isPlainUserName("-x"))
        check("the helper must have this app's team or certificate",
              ChargeHelper.requirement(team: "ABCDE12345", leafSHA1: nil) == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
              && ChargeHelper.requirement(team: nil, leafSHA1: String(repeating: "A", count: 40)) == "certificate leaf = H\"" + String(repeating: "a", count: 40) + "\""
              && ChargeHelper.requirement(team: "x\" or true", leafSHA1: nil) == nil && ChargeHelper.requirement(team: nil, leafSHA1: nil) == nil)
    }

    private static func testGameKeys() {
        let space = GameKey(kind: .tap, keyCode: 49, label: "Space", x: 0.9, y: 0.8)
        let stick = GameKey(kind: .joystick, label: "WASD", x: 0.2, y: 0.7, radius: 0.1)
        var engine = GameKeyEngine(keys: [space, stick], aspect: 2)
        let tap = engine.keyDown(49)
        check("game tap key goes down", tap.count == 1 && tap[0].kind == "tdown" && tap[0].key == "1" && tap[0].x == 0.9)
        check("game key repeat ignored", engine.keyDown(49).isEmpty)
        let w = engine.keyDown(GameKeyEngine.up, now: 100)
        let early = engine.tick(now: 110), wMove = engine.tick(now: 120)
        check("joystick presses at center alone, then moves up a tick later", w.count == 1 && w[0].kind == "tdown" && w[0].key == "0"
            && w[0].y == Float(0.7) && early.isEmpty && wMove.count == 1 && wMove[0].kind == "tmove" && abs((wMove[0].y ?? 0) - 0.5) < 0.0001)
        let d = engine.keyDown(GameKeyEngine.right, now: 130)
        check("joystick goes diagonal", d.count == 1 && d[0].kind == "tmove" && (d[0].x ?? 0) > 0.2 && (d[0].y ?? 1) < 0.7)
        check("held fingers repeat", engine.held().count == 2)
        _ = engine.keyUp(GameKeyEngine.up, now: 140)
        let release = engine.keyUp(GameKeyEngine.right, now: 150)
        check("joystick lifts when no direction is held", release.count == 1 && release[0].kind == "tup" && release[0].key == "0")
        check("other keys pass through", !engine.handles(12))
        let all = engine.releaseAll()
        check("release all lifts the tap key", all.count == 1 && all[0].kind == "tup" && all[0].key == "1" && engine.pressed.isEmpty)
        // Turning the picture and back gives the same phone point.
        let view = ScreenSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        view.videoSize = CGSize(width: 2400, height: 1080)
        var roundTrips = true
        for turns in 0..<4 {
            view.quarterTurns = turns
            let point = view.viewPoint(fromPhone: (0.25, 0.75))
            let back = view.phonePoint(atView: point)
            roundTrips = roundTrips && abs(back.x - 0.25) < 0.01 && abs(back.y - 0.75) < 0.01
        }
        check("game key points survive rotation", roundTrips)
    }

    /// The audit fixes: a new finger's tdown goes alone, ⌘ key ups, right modifiers, the mouse finger, throttles, pairing.
    private static func testGameKeysTiming() {
        func near(_ a: Float?, _ b: Double) -> Bool { abs(Double(a ?? -9) - b) < 0.0005 }
        /// No batch moves a finger it put down in that same batch.
        func downAlone(_ batches: [[ControlEvent]]) -> Bool {
            batches.allSatisfy { batch in
                let downs = Set(batch.filter { $0.kind == "tdown" }.compactMap(\.key))
                return !batch.contains { $0.kind == "tmove" && downs.contains($0.key ?? "") }
            }
        }
        let skill = GameKey(kind: .skill, keyCode: 12, label: "Q", x: 0.8, y: 0.8, radius: 0.05)
        var aim = GameKeyEngine(keys: [skill], aspect: 1)
        _ = aim.mouseMoved(to: (0.5, 1.0), now: 0)
        let press = aim.keyDown(12, now: 100)
        let soon = aim.tick(now: 110)
        let moved = aim.mouseMoved(to: (0.5, 0.0), now: 115)
        let waiting = aim.needsTick
        let later = aim.tick(now: 120)
        check("skill: tdown alone at the button, the aim on a tick 20 ms later", press.map(\.kind) == ["tdown"]
            && near(press[0].y, 0.8) && soon.isEmpty && moved.isEmpty && waiting
            && later.map(\.kind) == ["tmove"] && near(later[0].y, 0.75) && !aim.needsTick)
        let stick = GameKey(kind: .joystick, label: "WASD", x: 0.2, y: 0.7, radius: 0.1)
        var sticks = GameKeyEngine(keys: [stick], aspect: 1)
        let stickDown = sticks.keyDown(13, now: 0)
        let stickRight = sticks.keyDown(2, now: 5)
        let stickTicks = [sticks.tick(now: 8), sticks.tick(now: 16), sticks.tick(now: 24)]
        check("joystick: tdown alone at the centre, the push on a later tick", stickDown.map(\.kind) == ["tdown"]
            && near(stickDown[0].x, 0.2) && stickRight.isEmpty && stickTicks[0].isEmpty && stickTicks[1].isEmpty
            && stickTicks[2].count == 1 && (stickTicks[2][0].x ?? 0) > 0.2 && (stickTicks[2][0].y ?? 1) < 0.7)
        var tapStick = GameKeyEngine(keys: [stick], aspect: 1)
        _ = tapStick.keyDown(13, now: 0)
        let tapUp = tapStick.keyUp(13, now: 10)
        check("joystick let go before it moved still moves, then lifts", tapUp.map(\.kind) == ["tmove", "tup"] && tapStick.down.isEmpty)
        // Swipes and combos, even with a slow tick.
        let swipe = GameKey(kind: .swipe, keyCode: 3, label: "F", x: 0.2, y: 0.5, toX: 0.6, toY: 0.1)
        var combo = GameKey(kind: .tap, keyCode: 14, label: "E", x: 0.5, y: 0.5, mode: .combo)
        combo.steps = [.init(kind: .tap, x: 0.1, y: 0.1), .init(kind: .wait, ms: 10), .init(kind: .swipe, x: 0.3, y: 0.3, toX: 0.4, toY: 0.4, ms: 32)]
        for step in [8.0, 25.0] {
            var gestures = GameKeyEngine(keys: [swipe, combo], aspect: 1)
            var batches = [gestures.keyDown(3, now: 0) + gestures.keyDown(14, now: 0)]
            for t in stride(from: step, through: 400, by: step) { batches.append(gestures.tick(now: t)) }
            let swipeMoves = batches.enumerated().filter { $0.element.contains { $0.kind == "tmove" && $0.key == "0" } }
            check("swipe and combo: tdown alone, every \(Int(step)) ms tick", downAlone(batches) && gestures.down.isEmpty
                && Double(swipeMoves.first?.offset ?? 0) * step >= GameKeyEngine.settleMs
                && batches.joined().filter { $0.kind == "tdown" }.count == 3 && batches.joined().last?.kind == "tup")
        }
        // Right-hand modifiers recorded as a joystick's keys work like the left ones.
        let model = GameKeysModel()
        var fakeTime = 0.0
        model.clock = { fakeTime += 50; return fakeTime }
        model.preview(keys: [stick])
        model.editing = true
        model.capture = .stickKeys(stick.id, [], [])
        for code: UInt16 in [60, 62, 61, 13] { _ = model.assign(code: code, label: GameKeysModel.label(code: code, characters: nil)) }
        model.editing = false
        model.enabled = true
        var sent: [ControlEvent] = []
        model.send = { sent.append($0) }
        check("right ⇧⌃⌥ stick keys are stored as the left ones", model.keys.first?.customKeys == [56, 59, 58, 13]
            && model.key(60, down: true) && sent.first?.kind == "tdown" && model.key(62, down: true))
        // ⌘ swallows key ups: letting go of ⌘ releases what the keyboard no longer holds.
        sent = []
        model.releaseLifted(isHeld: { $0 == 62 })
        check("⌘ up releases keys let go meanwhile, right modifiers held stay", !sent.isEmpty && sent.allSatisfy { $0.kind == "tmove" })
        model.releaseLifted(isHeld: { _ in false })
        let lifted = sent.count
        _ = model.key(60, down: false)
        check("⌘ up with nothing held lifts the finger", sent.last?.kind == "tup" && sent.count == lifted)
        model.enabled = false
        // The mouse finger is kept by the engine, so the heartbeat holds it, and looking takes it over cleanly.
        let look = GameKey(kind: .look, label: "Look", x: 0.7, y: 0.5, radius: 0.1)
        var mouse = GameKeyEngine(keys: [look], aspect: 1)
        let touch = mouse.mouseTouch("tdown", x: 0.3, y: 0.3, now: 0)
        let drag = mouse.mouseTouch("tmove", x: 0.35, y: 0.3, now: 30)
        check("the mouse finger is in the heartbeat", touch.map(\.kind) == ["tdown"] && touch[0].key == "9" && drag.count == 1
            && mouse.held().contains { $0.key == "9" && near($0.x, 0.35) })
        let begin = mouse.lookBegin(now: 40)
        check("looking lifts the mouse finger before taking finger 9", begin.map(\.kind) == ["tup", "tdown"]
            && near(begin[0].x, 0.35) && near(begin[1].x, 0.7) && begin.allSatisfy { $0.key == "9" })
        check("mouse touches wait while looking", mouse.mouseTouch("tmove", x: 0.1, y: 0.1, now: 50).isEmpty
            && mouse.mouseTouch("tup", x: 0.1, y: 0.1, now: 60).isEmpty && mouse.held().count == 1)
        _ = mouse.lookEnd(now: 70)
        check("a stray mouse up after looking sends nothing", mouse.mouseTouch("tup", x: 0.1, y: 0.1, now: 80).isEmpty && mouse.down.isEmpty)
        // Aim and look moves at most about 90 a second; look adds up what it holds back.
        var aimRate = MoveThrottle(interval: 1.0 / 90)
        let due = [0, 0.004, 0.009, 0.0112, 0.015, 0.0224].map { aimRate.isDue($0) }
        check("aim moves are throttled to ~90 Hz", due == [true, false, false, true, false, true])
        var lookRate = MoveThrottle(interval: 1.0 / 90)
        let sums = [(1.0, 0.0, 0.0), (1.0, 0.0, 0.004), (2.0, 0.5, 0.008), (1.0, 1.0, 0.0115)].map { lookRate.add(dx: $0.0, dy: $0.1, at: $0.2) }
        check("look moves are throttled and add up", sums[0]! == (1, 0) && sums[1] == nil && sums[2] == nil && sums[3]! == (4, 1.5))
        // Pairing: one CPace share per prompt, a new nonce only after a wrong code or every 2 s.
        let start = Date(timeIntervalSince1970: 1_000_000)
        var renewal = PakeRenewal()
        renewal.started(now: start)
        let burst = (1...50).map { renewal.allowsNewShare(now: start.addingTimeInterval(Double($0) * 0.03)) }
        let afterWait = renewal.allowsNewShare(now: start.addingTimeInterval(2.1))
        let rightAfter = renewal.allowsNewShare(now: start.addingTimeInterval(2.2))
        renewal.wrongCode()
        let afterWrong = renewal.allowsNewShare(now: start.addingTimeInterval(2.3))
        let afterWrongAgain = renewal.allowsNewShare(now: start.addingTimeInterval(2.4))
        check("pairing: new nonces get a new share only every 2 s or after a wrong code", !burst.contains(true) && afterWait
            && !rightAfter && afterWrong && !afterWrongAgain)
        var pending = PendingCode()
        pending.hold("123456")
        pending.clear()
        let afterReject = pending.take(localAccepted: true)
        pending.hold("123456")
        let notAccepted = pending.take(localAccepted: false)
        pending.hold("654321")
        check("pairing: a wrong code drops the waiting code; only an accepted code is sent", afterReject == nil && notAccepted == nil
            && pending.code == "654321" && pending.take(localAccepted: true) == "654321" && pending.code == nil)
    }

    private static func testGameKeysMore() {
        func near(_ a: Float?, _ b: Double) -> Bool { abs(Double(a ?? -9) - b) < 0.0005 }
        // Two joysticks with different key sets, each on its own finger.
        let move = GameKey(kind: .joystick, label: "WASD", x: 0.2, y: 0.7, radius: 0.1)
        let camera = GameKey(kind: .joystick, label: "↑←↓→", x: 0.8, y: 0.7, radius: 0.1, keySet: .arrows)
        var two = GameKeyEngine(keys: [move, camera], aspect: 1)
        let w = two.keyDown(13, now: 0), up = two.keyDown(126, now: 0)
        let settled = two.tick(now: 20)
        check("two joysticks use separate fingers", w.first?.key == "0" && up.first?.key == "1" && w.count == 1 && up.count == 1
            && settled.map(\.key) == ["0", "1"] && settled.allSatisfy { $0.kind == "tmove" })
        let d = two.keyDown(2, now: 30), left = two.keyDown(123, now: 30)
        let k = 0.1 / 2.0.squareRoot()
        check("WASD diagonal is normalized", d.count == 1 && near(d[0].x, 0.2 + k) && near(d[0].y, 0.7 - k))
        check("arrow diagonal is normalized", left.count == 1 && near(left[0].x, 0.8 - k) && near(left[0].y, 0.7 - k))
        check("arrows don't move the WASD joystick", !two.handles(34) && two.keyDown(126).isEmpty)
        check("both joysticks lift on release", two.releaseAll().count == 2 && two.down.isEmpty)
        // Walking: Shift for full reach, half otherwise.
        let walker = GameKey(kind: .joystick, label: "WASD", x: 0.5, y: 0.5, radius: 0.1, walk: .fullWithKey)
        var walk = GameKeyEngine(keys: [walker], aspect: 1)
        _ = walk.keyDown(2, now: 0)
        let half = walk.tick(now: 20)
        let full = walk.keyDown(60, now: 30) // right Shift counts as Shift
        let back = walk.keyUp(60, now: 40)
        check("walk mode starts at half reach", near(half.last?.x, 0.55))
        check("shift pushes the joystick to full reach", full.count == 1 && near(full[0].x, 0.6))
        check("letting go of shift walks again", back.count == 1 && near(back[0].x, 0.55))
        var halfWith = GameKeyEngine(keys: [GameKey(kind: .joystick, label: "", x: 0.5, y: 0.5, radius: 0.1, walk: .halfWithKey)], aspect: 1)
        _ = halfWith.keyDown(2, now: 0)
        let fullFirst = halfWith.tick(now: 20)
        check("the other walk mode halves with shift", near(fullFirst.last?.x, 0.6) && near(halfWith.keyDown(56, now: 30).last?.x, 0.55))
        // Skill aim.
        let skill = GameKey(kind: .skill, keyCode: 12, label: "Q", x: 0.8, y: 0.8, radius: 0.05)
        let far = GameKeyEngine.aimPoint(button: (0.8, 0.8), radius: 0.05, mouse: (1.0, 0.5), aspect: 1)
        let close = GameKeyEngine.aimPoint(button: (0.8, 0.8), radius: 0.05, mouse: (0.6, 0.5), aspect: 1)
        check("skill aim is clamped to its reach", abs(far.x - 0.85) < 1e-9 && abs(far.y - 0.8) < 1e-9)
        check("skill aim follows the mouse's distance", abs(close.x - (0.8 + 0.1 / 0.25 * 0.05)) < 1e-9)
        var aim = GameKeyEngine(keys: [skill], aspect: 1)
        _ = aim.mouseMoved(to: (0.5, 1.0))
        let press = aim.keyDown(12, now: 0)
        let aimed = aim.tick(now: 20)
        check("a skill presses its button, then aims a tick later", press.map(\.kind) == ["tdown"] && near(press[0].x, 0.8)
            && near(press[0].y, 0.8) && aimed.map(\.kind) == ["tmove"] && near(aimed[0].y, 0.85))
        let follow = aim.mouseMoved(to: (0.5, 0.0), now: 30)
        check("the held skill follows the mouse", follow.count == 1 && near(follow[0].y, 0.75))
        let cancel = aim.cancelAim(now: 40)
        check("Esc returns to the middle, then lifts", cancel.map(\.kind) == ["tmove", "tup"] && near(cancel[0].x, 0.8) && near(cancel[0].y, 0.8))
        check("the release after a cancel does nothing", aim.keyUp(12, now: 500).isEmpty && aim.down.isEmpty)
        _ = aim.keyDown(12, now: 1000)
        _ = aim.tick(now: 1020)
        let cast = aim.keyUp(12, now: 1500)
        check("letting go casts where it aims", cast.count == 1 && cast[0].kind == "tup" && near(cast[0].y, 0.75))
        var quick = GameKeyEngine(keys: [{ var k = skill; k.quickCast = true; return k }()], aspect: 1)
        _ = quick.mouseMoved(to: (0.5, 0.0))
        _ = quick.keyDown(12, now: 0)
        let tapCast = quick.keyUp(12, now: 100)
        check("quick cast taps the middle", tapCast.map(\.kind) == ["tmove", "tup"] && near(tapCast[1].y, 0.8))
        // Swipes.
        let line = GameKeyEngine.swipeTimeline(from: (0.2, 0.5), to: (0.6, 0.1), durationMs: 120)
        let moves = line.filter { $0.kind == "tmove" }
        check("swipe starts at A and ends at B", line.first == .init(at: 0, kind: "tdown", x: 0.2, y: 0.5)
              && line.last == .init(at: 120, kind: "tup", x: 0.6, y: 0.1) && abs(moves.last!.x - 0.6) < 1e-9)
        check("swipe moves about every 16 ms", moves.count == 8 && zip(moves, moves.dropFirst()).allSatisfy { $1.at - $0.at <= 16 + 1e-9 })
        let swipe = GameKey(kind: .swipe, keyCode: 3, label: "F", x: 0.2, y: 0.5, toX: 0.6, toY: 0.1)
        var swiper = GameKeyEngine(keys: [swipe], aspect: 1)
        var played = swiper.keyDown(3, now: 0)
        _ = swiper.keyUp(3, now: 10)
        for t in stride(from: 8.0, through: 200, by: 8) { played += swiper.tick(now: t) }
        check("a swipe plays to its end and lifts", played.first?.kind == "tdown" && played.last?.kind == "tup"
              && near(played.last?.x, 0.6) && swiper.down.isEmpty && !swiper.needsTick)
        // Auto-fire at 10 a second.
        let fire = GameKey(kind: .tap, keyCode: 49, label: "Space", x: 0.5, y: 0.5, mode: .autoFire, rate: 10)
        var auto = GameKeyEngine(keys: [fire], aspect: 1)
        var shots = auto.keyDown(49, now: 0)
        for t in stride(from: 5.0, through: 995, by: 5) { shots += auto.tick(now: t) }
        check("auto-fire taps 10 times a second", shots.filter { $0.kind == "tdown" }.count == 10)
        let stop = auto.keyUp(49, now: 1000)
        check("auto-fire stops on key up with no finger down", auto.down.isEmpty && !auto.needsTick && auto.tick(now: 1200).isEmpty
              && (stop.isEmpty || stop.allSatisfy { $0.kind == "tup" }))
        // Hold toggle.
        var toggle = GameKeyEngine(keys: [GameKey(kind: .tap, keyCode: 49, label: "Space", x: 0.5, y: 0.5, mode: .toggle)], aspect: 1)
        let on = toggle.keyDown(49), letGo = toggle.keyUp(49)
        check("hold toggle stays down after the key is let go", on.first?.kind == "tdown" && letGo.isEmpty && toggle.down.count == 1 && toggle.held().count == 1)
        _ = toggle.keyDown(49)
        check("pressing again lets the toggle go", toggle.down.isEmpty)
        // Combos.
        var combo = GameKey(kind: .tap, keyCode: 14, label: "E", x: 0.5, y: 0.5, mode: .combo)
        combo.steps = [.init(kind: .tap, x: 0.1, y: 0.1), .init(kind: .wait, ms: 80), .init(kind: .tap, x: 0.2, y: 0.2),
                       .init(kind: .wait, ms: 50), .init(kind: .swipe, x: 0.3, y: 0.3, toX: 0.4, toY: 0.4, ms: 32)]
        let timeline = GameKeyEngine.comboTimeline(combo)
        check("combo taps in order with its waits", timeline[0] == .init(at: 0, kind: "tdown", x: 0.1, y: 0.1)
              && timeline[1].at == 40 && timeline[2] == .init(at: 120, kind: "tdown", x: 0.2, y: 0.2)
              && timeline[4].at == 210 && timeline[4].kind == "tdown" && timeline.last == .init(at: 242, kind: "tup", x: 0.4, y: 0.4))
        var comboEngine = GameKeyEngine(keys: [combo], aspect: 1)
        var comboEvents = comboEngine.keyDown(14, now: 0)
        _ = comboEngine.keyUp(14, now: 5)
        for t in stride(from: 8.0, through: 400, by: 8) { comboEvents += comboEngine.tick(now: t) }
        check("a combo plays every step and ends lifted", comboEvents.filter { $0.kind == "tdown" }.count == 3 && comboEngine.down.isEmpty)
        var cut = GameKeyEngine(keys: [swipe, combo, fire], aspect: 1)
        _ = cut.keyDown(3, now: 0); _ = cut.keyDown(14, now: 0); _ = cut.keyDown(49, now: 0)
        let all = cut.releaseAll()
        check("release all stops gestures and auto-fire, lifting every finger", !all.isEmpty && all.allSatisfy { $0.kind == "tup" }
              && cut.down.isEmpty && !cut.needsTick && cut.tick(now: 300).isEmpty)
        // The finger pool.
        let many = (0..<10).map { GameKey(kind: .tap, keyCode: UInt16(20 + $0), label: "\($0)", x: 0.5, y: 0.5) }
        var pool = GameKeyEngine(keys: many, aspect: 1)
        check("only 8 keys get a finger", pool.fingers.count == GameKeyEngine.fingerPool && Set(pool.fingers.values) == Set(0..<8))
        check("a key past the pool does nothing", pool.keyDown(29).isEmpty && !pool.handles(29))
        let model = GameKeysModel()
        model.preview(keys: Array(many.prefix(8)))
        model.editing = true
        model.pendTap(x: 0.3, y: 0.3)
        _ = model.assign(code: 40, label: "K")
        check("placing a ninth key is refused with a message", model.keys.count == 8 && model.message?.contains("No free finger") == true)
        model.placeJoystick(x: 0.2, y: 0.2)
        check("a joystick is refused too", model.joystickCount == 0)
        // Profiles saved by the older version still load.
        let old = #"[{"name":"PUBG","keys":[{"id":"9C1F0A57-1D7B-4C5B-9A3E-2F1C7D9E1A11","kind":"joystick","keyCode":0,"label":"WASD","x":0.2,"y":0.7,"radius":0.1},{"id":"9C1F0A57-1D7B-4C5B-9A3E-2F1C7D9E1A12","kind":"tap","keyCode":49,"label":"Space","x":0.9,"y":0.8,"radius":0.08}]}]"#
        let decoded = try? JSONDecoder().decode([GameProfile].self, from: Data(old.utf8))
        let keys = decoded?.first?.keys ?? []
        check("old profile JSON decodes with defaults", keys.count == 2 && keys[0].keySet == .wasd && keys[0].walk == .off
              && keys[1].mode == .tap && keys[1].rate == 10 && keys[1].steps.isEmpty && keys[1].duration == 120)
        check("new fields round-trip", (try? JSONDecoder().decode(GameKey.self, from: JSONEncoder().encode(combo))) == combo)
    }

    private static func testMenuBarLayout() {
        let suite = "dysklink.selftest.menubar"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let layout = MenuBarLayout(defaults: defaults)
        check("menu bar starts as before", layout.visible == [.devices, .displays, .awake, .layouts, .login])
        layout.setShown(.note, true)
        layout.move(.login, by: -1)
        layout.move(.devices, by: -1)
        let again = MenuBarLayout(defaults: defaults)
        check("menu bar keeps changes", again.isShown(.note) && again.order.first == .devices
              && again.order.firstIndex(of: .login)! + 1 == again.order.firstIndex(of: .note)!)
        defaults.set(["note", "devices"], forKey: "menubar.order")
        let upgraded = MenuBarLayout(defaults: defaults)
        check("menu bar adds new parts at the end", upgraded.order.prefix(2) == [.note, .devices] && upgraded.order.count == MenuBarLayout.Section.allCases.count)
        upgraded.reset()
        check("menu bar reset", upgraded.visible == MenuBarLayout.defaultShown)
        defaults.removePersistentDomain(forName: suite)
        let dragged = MenuBarLayout(defaults: defaults)
        dragged.reset()
        dragged.place(.login, at: .devices)
        check("dragging puts a part where another was", dragged.order.first == .login && dragged.order[1] == .devices)
        dragged.place(.login, at: .batteryLimit)
        check("dragging down moves it after the others", dragged.order.firstIndex(of: .login) == 2 && dragged.order[1] == .batteryLimit && dragged.order.first == .devices)
        dragged.reset()
    }

    private static func testPowerSplit() {
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
        // The case from the menu: the battery's lagging 12.05 W next to the Mac's 6.4 W.
        let battery = PowerSplit(PowerSample(adapterWatts: 0, batteryWatts: -12.05, systemWatts: 6.4, gpuWatts: 0.4))
        check("on battery the battery gives what the Mac uses", near(battery.battery, 6.4) && battery.charger == 0 && near(battery.total, 6.4))
        check("graphics and the rest add up to the total", near((battery.gpu ?? 0) + battery.rest + battery.charging, battery.total))
        let charging = PowerSplit(PowerSample(adapterWatts: 31, batteryWatts: 18, systemWatts: 9, gpuWatts: 1))
        check("charging: the charger covers the Mac and the battery", near(charging.total, 27) && near(charging.charger, 27) && charging.battery == 0
            && near(charging.charging, 18) && near((charging.gpu ?? 0) + charging.rest + charging.charging, charging.total))
        let mixed = PowerSplit(PowerSample(adapterWatts: 20, batteryWatts: -6, systemWatts: 23, gpuWatts: 4))
        check("mixed: the battery makes up what the charger doesn't", near(mixed.charger, 20) && near(mixed.battery, 3)
            && near(mixed.charger + mixed.battery, mixed.total) && mixed.isMixed)
        let losses = PowerSplit(PowerSample(adapterWatts: 12, batteryWatts: -0.5, systemWatts: 10))
        check("an adapter reading above the total leaves the battery at zero", near(losses.charger, 10) && losses.battery == 0 && !losses.isMixed)
        let held = PowerSplit(PowerSample(adapterWatts: 8, batteryWatts: 0.02, systemWatts: 7.5))
        check("plugged in and held: all from the charger", near(held.charger, 7.5) && held.charging == 0)
        let noSMC = PowerSplit(PowerSample(adapterWatts: 0, batteryWatts: -5, systemWatts: 0, gpuWatts: 9))
        check("without the system reading the sources set the total", near(noSMC.total, 5) && near(noSMC.gpu ?? 0, 5) && noSMC.rest == 0)
        let noise = PowerSplit(PowerSample(adapterWatts: 0.1, batteryWatts: 3, systemWatts: 6))
        check("no charging without a charger", noise.charging == 0 && near(noise.battery, 6))
    }

    private static func testBattery() {
        // From a MacBook Air: charging at 80% with a 30 W adapter.
        let sample: [String: Any] = [
            "CurrentCapacity": 80, "CycleCount": 163, "DesignCycleCount9C": 1000, "Voltage": 12401, "InstantAmperage": 1499,
            "IsCharging": true, "ExternalConnected": true, "FullyCharged": false, "AvgTimeToFull": 110, "AvgTimeToEmpty": 65535,
            "AdapterDetails": ["Watts": 30], "BatteryData": ["DesignCapacity": 4629, "NominalChargeCapacity": 4421, "FullChargeCapacity": 4294],
        ]
        let reading = BatteryHealth.parse(sample)
        check("battery parse", reading?.cycles == 163 && reading?.designMah == 4629 && reading?.fullMah == 4421
              && reading?.minutesToFull == 110 && reading?.minutesToEmpty == nil && reading?.adapterWatts == 30)
        check("battery measured health", reading?.measuredHealth == 96)
        check("battery status", reading?.status == "Charging with a 30 W adapter")
        check("battery power", abs((reading?.watts ?? 0) - 18.59) < 0.01)
        let json = Data(#"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_cycle_count":163,"sppower_battery_health":"Good","sppower_battery_health_maximum_capacity":"97%"}}]}"#.utf8)
        let apple = BatteryHealth.parseAppleHealth(json)
        check("battery apple health", apple.maxCapacity == 97 && apple.condition == "Good")
        if var reading {
            reading.appleMaxCapacity = 97
            let day1 = BatteryHistory.adding(reading, to: [], now: Date(timeIntervalSince1970: 1_790_000_000))
            let again = BatteryHistory.adding(reading, to: day1, now: Date(timeIntervalSince1970: 1_790_000_100))
            let next = BatteryHistory.adding(reading, to: again, now: Date(timeIntervalSince1970: 1_790_100_000))
            check("battery history one point a day", day1.count == 1 && again.count == 1 && next.count == 2 && next[0].health == 97)
        }
        if let live = BatteryHealth.read() {
            print("BATTERY live \(live.percent)% cycles=\(live.cycles) health=\(live.measuredHealth ?? -1) temp=\(live.temperatureC.map { String(format: "%.1f", $0) } ?? "none") \(live.status)")
        }
    }

    private static func testOneTimeCode() {
        let cases: [(String, String?)] = [
            ("Kode OTP Anda 482915. JANGAN berikan kode ini kepada siapa pun.", "482915"),
            ("<#> 123456 adalah kode verifikasi WhatsApp Anda.", "123456"),
            ("G-731942 is your Google verification code.", "731942"),
            ("Your code is 482-915", "482915"),
            ("Gunakan PIN 4821 untuk masuk. Berlaku s/d 10/11/2026 12:30", "4821"),
            ("JANGAN BERIKAN kode ini. Transaksi Rp 250000 kode: 99812734", "99812734"),
            ("Pembayaran Rp 150000 berhasil pada 10/11/2026", nil),
            ("Hubungi +628123456789 untuk info", nil),
            ("Rapat jam 14:30 di ruang 2026", nil),
        ]
        for (text, expected) in cases {
            check("code in \"\(text.prefix(30))\"", OneTimeCode.find(in: text) == expected)
        }
        check("code spaced", CodeBanner.spaced("482915") == "482 915")
    }

    private static func testMacCare(_ folder: URL) {
        let fm = FileManager.default
        let home = folder.appendingPathComponent("care-home")
        func write(_ path: String, _ data: Data, modified: Date? = nil) {
            let url = home.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
            if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        }
        let mb = Data(repeating: 7, count: 1_000_000)
        let old = Date().addingTimeInterval(-200 * 86_400)

        // Cleaner
        write("Library/Caches/com.example.app/blob", mb)
        write("Library/Caches/id.dysklink.mac/blob", mb)
        write("Library/Logs/tiny.log", Data(repeating: 1, count: 100))
        write("Library/Developer/Xcode/DerivedData/Proj/x", mb)
        write("Downloads/Setup.dmg", Data(repeating: 2, count: 2_000))
        write("Downloads/old.zip", Data(repeating: 3, count: 3_000), modified: old)
        write("Downloads/new.txt", Data(repeating: 4, count: 3_000))
        write("Movies/big.mov", mb + mb)
        write("Library/big-hidden.bin", mb + mb)
        let groups = Cleaner.scan(home: home, lastUsed: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate })
        check("a cache folder is found", groups[.caches]?.map(\.name) == ["com.example.app"])
        check("DyskLink's own cache is left alone", groups[.caches]?.contains { $0.name.hasPrefix("id.dysklink") } == false)
        check("tiny logs are skipped", groups[.logs]?.isEmpty == true)
        check("Xcode build data is found", groups[.developer]?.map(\.name) == ["DerivedData"])
        check("an installer in Downloads is found", groups[.installers]?.map(\.name) == ["Setup.dmg"])
        check("only old downloads are listed", groups[.oldDownloads]?.map(\.name) == ["old.zip"])
        let large = Cleaner.largeFiles(home: home, minimum: 1_500_000)
        check("large files skip Library", large.map(\.name) == ["big.mov"])
        check("sizes count what's on disk", MacCare.size(of: home.appendingPathComponent("Library/Caches/com.example.app")) >= 1_000_000)

        // Duplicates
        let content = Data((0..<200_000).map { UInt8($0 % 251) })
        var sameStart = content
        sameStart[199_999] = 9
        write("Dups/a.bin", content)
        write("Dups/inner/a-copy.bin", content)
        write("Dups/same-start.bin", sameStart)
        write("Dups/other.bin", Data(repeating: 5, count: 200_000))
        let dupsFolder = home.appendingPathComponent("Dups")
        let found = Duplicates.find(in: [dupsFolder, dupsFolder, dupsFolder.appendingPathComponent("inner")], minimum: 100_000)
        check("one set of copies is found", found.count == 1)
        check("the copies are the matching files", Set(found.first?.files.map(\.name) ?? []) == ["a.bin", "a-copy.bin"])
        check("same start but a different end isn't a copy", found.first?.files.contains { $0.name == "same-start.bin" } == false)
        check("the extra space is counted once per copy", found.first?.wasted == 200_000)
        check("small files are skipped", Duplicates.find(in: [dupsFolder], minimum: 300_000).isEmpty)
        write("Dups-links/x.bin", Data(repeating: 11, count: 200_000))
        try? fm.linkItem(at: home.appendingPathComponent("Dups-links/x.bin"), to: home.appendingPathComponent("Dups-links/x-link.bin"))
        check("hard links of one file aren't copies", Duplicates.find(in: [home.appendingPathComponent("Dups-links")], minimum: 100_000).isEmpty)
        write("Dups-clones/y.bin", Data((0..<300_000).map { UInt8($0 % 241) }))
        let clone = home.appendingPathComponent("Dups-clones/y-clone.bin")
        // FileManager copies are APFS clones, which share their blocks.
        try? fm.copyItem(at: home.appendingPathComponent("Dups-clones/y.bin"), to: clone)
        let clones = Duplicates.find(in: [home.appendingPathComponent("Dups-clones")], minimum: 100_000)
        if Duplicates.privateSize(clone) != nil {
            check("an APFS clone frees nothing, so it isn't counted as wasted", clones.count == 1 && (clones.first?.wasted ?? .max) < 100_000)
        } else {
            print("SKIP clone check: this disk doesn't report private sizes")
        }

        // Uninstall
        func app(_ path: String, _ id: String) {
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "2.1", "CFBundleName": "x"]
            let url = home.appendingPathComponent(path + "/Contents")
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url.appendingPathComponent("Info.plist"), atomically: true)
        }
        app("Applications/Foo.app", "com.foo.app")
        app("Applications/Tools/Bar.app", "com.bar.app")
        app("Applications/Safari Copy.app", "com.apple.Safari")
        app("Applications/DyskLink.app", "id.dysklink.mac")
        app("Applications/Shouty.app", "COM.APPLE.Mail")
        app("Applications/Root.app", "com.apple")
        check("Apple's IDs are recognized in any case", Uninstaller.isAppleBundleId("com.apple.Safari") && Uninstaller.isAppleBundleId("COM.Apple.mail")
              && Uninstaller.isAppleBundleId("com.apple") && !Uninstaller.isAppleBundleId("com.applesauce.x") && !Uninstaller.isAppleBundleId("org.com.apple"))
        let apps = Uninstaller.apps(in: [home.appendingPathComponent("Applications")])
        check("apps are listed, also inside folders", apps.map(\.name) == ["Bar", "Foo"])
        write("Library/Preferences/com.foo.app.plist", Data([1]))
        write("Library/Caches/com.foo.app/c", Data([1]))
        write("Library/Group Containers/TEAM123.com.foo.app/g", Data([1]))
        write("Library/Application Support/Foo/data", Data([1]))
        write("Library/Application Support/com.foobar/data", Data([1]))
        write("Library/LaunchAgents/com.foo.app.helper.plist", Data([1]))
        let leftovers = apps.first { $0.name == "Foo" }.map { Uninstaller.leftovers(for: $0, home: home) } ?? []
        check("leftovers with the app's ID are found", Set(leftovers.filter(\.byId).map(\.item.name)) ==
              ["com.foo.app.plist", "com.foo.app", "TEAM123.com.foo.app", "com.foo.app.helper.plist"])
        check("a folder with the same name is only suggested", leftovers.filter { !$0.byId }.map(\.item.name) == ["Foo"])
        check("a similar ID isn't a leftover", !leftovers.contains { $0.item.name == "com.foobar" })
        // The disk ignores case, so a folder that differs only in case would be found by a made-up path.
        write("Library/Application Support/COM.CASE.APP/data", Data([1]))
        write("Library/Caches/com.case.app/c", Data([1]))
        let cased = InstalledApp(url: home.appendingPathComponent("Applications/Case.app"), name: "Cs", bundleId: "com.case.app", version: "")
        check("leftovers match the exact name, case included",
              Uninstaller.leftovers(for: cased, home: home).map(\.item.name) == ["com.case.app"])
        check("plain bundle IDs are safe", Uninstaller.isSafeBundleId("com.foo.app") && Uninstaller.isSafeBundleId("A1-b.c"))
        check("dangerous bundle IDs are refused", [".", "..", "../..", "com/../x", "a..b", ".hidden", "-x", "", "a b", "a/b", "ü.x"]
              .allSatisfy { !Uninstaller.isSafeBundleId($0) })
        let evil = InstalledApp(url: home.appendingPathComponent("Applications/Evil.app"), name: "Ev", bundleId: "..", version: "")
        check("an app with the ID .. leaves no leftovers", Uninstaller.leftovers(for: evil, home: home).isEmpty)
        let dot = InstalledApp(url: home.appendingPathComponent("Applications/Dot.app"), name: "Do", bundleId: ".", version: "")
        check("an app with the ID . leaves no leftovers", Uninstaller.leftovers(for: dot, home: home).isEmpty)
        let caches = home.appendingPathComponent("Library/Caches")
        check("a leftover must sit right inside its folder",
              Uninstaller.isDirectlyInside(caches.appendingPathComponent("com.foo.app"), folder: caches)
              && !Uninstaller.isDirectlyInside(caches.appendingPathComponent("a/b"), folder: caches)
              && !Uninstaller.isDirectlyInside(caches.appendingPathComponent(".."), folder: caches)
              && !Uninstaller.isDirectlyInside(caches, folder: caches))
        // A linked folder in the way of the path doesn't count as the folder itself.
        try? fm.createDirectory(at: home.appendingPathComponent("Library/Elsewhere"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: caches.appendingPathComponent("linked"), withDestinationURL: home.appendingPathComponent("Library/Elsewhere"))
        check("a path through a linked folder is refused", !Uninstaller.isDirectlyInside(caches.appendingPathComponent("linked/x"), folder: caches))
        if let foo = apps.first(where: { $0.name == "Foo" }) {
            app("Applications/Copy/Foo.app", "com.foo.app")
            let copy = home.appendingPathComponent("Applications/Copy/Foo.app")
            check("another copy with the same ID is found", Uninstaller.otherCopies(of: foo, listed: [copy, foo.url]).map(\.lastPathComponent) == ["Foo.app"])
            check("the app itself isn't another copy",
                  !Uninstaller.otherCopies(of: foo, listed: [foo.url]).contains { $0.standardizedFileURL == foo.url.standardizedFileURL })
        }

        // Startup
        let agent: [String: Any] = ["Label": "com.foo.agent", "ProgramArguments": ["/Applications/Foo.app/Contents/MacOS/helper", "--quiet"], "RunAtLoad": true]
        try? fm.removeItem(at: home.appendingPathComponent("Library/LaunchAgents"))
        try? fm.createDirectory(at: home.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
        (agent as NSDictionary).write(to: home.appendingPathComponent("Library/LaunchAgents/com.foo.agent.plist"), atomically: true)
        let noSystem = folder.appendingPathComponent("care-system")
        var calls: [[String]] = []
        let fake: Startup.Launchctl = { calls.append($0); return 0 }
        let items = Startup.items(home: home, system: noSystem)
        check("a startup agent is read", items.map(\.label) == ["com.foo.agent"] && items.first?.runsAtLoad == true)
        check("the agent's app is known", items.first?.appName == "Foo")
        if let item = items.first {
            _ = try? Startup.turnOff(item, home: home, run: fake)
            let off = Startup.items(home: home, system: noSystem)
            check("turning off stops it and moves it aside", calls.first?.first == "bootout" && off.first?.isOff == true
                  && !fm.fileExists(atPath: item.url.path))
            if let offItem = off.first { _ = try? Startup.turnOn(offItem, home: home, run: fake) }
            let on = Startup.items(home: home, system: noSystem)
            check("turning on puts it back and starts it", calls.last?.first == "bootstrap" && on.first?.isOff == false
                  && fm.fileExists(atPath: item.url.path))
        }
    }

    private static func testHistory(_ folder: URL) {
        let board = NSPasteboard(name: NSPasteboard.Name("dysklink.selftest"))
        defer { board.releaseGlobally() }
        let suite = "id.phonelink.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ClipboardHistory(directory: folder, defaults: defaults)

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

        check("the default limit is 200 items and 30 images", history.maxEntries == 200 && history.maxImages == 30)
        for index in 0..<(history.maxEntries + 20) { history.add(text: "isi \(index)") }
        check("the limit holds", history.entries.filter { !$0.isPinned }.count == history.maxEntries)
        check("a pinned entry survives the limit", history.entries.contains { $0.text == "kedua" })
        check("trimmed images are deleted", file.map { !FileManager.default.fileExists(atPath: $0.path) } == true)

        history.saveNow()
        let reloaded = ClipboardHistory(directory: folder, defaults: defaults)
        check("history reloads from disk", reloaded.entries == history.entries)

        let lower = history.removedCount(maxEntries: 50, maxImages: 30)
        check("a lower limit counts what it removes", lower == 150)
        let newest = history.entries.first { !$0.isPinned }
        history.setLimits(maxEntries: 50, maxImages: 30)
        check("a lower limit keeps the newest", history.entries.filter { !$0.isPinned }.count == 50
            && history.entries.first { !$0.isPinned } == newest)
        check("a lower limit keeps pinned items", history.entries.contains { $0.text == "kedua" })
        check("a higher limit removes nothing", history.removedCount(maxEntries: 1000, maxImages: 100) == 0)
        history.setLimits(maxEntries: 75, maxImages: 30)
        check("a value outside the choices is refused", history.maxEntries == 50)
        let restored = ClipboardHistory(directory: folder, defaults: defaults)
        check("limits are remembered", restored.maxEntries == 50 && restored.maxImages == 30)
        let pictures = (0..<3).map { ClipEntry(imageFile: "\($0).png") }
        check("the image limit is separate", ClipboardHistory.trimmed(pictures, maxEntries: 50, maxImages: 2).removed.map(\.imageFile) == ["2.png"])
        let store = folder.appendingPathComponent("clipboard-history.json").path
        let mode = (try? FileManager.default.attributesOfItem(atPath: store))?[.posixPermissions] as? Int
        check("the history file is private to this user", mode == 0o600)

        reloaded.clearUnpinned()
        check("clearing keeps pinned entries", reloaded.entries.map(\.text) == ["kedua"])
    }

    private static func testFirewallCheck() {
        check("firewall: block all on", FirewallCheck.parse(blockAll: "Firewall has block all state set to enabled.", app: "") == .blocksAll)
        check("firewall: older block all wording", FirewallCheck.parse(blockAll: "Block all INCOMING connections ENABLED!", app: "") == .blocksAll)
        check("firewall: block all off", FirewallCheck.parse(blockAll: "Firewall has block all state set to disabled.", app: "Incoming connection to /Applications/DyskLink.app is permitted.") == nil)
        check("firewall: app blocked", FirewallCheck.parse(blockAll: "Firewall has block all state set to disabled.", app: "Incoming connection to /Applications/DyskLink.app is blocked.") == .blocksApp)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("dysk-none-\(UUID().uuidString)")
        check("a missing folder isn't reported as blocked", MacCare.unreadable([missing, FileManager.default.temporaryDirectory]).isEmpty)
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
        let checked = Date(timeIntervalSince1970: 2_000_000)
        check("a check that worked runs again a day later",
              abs(UpdateChecker.nextDelay(lastSuccess: checked, lastAttempt: checked, failures: 0, now: checked) - 86_400) < 1)
        check("the first check after launch waits 15 s", UpdateChecker.nextDelay(lastSuccess: nil, lastAttempt: nil, failures: 0, now: checked) == 15)
        check("a failed check is tried again after an hour",
              abs(UpdateChecker.nextDelay(lastSuccess: nil, lastAttempt: checked, failures: 1, now: checked.addingTimeInterval(60)) - 3540) < 1)
        check("failures in a row wait longer, up to a day",
              abs(UpdateChecker.nextDelay(lastSuccess: nil, lastAttempt: checked, failures: 2, now: checked) - 7200) < 1
              && abs(UpdateChecker.nextDelay(lastSuccess: nil, lastAttempt: checked, failures: 9, now: checked) - 86_400) < 1)
        check("a failed check never retries every few seconds",
              UpdateChecker.nextDelay(lastSuccess: checked.addingTimeInterval(-200_000), lastAttempt: checked, failures: 1, now: checked) >= 3600)
        check("prayer times back off after failures", PrayerModel.retryDelay(failures: 0) == 0 && PrayerModel.retryDelay(failures: 1) == 120
              && PrayerModel.retryDelay(failures: 2) == 240 && PrayerModel.retryDelay(failures: 30) == 3600)
        check("newer patch", UpdateChecker.isNewer("v0.1.3", than: "0.1.2"))
        check("same version isn't newer", !UpdateChecker.isNewer("0.1.2", than: "0.1.2"))
        check("older isn't newer", !UpdateChecker.isNewer("0.1.10", than: "0.1.11"))
        check("numbers compare as numbers", UpdateChecker.isNewer("0.1.10", than: "0.1.9"))
        check("missing parts count as zero", !UpdateChecker.isNewer("0.2", than: "0.2.0") && UpdateChecker.isNewer("0.2.1", than: "0.2"))
        check("odd tags are ignored", !UpdateChecker.isNewer("nightly", than: "0.1.0"))
        let releases = Data(#"[{"tag_name":"v0.1.2","html_url":"https://example.com/2","draft":false},{"tag_name":"v0.2.0","html_url":"https://example.com/9","draft":true},{"tag_name":"v0.1.10","html_url":"https://example.com/10","draft":false},{"tag_name":"v0.1.3","html_url":"https://example.com/3","prerelease":true}]"#.utf8)
        check("picks the highest published release", (try? UpdateChecker.newest(in: releases, newerThan: "0.1.2"))??.version == "0.1.10")
        check("nothing newer gives nothing", (try? UpdateChecker.newest(in: releases, newerThan: "0.1.10")) == .some(nil))
        check("battery under the limit is noticed", AwakeDecision.isBelow(battery, limit: 20))
        check("battery above the limit is fine", !AwakeDecision.isBelow(battery, limit: 10))
        check("plugged in is never below", !AwakeDecision.isBelow(mains, limit: 20))
        check("no limit is never below", !AwakeDecision.isBelow(battery, limit: 0))
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
        let data = ProcessRunner.run("/usr/bin/pmset", ["-g", "assertions"])?.output ?? Data()
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
        check("EDID vendor letters become CoreGraphics' number", MonitorIdentity.eisaVendor("GSM") == 0x1E6D && MonitorIdentity.eisaVendor("g1m") == nil)
        let lg = MonitorIdentity(vendor: 0x1E6D, product: 23305, serial: 111)
        let dell = MonitorIdentity(vendor: 0x10AC, product: 41200, serial: 7)
        check("one monitor and one service go together", MonitorMatch.assign(screens: [(5, MonitorIdentity())], services: [MonitorIdentity()]) == [5: 0])
        check("two monitors are matched by their EDID, not by order",
              MonitorMatch.assign(screens: [(5, dell), (6, lg)], services: [lg, dell]) == [5: 1, 6: 0])
        let twinA = MonitorIdentity(vendor: 0x1E6D, product: 23305, serial: 0)
        check("two identical monitors without serials aren't guessed",
              MonitorMatch.assign(screens: [(5, twinA), (6, twinA)], services: [twinA, twinA]).isEmpty)
        check("serials tell identical models apart",
              MonitorMatch.assign(screens: [(5, lg), (6, MonitorIdentity(vendor: 0x1E6D, product: 23305, serial: 222))],
                                  services: [MonitorIdentity(vendor: 0x1E6D, product: 23305, serial: 222), lg]) == [5: 1, 6: 0])
        check("services that say nothing aren't guessed with two monitors",
              MonitorMatch.assign(screens: [(5, lg), (6, dell)], services: [MonitorIdentity(), MonitorIdentity()]).isEmpty)
        let sidecar = MonitorIdentity(vendor: 0x610, product: 0xA050, serial: 0)
        let lgService = MonitorIdentity(vendor: 0x1E6D, product: 23305)
        let withSidecar = MonitorMatch.assign(screens: [(5, lg), (6, sidecar)], services: [lgService])
        check("a monitor beside a Sidecar screen gets the one service", withSidecar == [5: 0])
        check("a Sidecar screen isn't counted as unmatched",
              MonitorMatch.unmatched(screens: [(5, lg), (6, sidecar)], services: [lgService], assigned: withSidecar) == 0
              && MonitorMatch.unmatched(screens: [(5, twinA), (6, twinA)], services: [twinA, twinA], assigned: [:]) == 2
              && MonitorMatch.unmatched(screens: [(6, sidecar)], services: [], assigned: [:]) == 0)
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
        let corner: (x: Float, y: Float) = (0.1, 0.2)
        let unturned = ScreenSurface.phonePoint(corner, quarterTurns: 0)
        check("an unturned picture maps straight through", unturned.x == 0.1 && unturned.y == 0.2)
        // Turned clockwise, the phone's top left corner appears at the top right.
        let turnedRight = ScreenSurface.phonePoint((1, 0), quarterTurns: 1)
        check("a quarter turn maps the top right to the phone's top left", turnedRight.x == 0 && turnedRight.y == 0)
        let upside = ScreenSurface.phonePoint((1, 1), quarterTurns: 2)
        check("a half turn maps the bottom right to the phone's top left", upside.x == 0 && upside.y == 0)
        let turnedLeft = ScreenSurface.phonePoint((0, 1), quarterTurns: 3)
        check("three quarter turns map the bottom left to the phone's top left", turnedLeft.x == 0 && turnedLeft.y == 0)
        var roundTrip = true
        for turns in 0..<4 {
            var point = corner
            for _ in 0..<4 { point = ScreenSurface.phonePoint(point, quarterTurns: turns) }
            roundTrip = roundTrip && abs(point.x - corner.x) < 0.0001 && abs(point.y - corner.y) < 0.0001
        }
        check("four of the same turn come back to the start", roundTrip)
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
        check("letting go of Option chooses while open", SwitcherKeys.releaseCommits(flags: [], isOpen: true))
        check("Option still held or the switcher closed doesn't choose",
              !SwitcherKeys.releaseCommits(flags: .maskAlternate, isOpen: true) && !SwitcherKeys.releaseCommits(flags: [], isOpen: false))
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
        check("a camera makes the panel taller by its height", model.openSize.height == 225)
        model.hasNotch = false
        check("no camera needs no extra room", model.openSize.height == 189)
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
        model.togglePomodoro()
        check("a running timer still shows with the bar hidden", model.closedHeight(statusHeight: 24) == 30)
        model.screenWatchers = ["Pixel"]
        check("a phone viewing the screen shows under the notch", model.closedHeight(statusHeight: 24) == 30 && model.watchText == "Pixel is viewing")
        model.screenWatchers = []
        model.resetPomodoro()
        model.hidesBar = wasHiding
        let savedSettings = model.pomodoroSettings
        let savedSound = model.playsPomodoroSound
        let savedHidden = model.hiddenSections
        model.pomodoroSettings = PomodoroSettings()
        check("focus starts idle", !model.isFocusing && model.focusText == "25:00")
        model.togglePomodoro()
        check("focus counts down", model.isFocusing && (model.focusText == "25:00" || model.focusText == "24:59"))
        model.togglePomodoro()
        check("focus pauses", !model.isFocusing && model.pomodoro.isStarted)
        model.resetPomodoro()
        check("focus resets", !model.pomodoro.isStarted)

        model.pomodoroSettings.focusMinutes = 50
        check("new lengths apply to an idle timer", model.focusText == "50:00")
        model.togglePomodoro()
        model.pomodoroSettings.focusMinutes = 30
        check("a started cycle keeps its lengths", model.pomodoro.settings.focusMinutes == 50)
        model.resetPomodoro()
        check("a reset uses the new lengths", model.focusText == "30:00")

        NotchModel.Section.allCases.forEach { model.setShown($0, true) }
        model.page = .music
        model.setShown(.music, false)
        check("hiding the open page moves to the next one", model.page == .focus && model.pages == [.focus, .shelf, .todo, .water, .note])
        model.togglePomodoro()
        model.setShown(.pomodoro, false)
        check("hiding Pomodoro stops its timer", !model.isFocusing && model.page == .shelf)
        model.shelfMode = .files
        model.setShown(.files, false)
        check("the shelf shows clipboard alone", model.shelfMode == .clipboard && !model.hasShelfSwitch && model.pages == [.shelf, .todo, .water, .note])
        model.setShown(.todo, false)
        model.setShown(.water, false)
        model.setShown(.note, false)
        check("the last section can't be hidden", !model.canHide(.clipboard))
        model.setShown(.clipboard, false)
        check("the panel keeps one page", model.isShown(.clipboard) && model.pages == [.shelf])
        NotchModel.Section.allCases.forEach { model.setShown($0, !savedHidden.contains($0)) }
        NotchModel.Section.allCases.forEach { model.setShown($0, !savedHidden.contains($0)) }
        model.pomodoroSettings = savedSettings
        model.playsPomodoroSound = savedSound
        check("the settings are put back", model.hiddenSections == savedHidden && model.pomodoroSettings == savedSettings)
        testPomodoro()
        testBrowserMedia()
        let folderToSend = folder.appendingPathComponent("send-folder")
        try? FileManager.default.createDirectory(at: folderToSend, withIntermediateDirectories: true)
        let fileToSend = folder.appendingPathComponent("send.txt")
        try? Data("hi".utf8).write(to: fileToSend)
        check("only files are sent to the phone",
              NotchView.sendable([fileToSend, folderToSend, folder.appendingPathComponent("gone.txt")]) == [fileToSend])
    }

    private static func testBrowserMedia() {
        let firefox = BrowserMedia.video(fromWindowTitle: "Lofi Beats to Study - YouTube — Mozilla Firefox")
        check("a Firefox YouTube window is read", firefox == .init(title: "Lofi Beats to Study", artist: nil, isMusic: false))
        check("a Chrome or Safari title is read",
              BrowserMedia.video(fromWindowTitle: "Paper Birds - YouTube")?.title == "Paper Birds"
              && BrowserMedia.video(fromWindowTitle: "Paper Birds - YouTube - Google Chrome")?.title == "Paper Birds")
        check("the notification count is dropped", BrowserMedia.video(fromWindowTitle: "(12) Rain - Live - YouTube")?.title == "Rain - Live")
        check("YouTube Music gives the artist",
              BrowserMedia.video(fromWindowTitle: "Paper Birds • Sample Artist - YouTube Music — Mozilla Firefox")
              == .init(title: "Paper Birds", artist: "Sample Artist", isMusic: true))
        check("the YouTube home page and other sites are skipped",
              BrowserMedia.video(fromWindowTitle: "YouTube — Mozilla Firefox") == nil
              && BrowserMedia.video(fromWindowTitle: "Why YouTube - YouTube fans love it - Blog") == nil
              && BrowserMedia.video(fromWindowTitle: "Inbox - Mail") == nil)
        let windows = [
            BrowserMedia.Window(bundleID: "com.apple.Safari", appName: "Safari", title: "Old Video - YouTube"),
            BrowserMedia.Window(bundleID: "org.mozilla.firefox", appName: "Firefox", title: "New Song - YouTube — Mozilla Firefox"),
        ]
        let playing = BrowserMedia.choose(windows, audible: ["org.mozilla.firefox"])
        check("the browser making sound wins", playing?.title == "New Song" && playing?.isPlaying == true
              && playing?.artist == "YouTube in Firefox")
        check("a silent video shows as paused", BrowserMedia.choose(windows, audible: [])?.isPlaying == false)
        check("Safari plays through WebKit", BrowserMedia.isAudible("com.apple.Safari", in: ["com.apple.WebKit.GPU"])
              && BrowserMedia.isAudible("com.google.Chrome", in: ["com.google.Chrome.helper"])
              && !BrowserMedia.isAudible("com.google.Chrome", in: ["com.google.ChromeX"]))
    }

    private static func testPomodoro() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var timer = Pomodoro()
        check("a cycle is four rounds and a long break, 2 h 10 min", timer.steps.count == 8
            && timer.steps.last?.phase == .longBreak && timer.settings.cycleLength == 7800)
        let short = PomodoroSettings(focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 30, sessions: 2)
        check("a custom cycle has its own steps", short.steps.map(\.phase) == [.focus, .shortBreak, .focus, .longBreak]
            && short.cycleLength == 8400)
        check("odd stored lengths fall back to the defaults",
              PomodoroSettings(focusMinutes: 7, shortBreakMinutes: 5, longBreakMinutes: 99, sessions: 40).checked == PomodoroSettings())
        check("an idle timer shows a full round", !timer.isStarted && timer.remaining(at: start) == 1500
            && timer.remainingInCycle(at: start) == 7800)
        timer.start(at: start)
        check("a running round counts down", timer.remaining(at: start.addingTimeInterval(60)) == 1440)
        timer.pause(at: start.addingTimeInterval(60))
        check("a paused round keeps its time", timer.remaining(at: start.addingTimeInterval(600)) == 1440
            && timer.isStarted && !timer.isRunning)
        timer.start(at: start.addingTimeInterval(600))
        check("a round doesn't end early", timer.advance(at: start.addingTimeInterval(2039)) == nil)
        check("the end of focus starts a short break", timer.advance(at: start.addingTimeInterval(2040)) == .focus
            && timer.phase == .shortBreak && timer.remaining(at: start.addingTimeInterval(2040)) == 300)
        check("the end of a break starts the next round", timer.advance(at: start.addingTimeInterval(2340)) == .shortBreak
            && timer.phase == .focus && timer.session == 2 && timer.stepIndex == 2)
        var finished = 0
        for _ in 0..<timer.steps.count where timer.advance(at: start.addingTimeInterval(20_000)) != nil { finished += 1 }
        check("a Mac that slept catches up and ends the cycle", finished == 6 && !timer.isStarted && !timer.isRunning)
        check("a long time reads in hours", NotchView.duration(7800) == "2 h 10 min" && NotchView.duration(600) == "10 min")
        let now = Date()
        check("a fresh copy reads just now", NotchView.ago(now.addingTimeInterval(-30), now: now) == "Just now")
        check("an older copy reads in minutes", NotchView.ago(now.addingTimeInterval(-150), now: now) == "2 min ago")
        let paused = NowPlaying(title: "A", artist: "B", isPlaying: false, duration: 200, position: 10, positionDate: now)
        let started = NowPlaying(title: "A", artist: "B", isPlaying: true, duration: 200, position: 10, positionDate: now)
        let stopped = started.toggled(at: now.addingTimeInterval(5))
        check("a click pauses the song where it is", !stopped.isPlaying && stopped.elapsed(at: now.addingTimeInterval(60)) == 15)
        check("a second click plays it on", stopped.toggled(at: now.addingTimeInterval(60)).isPlaying)
        check("a paused song stays put", paused.elapsed(at: now.addingTimeInterval(30)) == 10)
        let playing = NowPlaying(title: "A", artist: "B", isPlaying: true, duration: 200, position: 10, positionDate: now)
        check("a playing song moves on", playing.elapsed(at: now.addingTimeInterval(5)) == 15)
        check("a song never passes its end", playing.elapsed(at: now.addingTimeInterval(500)) == 200)
        check("Music sends no position", NowPlaying(title: "A", artist: "B", isPlaying: true, duration: 200).elapsed(at: now) == nil)
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

#if DEBUG
@MainActor
extension ToolsSelfTest {
    fileprivate static func moment(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func testPrayerAndWeather() {
        let jakarta = PrayerLocation(province: "DKI Jakarta", city: "Kota Jakarta")
        let json = Data(#"""
        {"code":200,"data":{"provinsi":"DKI Jakarta","kabkota":"Kota Jakarta","bulan":11,"tahun":2026,"jadwal":[
         {"tanggal":9,"tanggal_lengkap":"2026-11-09","imsak":"03:58","subuh":"04:08","terbit":"05:23","dhuha":"05:51","dzuhur":"11:40","ashar":"14:56","maghrib":"17:50","isya":"19:01"},
         {"tanggal":10,"tanggal_lengkap":"2026-11-10","imsak":"03:58","subuh":"04:07","terbit":"05:23","dhuha":"05:51","dzuhur":"11:40","ashar":"14:56","maghrib":"17:50","isya":"19:02"}]}}
        """#.utf8)
        guard let month = try? PrayerAPI.month(from: json, location: jakarta) else { return check("prayer month parses", false) }
        check("prayer month parses", month.days.count == 2 && month.month == 11 && month.days[0].isya == "19:01")
        let schedule = PrayerSchedule(location: jakarta, months: [month])
        let midday = schedule.upcoming(after: moment("2026-11-09T10:00:00+07:00"))
        check("next prayer before noon is Dzuhur", midday?.prayer == .dzuhur && midday?.time == moment("2026-11-09T11:40:00+07:00"))
        check("its progress starts at Subuh", midday?.previous == moment("2026-11-09T04:08:00+07:00"))
        let evening = schedule.upcoming(after: moment("2026-11-09T20:00:00+07:00"))
        check("after Isya the next is tomorrow's Subuh", evening?.prayer == .subuh && evening?.time == moment("2026-11-10T04:07:00+07:00"))
        check("and it starts from today's Isya", evening?.previous == moment("2026-11-09T19:01:00+07:00"))
        let dawn = schedule.upcoming(after: moment("2026-11-09T03:00:00+07:00"))
        check("before Subuh the next is today's Subuh", dawn?.prayer == .subuh && dawn?.previous == nil)
        check("a day that isn't loaded gives nothing", schedule.upcoming(after: moment("2026-11-20T10:00:00+07:00")) == nil)
        check("the last day needs tomorrow loaded", schedule.upcoming(after: moment("2026-11-10T20:00:00+07:00")) == nil)
        let onTime = schedule.due(at: moment("2026-11-09T11:40:30+07:00"), early: false)
        check("the on-time alert is the prayer that just came", onTime?.prayer == .dzuhur && onTime?.time == moment("2026-11-09T11:40:00+07:00"))
        check("no on-time alert long after", schedule.due(at: moment("2026-11-09T11:45:00+07:00"), early: false) == nil)
        check("no on-time alert before the time", schedule.due(at: moment("2026-11-09T11:39:30+07:00"), early: false) == nil)
        check("the early alert comes ten minutes before",
              schedule.due(at: moment("2026-11-09T11:30:20+07:00"), early: true)?.prayer == .dzuhur
              && schedule.due(at: moment("2026-11-09T11:40:10+07:00"), early: true) == nil)
        check("the schedule ignores other cities", PrayerSchedule(location: PrayerLocation(province: "Bali", city: "Kota Denpasar"), months: [month]).days.isEmpty)
        check("time zones follow the province",
              PrayerLocation(province: "Bali", city: "x").timeZone.identifier == "Asia/Makassar"
              && PrayerLocation(province: "Papua", city: "x").timeZone.identifier == "Asia/Jayapura"
              && jakarta.timeZone.identifier == "Asia/Jakarta")
        check("city labels drop Kota and Kab.", jakarta.label == "Jakarta" && PrayerLocation(province: "x", city: "Kab. Bogor").label == "Bogor")
        check("provinces parse", (try? PrayerAPI.provinces(from: Data(#"{"code":200,"data":["Aceh","Bali"]}"#.utf8))) == ["Aceh", "Bali"])

        let forecast = Data(#"""
        {"current":{"time":"2026-11-09T13:30","temperature_2m":31.6,"weather_code":51,"is_day":1},
         "daily":{"time":["2026-11-09","2026-11-10"],"weather_code":[53,81],"temperature_2m_max":[32.4,31.0],
                  "temperature_2m_min":[21.4,20.3],"precipitation_probability_max":[92,null]}}
        """#.utf8)
        let report = try? WeatherAPI.report(from: forecast)
        check("forecast parses", report?.temperature == 31.6 && report?.isDay == true && report?.days.count == 2)
        check("a missing rain chance counts as zero", report?.days.last?.rainChance == 0 && report?.days.first?.rainChance == 92)
        let places = try? WeatherAPI.places(from: Data(#"{"results":[{"name":"Kota Bandung","admin1":"Jawa Barat","latitude":-6.92,"longitude":107.6}]}"#.utf8))
        check("places parse", places?.first?.label == "Kota Bandung, Jawa Barat" && places?.first?.shortName == "Bandung")
        check("no results is an empty list", (try? WeatherAPI.places(from: Data(#"{"generationtime_ms":0.5}"#.utf8))) == [])
        check("weather codes have words and symbols", WeatherAPI.describe(95) == "Thunderstorm" && WeatherAPI.symbol(0, isDay: false) == "moon.stars.fill")
        let weather = WeatherModel(isInert: true)
        let saved = weather.usesFahrenheit
        weather.usesFahrenheit = false
        let celsius = weather.degrees(31.6)
        weather.usesFahrenheit = true
        let fahrenheit = weather.degrees(31.6)
        weather.usesFahrenheit = saved
        testTodo()
        testWater()
        var alerts = PhoneBatteryAlerts()
        func battery(_ percent: Int?, _ charging: Bool?) -> PhoneBatteryAlerts.Alert? {
            alerts.update(peer: "hp", percent: percent, isCharging: charging, limit: 20)
        }
        check("a healthy phone gives no warning", battery(80, false) == nil)
        check("falling to the limit warns once", battery(20, false) == .low(20) && battery(19, false) == nil && battery(15, false) == nil)
        check("a small recovery doesn't repeat it", battery(24, false) == nil && battery(18, false) == nil)
        check("charging clears the low warning", battery(30, true) == nil && battery(19, false) == .low(19))
        check("recovering well above the limit clears it", battery(26, false) == nil && battery(20, false) == .low(20))
        check("full while charging warns once", battery(100, true) == .full && battery(100, true) == nil)
        check("unplugging and charging to full warns again", battery(100, false) == nil && battery(100, true) == .full)
        check("unknown battery or charging gives nothing", battery(nil, false) == nil && battery(10, nil) == nil)
        check("temperatures convert", celsius == "32°" && fahrenheit == "89°")
    }

    static func testTodo() {
        let noon = moment("2026-11-09T12:00:00+07:00")
        let tomorrow = moment("2026-11-10T09:00:00+07:00")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        var list = TodoList()
        check("a task is added", list.add("  Write the report  ", at: noon) && list.items.first?.title == "Write the report")
        check("empty text is refused", !list.add("   ", at: noon) && list.items.count == 1)
        check("only the first line is kept", list.add("Call Dina\nsecond line", at: noon) && list.items.last?.title == "Call Dina")
        check("long titles are cut", { var l = TodoList(); l.add(String(repeating: "a", count: 200), at: noon); return l.items[0].title.count == TodoList.maxTitle }())
        check("the list has a limit", { var l = TodoList(); for i in 0..<60 { l.add("task \(i)", at: noon) }; return l.items.count == TodoList.maxItems }())
        let fullModel = TodoModel(directory: FileManager.default.temporaryDirectory, persists: false)
        for i in 0..<TodoList.maxItems { fullModel.add("task \(i)") }
        check("a full list says why a task wasn't added", !fullModel.add("one more") && fullModel.problem != nil)
        fullModel.delete(fullModel.list.items[0].id)
        check("adding works again once there's room", fullModel.add("one more") && fullModel.problem == nil)
        let first = list.items[0].id
        list.toggle(first, at: noon)
        check("finishing counts for today", list.doneToday(now: noon, calendar: calendar) == 1 && list.totalToday(now: noon, calendar: calendar) == 2)
        check("open tasks come before finished ones", list.visible(now: noon, calendar: calendar).map(\.title) == ["Call Dina", "Write the report"])
        list.toggle(first, at: noon)
        check("toggling again reopens it", list.doneToday(now: noon, calendar: calendar) == 0 && !list.items[0].isDone)
        list.toggle(first, at: noon)
        list.dropOld(now: tomorrow, calendar: calendar)
        check("tasks finished yesterday are dropped, open ones stay", list.items.map(\.title) == ["Call Dina"])
        check("yesterday's finished tasks don't count", list.doneToday(now: tomorrow, calendar: calendar) == 0 && list.totalToday(now: tomorrow, calendar: calendar) == 1)
        list.delete(list.items[0].id)
        check("a task is removed", list.items.isEmpty)
        var cleared = TodoList()
        cleared.add("a", at: noon); cleared.add("b", at: noon)
        cleared.toggle(cleared.items[0].id, at: noon)
        cleared.clearDone()
        check("finished tasks can be cleared", cleared.items.map(\.title) == ["b"])
        var renamed = TodoList()
        renamed.add("old name", at: noon)
        let id = renamed.items[0].id
        check("a task is renamed", renamed.rename(id, to: "  new name\nmore  ") && renamed.items[0].title == "new name")
        check("an empty name is refused", !renamed.rename(id, to: "   ") && renamed.items[0].title == "new name")
        check("a missing task can't be renamed", !renamed.rename(UUID(), to: "x"))
        testLyrics()
    }

    static func testLayout() {
        let area = CGRect(x: 0, y: 25, width: 1200, height: 775)
        let current = CGSize(width: 400, height: 300)
        check("left half", WindowSpot.leftHalf.frame(in: area, current: current) == CGRect(x: 0, y: 25, width: 600, height: 775))
        check("right half", WindowSpot.rightHalf.frame(in: area, current: current) == CGRect(x: 600, y: 25, width: 600, height: 775))
        check("bottom right quarter", WindowSpot.bottomRight.frame(in: area, current: current).origin == CGPoint(x: 600, y: 412))
        check("thirds cover the width", WindowSpot.rightThird.frame(in: area, current: current).maxX == 1200
              && WindowSpot.leftTwoThirds.frame(in: area, current: current).width == 800)
        check("center keeps the size", WindowSpot.center.frame(in: area, current: current) == CGRect(x: 400, y: 263, width: 400, height: 300))
        check("center never grows past the screen", WindowSpot.center.frame(in: area, current: CGSize(width: 5000, height: 5000)) == area)
        let grid = WindowSpot.grid(count: 5, in: area)
        check("five windows make two rows", grid.count == 5 && Set(grid.map(\.minY)).count == 2)
        check("the last row fills the width", grid[3].width == 600 && grid[4].maxX == 1200)
        check("no windows, no grid", WindowSpot.grid(count: 0, in: area).isEmpty)
        check("every spot has its own key", Set(WindowSpot.allCases.map(\.key.code)).count == WindowSpot.allCases.count)
    }

    static func testLauncher() {
        // Emoji and folder prefixes
        check("there are many emoji", LauncherEmoji.all.count > 1000)
        check("an English name finds an emoji", LauncherEmoji.search("sunglasses").prefix(2).contains { $0.emoji == "😎" })
        check("an Indonesian word finds an emoji", LauncherEmoji.search("jempol").first?.emoji == "👍")
        check("api finds fire", LauncherEmoji.search("api").first?.emoji == "🔥")
        check("two words narrow it down", LauncherEmoji.search("face sunglasses").first?.emoji == "😎")
        check("heart finds the red heart", LauncherEmoji.search("heart").first?.emoji == "❤️")
        check("text-style emoji get the color form", LauncherEmoji.all.contains { $0.emoji == "☀️" })
        check("skin tones aren't listed alone", !LauncherEmoji.all.contains { $0.emoji.unicodeScalars.first?.properties.isEmojiModifier == true })
        check("nothing matches nonsense", LauncherEmoji.search("qqzzxx").isEmpty)
        check(": starts emoji", LauncherSearch.emojiTerms(":smile") == "smile")
        check("e starts emoji", LauncherSearch.emojiTerms("e senyum") == "senyum")
        check("a bare : shows recent emoji", LauncherSearch.emojiTerms(":") == "")
        check("a normal word isn't emoji", LauncherSearch.emojiTerms("excel") == nil)
        check("d looks for folders", LauncherSearch.scoped("d proyek")?.folders == true && LauncherSearch.scoped("d proyek")?.terms == "proyek")
        check("f looks for files", LauncherSearch.scoped("f laporan")?.folders == false)
        check("a prefix alone isn't a search", LauncherSearch.scoped("d ") == nil)
        check("sums follow the order of operations", LauncherMath.evaluate("12*(3+4)-2^3") == 76)
        check("decimals with a comma", LauncherMath.evaluate("1,5*2") == 3)
        check("division by zero gives nothing", LauncherMath.evaluate("5/0") == nil)
        check("a plain number isn't a sum", LauncherMath.evaluate("2026") == nil)
        check("words aren't sums", LauncherMath.evaluate("safari") == nil && LauncherMath.evaluate("2+x") == nil)
        check("broken sums give nothing", LauncherMath.evaluate("(2+3") == nil && LauncherMath.evaluate("2+") == nil && LauncherMath.evaluate("*3") == nil)
        check("deep brackets are refused", LauncherMath.evaluate(String(repeating: "(", count: 80) + "1" + String(repeating: ")", count: 80)) == nil)
        check("results read cleanly", LauncherMath.format(7) == "7" && LauncherMath.format(0.1 + 0.2) == "0.3")
        check("kilometres to miles", LauncherUnits.convert("10 km to mi") == "6.2137 mi")
        check("fahrenheit to celsius", LauncherUnits.convert("212 F ke C") == "100 C")
        check("different kinds don't convert", LauncherUnits.convert("10 kg to km") == nil)
        check("an exact name wins", (LauncherScore.score("Safari", "safari") ?? 0) > (LauncherScore.score("Safari Technology Preview", "safari") ?? 0))
        check("initials match", LauncherScore.score("Visual Studio Code", "vsc") != nil)
        check("unrelated names don't match", LauncherScore.score("Mail", "xyz") == nil)
    }

    static func testClipboardImport() {
        func be32(_ value: Int32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
        func qBytes(_ data: Data) -> Data { be32(Int32(data.count)) + data }
        func qString(_ text: String) -> Data { qBytes(text.data(using: .utf16BigEndian)!) }
        func qVariantString(_ text: String) -> Data { be32(10) + Data([0]) + qString(text) }
        func qVariantBytes(_ data: Data) -> Data { be32(12) + Data([0]) + qBytes(data) }
        func qCompress(_ data: Data) -> Data {
            var output = [UInt8](repeating: 0, count: data.count + 64)
            let written = [UInt8](data).withUnsafeBufferPointer {
                compression_encode_buffer(&output, output.count, $0.baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
            return be32(Int32(data.count)) + Data([0x78, 0x9C]) + Data(output[0..<written]) + Data([0, 0, 0, 0])
        }
        let png: Data = {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }()

        let long = String(repeating: "panjang ", count: 200)
        check("qUncompress reads Qt's zlib data", CopyQReader.qUncompress(qCompress(Data(long.utf8))) == Data(long.utf8))
        // A tab file with plain text, compressed text, an image, notes only, and the old v1 item format.
        var tab = be32(5)
        tab += be32(-2) + be32(2) + qString("4") + Data([0]) + qBytes(Data("halo dunia".utf8))
            + qString("2") + Data([0]) + qBytes(Data("catatan".utf8))
        tab += be32(-2) + be32(1) + qString("4;charset=utf-8") + Data([1]) + qBytes(qCompress(Data(long.utf8)))
        tab += be32(-2) + be32(1) + qString("7png") + Data([0]) + qBytes(png)
        tab += be32(-2) + be32(1) + qString("2") + Data([0]) + qBytes(Data("hanya catatan".utf8))
        tab += be32(1) + qString("text/plain") + qBytes(qCompress(Data("format lama".utf8)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dysklink-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clips = (try? CopyQReader.tabFile(tab, folder: folder)) ?? []
        check("CopyQ tab items are read in order", clips.map { $0.text ?? ($0.image != nil ? "<image>" : "?") }
              == ["halo dunia", long, "<image>", "format lama"])
        let encrypted = be32(1) + be32(-3) + be32(4) + Data([1, 2, 3, 4])
        check("encrypted CopyQ items are reported", (try? CopyQReader.tabFile(encrypted, folder: folder)) == nil)

        let settings = be32(1) + qString("tabs") + be32(11) + Data([0]) + be32(1) + qString("&clipboard")
        let tabMap = be32(2) + qString("name") + qVariantString("&clipboard") + qString("data") + qVariantBytes(tab)
        let v4 = qBytes(Data("CopyQ v4".utf8)) + settings + tabMap
        let cpq = folder.appendingPathComponent("export.cpq")
        try? v4.write(to: cpq)
        check("a CopyQ v4 export is read", (try? ClipboardImport.read(cpq))?.count == 4)
        let v5 = folder.appendingPathComponent("locked.cpq")
        try? (qBytes(Data("CopyQ v5".utf8)) + Data(repeating: 7, count: 20)).write(to: v5)
        check("a CopyQ v5 export asks for a plain export", (try? ClipboardImport.read(v5)) == nil)
        let copyqFolder = folder.appendingPathComponent("copyq")
        try? FileManager.default.createDirectory(at: copyqFolder, withIntermediateDirectories: true)
        try? tab.write(to: copyqFolder.appendingPathComponent("copyq_tab_JmNsaXBib2FyZA==.dat"))
        check("CopyQ's data folder is read", (try? ClipboardImport.read(copyqFolder))?.count == 4)

        // A Ditto database with the same tables Ditto makes.
        let dbURL = folder.appendingPathComponent("Ditto.db")
        var db: OpaquePointer?
        sqlite3_open(dbURL.path, &db)
        sqlite3_exec(db, """
            CREATE TABLE Main(lID INTEGER PRIMARY KEY AUTOINCREMENT, lDate INTEGER, mText TEXT, lShortCut INTEGER,
              lDontAutoDelete INTEGER, CRC INTEGER, bIsGroup INTEGER, lParentID INTEGER, QuickPasteText TEXT);
            CREATE TABLE Data(lID INTEGER PRIMARY KEY AUTOINCREMENT, lParentID INTEGER, strClipBoardFormat TEXT, ooData BLOB);
            INSERT INTO Main(lID, lDate, mText, bIsGroup) VALUES (1, 1700000000, 'lama', 0), (2, 1700000500, 'Grup', 1),
              (3, 1700000900, 'cadangan', 0), (4, 1700000300, 'gambar', 0);
            INSERT INTO Data(lParentID, strClipBoardFormat, ooData) VALUES (3, 'CF_TEXT', X'616E7369');
            """, nil, nil, nil)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO Data(lParentID, strClipBoardFormat, ooData) VALUES (?, ?, ?)", -1, &statement, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (parent, format, blob) in [(1, "CF_UNICODETEXT", "Salam ✓\0".data(using: .utf16LittleEndian)!), (4, "PNG", png)] {
            sqlite3_reset(statement)
            sqlite3_bind_int(statement, 1, Int32(parent))
            sqlite3_bind_text(statement, 2, format, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(blob.count), transient) }
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        sqlite3_close(db)
        let ditto = (try? ClipboardImport.read(dbURL)) ?? []
        check("Ditto clips come newest first, without groups", ditto.map { $0.text ?? "<image>" } == ["ansi", "<image>", "Salam ✓"])
        check("Ditto dates are kept", ditto.last?.date == Date(timeIntervalSince1970: 1_700_000_000))
        check("Ditto's database is left alone", !FileManager.default.fileExists(atPath: dbURL.path + "-journal")
              && !FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        var dib = Data(count: 40)
        dib.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(40).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: Int32(1).littleEndian, toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(1).littleEndian, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: UInt16(1).littleEndian, toByteOffset: 12, as: UInt16.self)
            raw.storeBytes(of: UInt16(24).littleEndian, toByteOffset: 14, as: UInt16.self)
        }
        dib += Data([0, 0, 255, 0])
        check("a Windows DIB becomes a PNG", DittoReader.clipImage(["CF_DIB": dib]) != nil)
        check("a random file isn't recognized", {
            let junk = folder.appendingPathComponent("junk.bin")
            try? Data("bukan apa-apa".utf8).write(to: junk)
            return (try? ClipboardImport.read(junk)) == nil
        }())

        let suite = "id.phonelink.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ClipboardHistory(directory: folder.appendingPathComponent("history"), defaults: defaults)
        history.add(text: "halo dunia")
        let merged = history.importClips(clips + ditto + [ImportedClip(text: "Kucing#2024")])
        check("import skips what is saved, repeats, and what looks like a password", merged.added == 5)
        check("imported items sort by date", history.entries.first?.text == "halo dunia" && history.entries.last?.text == "Salam ✓")
        check("importing again adds nothing", history.importClips(clips).added == 0)
        history.setLimits(maxEntries: ClipboardHistory.unlimited, maxImages: ClipboardHistory.unlimited)
        for index in 0..<1200 { history.add(text: "item \(index)") }
        check("unlimited keeps more than 1000", history.entries.count == 1206)
        history.setLimits(maxEntries: 50, maxImages: 10)
        check("a limit still trims", history.entries.count == 50)
    }

    static func testTerminal() {
        let shell = PtyShell(id: "t")
        let lock = NSLock()
        var output = Data()
        var exitCode: Int32 = -1
        let done = DispatchSemaphore(value: 0)
        shell.onOutput = { data in lock.lock(); output.append(data); lock.unlock() }
        shell.onExit = { code in exitCode = code; done.signal() }
        do {
            try shell.start(cols: 100, rows: 30, shell: "/bin/sh",
                            arguments: ["-c", "printf 'term=%s size=%s ' \"$TERM\" \"$(stty size)\"; read line; printf 'got=%s' \"$line\"; exit 3"])
        } catch {
            return check("terminal: shell starts", false)
        }
        // Typed the way the phone sends it: Return is a carriage return.
        shell.write(Data("hello\r".utf8))
        let finished = done.wait(timeout: .now() + 5) == .success
        lock.lock(); let text = String(decoding: output, as: UTF8.self); lock.unlock()
        check("terminal: runs and exits with its code", finished && exitCode == 3)
        check("terminal: xterm with the phone's size", text.contains("term=xterm-256color") && text.contains("size=30 100"))
        check("terminal: typing reaches the shell", text.contains("got=hello"))

        let stuck = PtyShell(id: "u")
        let ended = DispatchSemaphore(value: 0)
        stuck.onExit = { _ in ended.signal() }
        try? stuck.start(cols: 80, rows: 24, shell: "/bin/sh", arguments: ["-c", "sleep 30"])
        stuck.hangUp()
        check("terminal: hang up ends it", ended.wait(timeout: .now() + 4) == .success)

        // A shell that doesn't read: typing fills the pty, and hanging up must not wait behind the typing.
        let full = PtyShell(id: "v")
        let gone = DispatchSemaphore(value: 0)
        full.onExit = { _ in gone.signal() }
        try? full.start(cols: 80, rows: 24, shell: "/bin/sh", arguments: ["-c", "sleep 30"])
        full.write(Data(repeating: UInt8(ascii: "x"), count: 512 * 1024))
        full.resize(cols: 90, rows: 30)
        full.hangUp()
        check("terminal: a full pty doesn't hold up hanging up", gone.wait(timeout: .now() + 4) == .success)

        // A shell let go of while running is ended and reaped, not left as a zombie.
        var dropped: PtyShell? = PtyShell(id: "w")
        try? dropped?.start(cols: 80, rows: 24, shell: "/bin/sh", arguments: ["-c", "trap '' HUP; sleep 30"])
        let child = dropped?.pid ?? 0
        dropped = nil
        var reaped = false
        for _ in 0..<40 where !reaped {
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + 0.1)
            reaped = kill(child, 0) != 0 && errno == ESRCH
        }
        check("terminal: a dropped shell is reaped", child > 0 && reaped)
    }

    /// The frames the session builds by hand must read back as the same messages, and the NAL splitter that works
    /// in place must find the same units as the old copying one.
    static func testFastFrames() {
        func envelope(_ frame: Data?) -> Envelope? {
            guard let frame, frame.count > 4 else { return nil }
            let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length == frame.count - 4 else { return nil }
            return try? JSONDecoder().decode(Envelope.self, from: frame.dropFirst(4))
        }
        let bytes = Data((0..<70_001).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let chunk = envelope(PeerSession.base64Frame(type: MessageType.fileChunk,
                                                     fields: #""file":{"id":\#(PeerSession.jsonString("a\"b\\c/é")),"data":"#,
                                                     data: bytes, after: "}"))
        check("chunk frame reads back", chunk?.type == MessageType.fileChunk && chunk?.file?.id == "a\"b\\c/é"
              && chunk?.file?.data.flatMap { Data(base64Encoded: $0) } == bytes)
        let video = envelope(PeerSession.base64Frame(type: MessageType.macScreenFrame, fields: #""video":"#,
                                                     data: bytes.prefix(5), after: #","keyFrame":true"#))
        check("video frame reads back", video?.keyFrame == true && video?.video.flatMap { Data(base64Encoded: $0) } == bytes.prefix(5))
        let empty = envelope(PeerSession.base64Frame(type: MessageType.audioFrame, fields: #""audio":"#, data: Data()))
        check("empty payload reads back", empty?.type == MessageType.audioFrame && empty?.audio == "")
        check("oversized frame dropped", PeerSession.base64Frame(type: MessageType.fileChunk, fields: #""video":"#,
                                                                 data: Data(count: 800 * 1024)) == nil)

        // The old splitter, kept here as the reference.
        func reference(_ data: Data) -> [Data] {
            let bytes = [UInt8](data)
            var units: [Data] = []
            var start: Int?
            var index = 0
            while index + 2 < bytes.count {
                if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                    if let start {
                        var end = index
                        while end > start, bytes[end - 1] == 0 { end -= 1 }
                        units.append(Data(bytes[start..<end]))
                    }
                    start = index + 3
                    index += 3
                } else {
                    index += 1
                }
            }
            if let start, start < bytes.count { units.append(Data(bytes[start...])) }
            return units.filter { !$0.isEmpty }
        }
        var generator = SystemRandomNumberGenerator()
        var same = true
        for round in 0..<400 {
            // Mostly zeros and ones, so start codes and trailing zeros come up often.
            let count = Int.random(in: 0..<200, using: &generator)
            var sample = Data((0..<count).map { _ in [0, 0, 0, 1, 1, 2, 0x41, 0x67, 0xFF].randomElement(using: &generator)! })
            if round % 3 == 0 { sample = Data([9, 9]) + sample; sample = sample.dropFirst(2) }
            if VideoDecoder.nalUnits(sample) != reference(sample) { same = false }
        }
        check("NAL units found in place match", same)
    }

    static func testNotificationImages() {
        // A 1×1 PNG, as the phone sends it.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        let json = #"{"key":"k","app":"WhatsApp","time":1,"pkg":"com.whatsapp","icon":"\#(png)","color":2479463}"#
        let item = try? JSONDecoder().decode(NotificationItem.self, from: Data(json.utf8))
        check("notification: images decode", item?.pkg == "com.whatsapp" && PhoneImages.image(item?.icon) != nil && item?.color == 0x25D567)
        let old = try? JSONDecoder().decode(NotificationItem.self, from: Data(#"{"key":"k","app":"Mail","time":1}"#.utf8))
        check("notification: old phones still work", old != nil && PhoneImages.image(old?.icon) == nil)
        check("notification: bad data is ignored", PhoneImages.image("not base64!") == nil)
        // A later notification without an icon reuses the app's last one.
        if let item { _ = PhoneImages.appIcon(item) }
        check("notification: app icon remembered", PhoneImages.appIcon(NotificationItem(key: "2", app: "WhatsApp", time: 2, pkg: "com.whatsapp")) != nil)
    }

    static func testPhoneSearch() {
        let people = [
            ContactItem(id: "1", name: "Ayu Lestari", phones: ["+62 812-0000-0001"]),
            ContactItem(id: "2", name: "Budi Santoso", phones: ["081200000002"]),
            ContactItem(id: "3", name: "Siti Ayuningtyas", phones: ["6281300000003"]),
            ContactItem(id: "4", name: "José Ramírez", phones: []),
            ContactItem(id: "5", name: "Pak RT Budiman", phones: ["0215550000"]),
        ]
        func names(_ query: String) -> [String] { PhoneSearch.contacts(people, query: query).map(\.name) }
        check("search: empty shows all, sorted", names("") == ["Ayu Lestari", "Budi Santoso", "José Ramírez", "Pak RT Budiman", "Siti Ayuningtyas"])
        check("search: name start ranks first", names("ayu") == ["Ayu Lestari", "Siti Ayuningtyas"])
        check("search: case and accents", names("JOSE ramirez") == ["José Ramírez"])
        check("search: word starts in any order", names("santoso bu") == ["Budi Santoso"])
        check("search: middle of a word", names("udim") == ["Pak RT Budiman"])
        check("search: 0812 finds +62 812", names("0812") == ["Ayu Lestari", "Budi Santoso"])
        check("search: +62 813 finds 62813", names("+62 813") == ["Siti Ayuningtyas"])
        check("search: formatted digits", names("0000-0001") == ["Ayu Lestari"])
        check("search: one letter only matches word starts", names("a") == ["Ayu Lestari", "Siti Ayuningtyas"])
        check("search: no match", names("zzz").isEmpty && names("0899").isEmpty)
        check("search: text in a message", PhoneSearch.textMatches("Besok rapat jam TIGA ya", "rapat tiga"))
        check("search: initials", PhoneSearch.initials("Budi Santoso") == "BS" && PhoneSearch.initials("+62812") == "#")
        check("search: sections", PhoneSearch.section("ayu") == "A" && PhoneSearch.section("0812") == "#" && PhoneSearch.section("Élodie") == "E")
    }

    static func testLauncherWeb() {
        let google = LauncherWeb.search("cuaca gresik")
        check("web: Google by default", google?.name == "Google" && google?.url.absoluteString == "https://www.google.com/search?q=cuaca%20gresik")
        let youtube = LauncherWeb.search("yt lofi hip hop")
        check("web: yt prefix", youtube?.name == "YouTube" && youtube?.terms == "lofi hip hop")
        check("web: a prefix alone searches Google", LauncherWeb.search("w")?.name == "Google")
        check("web: & is escaped", LauncherWeb.search("tom & jerry")?.url.absoluteString.contains("%26") == true)
        check("web: github.com is an address", LauncherWeb.address("github.com")?.absoluteString == "https://github.com")
        check("web: path kept", LauncherWeb.address("example.co.id/a/b")?.absoluteString == "https://example.co.id/a/b")
        check("web: full link", LauncherWeb.address("http://192.168.1.1:8080")?.host == "192.168.1.1")
        check("web: numbers aren't an address", LauncherWeb.address("3.14") == nil)
        check("web: file names aren't an address", LauncherWeb.address("report.pdf") == nil)
        check("web: words aren't an address", LauncherWeb.address("hello world.com") == nil)
    }

    static func testShortcuts() {
        let copy = Shortcut.parse("cmd+c")
        check("shortcut: cmd+c", copy?.0 == 8 && copy?.1 == .maskCommand)
        let shot = Shortcut.parse(" Cmd + Shift + 4 ")
        check("shortcut: spaces and case", shot?.0 == 21 && shot?.1 == [.maskCommand, .maskShift])
        check("shortcut: ctrl+up", Shortcut.parse("ctrl+up")?.0 == 126)
        check("shortcut: f12", Shortcut.parse("f12")?.0 == 111 && Shortcut.parse("f12")?.1 == [])
        check("shortcut: cmd++ zooms in", Shortcut.parse("cmd++")?.0 == 24 && Shortcut.parse("cmd++")?.1 == [.maskCommand, .maskShift])
        check("shortcut: backslash", Shortcut.parse("cmd+\\")?.0 == 42)
        check("shortcut: unknown key", Shortcut.parse("cmd+volumeup") == nil)
        check("shortcut: unknown modifier", Shortcut.parse("hyper+c") == nil)
        check("shortcut: only modifiers", Shortcut.parse("cmd+shift") == nil)
        check("shortcut: empty", Shortcut.parse("") == nil)
        check("shortcut: fn", Shortcut.parse("fn+f11")?.0 == 103 && Shortcut.parse("fn+f11")?.1 == .maskSecondaryFn)
    }

    static func testMacSync() {
        check("only the smaller ID connects", MacSync.shouldDial(from: "aa", to: "bb") && !MacSync.shouldDial(from: "bb", to: "aa"))
        check("a Mac never connects to itself", !MacSync.shouldDial(from: "aa", to: "aa") && !MacSync.shouldDial(from: "aa", to: ""))
        let clips = (0..<900).map { SyncedClip(text: "salinan \($0)", time: Int64($0)) }
        check("history sync sends at most 500", MacSync.fitting(clips).count == 500 && MacSync.fitting(clips).first?.text == "salinan 0")
        let big = [SyncedClip(text: String(repeating: "x", count: 600_000), time: 0), SyncedClip(text: "kecil", time: 1)]
        check("a huge copy is skipped, not everything after it", MacSync.fitting(big).map(\.text) == ["kecil"])
        let frame = try? JSONEncoder().encode({ var e = Envelope(type: MessageType.clipboardHistory); e.clips = MacSync.fitting(
            (0..<500).map { SyncedClip(text: String(repeating: "\"é\n", count: 600) + "\($0)", time: 0) }); return e }())
        check("history fits in one frame", (frame?.count ?? .max) <= PhoneLinkProtocol.maxFrameBytes)
    }

    static func testLyrics() {
        let lines = LyricsParser.parse("[ar: someone]\n[00:12.50]First line\n[00:15.00][01:02.3]Chorus\n[00:20]Third\nnot a line")
        check("timed lyrics are read", lines.map(\.text) == ["First line", "Chorus", "Third", "Chorus"])
        check("times are read with fractions", lines.map(\.time) == [12.5, 15, 20, 62.3])
        check("no line before the first time", LyricsParser.index(in: lines, at: 5) == nil)
        check("the current line follows the song", LyricsParser.index(in: lines, at: 16) == 1 && LyricsParser.index(in: lines, at: 70) == 3)
        let youtube = LyricsParser.split(title: "Hindia - Secukupnya (Official Music Video) | Lyrics", artist: "")
        check("a YouTube title gives artist and song", youtube.artist == "Hindia" && youtube.title == "Secukupnya")
        let app = LyricsParser.split(title: "Secukupnya", artist: "Hindia")
        check("a known artist is kept", app.artist == "Hindia" && app.title == "Secukupnya")
    }

    static func testWater() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7 * 3600)!
        let nine = moment("2026-11-09T09:10:00+07:00")
        let noon = moment("2026-11-09T12:00:00+07:00")
        let nextDay = moment("2026-11-10T10:00:00+07:00")
        var log = WaterLog()
        log.add(250, at: nine)
        log.add(250, at: moment("2026-11-09T09:50:00+07:00"))
        log.add(300, at: noon)
        log.add(0, at: noon)
        check("drinks add up for today", log.total(on: noon, calendar: calendar) == 800 && log.entries.count == 3)
        check("drinks are grouped by hour", log.byHour(on: noon, calendar: calendar) == [9: 500, 12: 300])
        check("another day starts from zero", log.total(on: nextDay, calendar: calendar) == 0)
        log.undo(now: noon, calendar: calendar)
        check("undo takes back the last drink", log.total(on: noon, calendar: calendar) == 500)
        log.undo(now: nextDay, calendar: calendar)
        check("undo on an empty day changes nothing", log.entries.count == 2)
        log.dropOld(now: moment("2026-11-20T10:00:00+07:00"), calendar: calendar)
        check("old days are dropped", log.entries.isEmpty)

        var settings = WaterSettings(goalMl: 2000, glassMl: 250, remindEveryMinutes: 60, reminds: true, fromHour: 8, toHour: 21)
        func due(_ now: String, drink: String?, reminder: String? = nil, total: Int = 0) -> Bool {
            WaterLog.isReminderDue(now: moment(now), lastDrink: drink.map(moment), lastReminder: reminder.map(moment),
                                   total: total, settings: settings, calendar: calendar)
        }
        check("nothing is due with reminders off", { var off = settings; off.reminds = false
            return !WaterLog.isReminderDue(now: noon, lastDrink: nil, lastReminder: nil, total: 0, settings: off, calendar: calendar) }())
        check("a reminder is due an hour after the last drink", due("2026-11-09T12:00:00+07:00", drink: "2026-11-09T10:59:00+07:00"))
        check("not yet before the interval", !due("2026-11-09T12:00:00+07:00", drink: "2026-11-09T11:30:00+07:00"))
        check("a recent reminder waits the interval", !due("2026-11-09T12:00:00+07:00", drink: "2026-11-09T09:00:00+07:00", reminder: "2026-11-09T11:30:00+07:00"))
        check("the first reminder waits an hour after the start", !due("2026-11-09T08:30:00+07:00", drink: nil) && due("2026-11-09T09:00:00+07:00", drink: nil))
        check("no reminders at night", !due("2026-11-09T22:30:00+07:00", drink: "2026-11-09T12:00:00+07:00"))
        check("no reminders before the start hour", !due("2026-11-09T07:30:00+07:00", drink: nil))
        check("no reminders once the goal is reached", !due("2026-11-09T15:00:00+07:00", drink: "2026-11-09T10:00:00+07:00", total: 2000))
        settings.fromHour = 20; settings.toHour = 10
        check("odd hours fall back to the defaults", settings.checked.fromHour == 8 && settings.checked.toHour == 21)
        settings = WaterSettings(goalMl: 1234, glassMl: 250, remindEveryMinutes: 7)
        check("values outside the lists fall back", settings.checked.goalMl == 2000 && settings.checked.remindEveryMinutes == 60 && settings.checked.glassMl == 250)
        check("litres are shown short", WaterModel.litres(1500) == "1.5" && WaterModel.litres(2000) == "2" && WaterModel.litres(250) == "0.25")
    }
}
#endif
