import AppKit
import IOKit.ps
import Observation
import os
import SwiftUI

private let log = Logger(subsystem: "id.phonelink.mac", category: "Notch")

struct ShelfItem: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

/// The shelf only remembers where files are. Nothing is copied or moved.
enum ShelfStore {
    static func load(from file: URL) -> [ShelfItem] {
        guard let data = try? Data(contentsOf: file),
              let items = try? JSONDecoder().decode([ShelfItem].self, from: data)
        else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func save(_ items: [ShelfItem], to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items), (try? data.write(to: file, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func adding(_ urls: [URL], to items: [ShelfItem]) -> [ShelfItem] {
        var result = items
        for url in urls where url.isFileURL {
            let item = ShelfItem(path: url.path)
            if !result.contains(item) { result.insert(item, at: 0) }
        }
        return result
    }
}

struct NotchGeometry: Equatable {
    /// The camera housing, or a thin bar on screens without one, in screen coordinates.
    var closed: CGRect
    var hasNotch: Bool

    static func make(frame: CGRect, safeTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?) -> NotchGeometry {
        if safeTop > 0, let leftArea, let rightArea, rightArea.minX > leftArea.maxX {
            let rect = CGRect(x: leftArea.maxX, y: frame.maxY - safeTop, width: rightArea.minX - leftArea.maxX, height: safeTop)
            return NotchGeometry(closed: rect, hasNotch: true)
        }
        let width: CGFloat = 170, height: CGFloat = 6
        return NotchGeometry(closed: CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height), hasNotch: false)
    }

    /// Exactly the notch, so reaching for a menu beside it doesn't open anything.
    func trigger() -> CGRect {
        closed.insetBy(dx: 4, dy: 0).union(CGRect(x: closed.minX + 4, y: closed.maxY, width: closed.width - 8, height: 2))
    }
}

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    /// Spotify sends the length and position. Music sends only the length.
    var duration: TimeInterval?
    var position: TimeInterval?
    var positionDate = Date()

    func elapsed(at now: Date) -> TimeInterval? {
        guard let position else { return nil }
        let moved = isPlaying ? position + now.timeIntervalSince(positionDate) : position
        return duration.map { min(moved, $0) } ?? moved
    }

    /// Flips playing and paused, keeping the song where it is.
    func toggled(at now: Date) -> NowPlaying {
        var next = self
        next.position = elapsed(at: now)
        next.positionDate = now
        next.isPlaying.toggle()
        return next
    }
}

@MainActor
@Observable
final class NotchModel {
    enum Page: String, CaseIterable {
        case music = "", focus = "Pomodoro", shelf = "Shelf", prayer = "Prayer", weather = "Weather", todo = "Todo", water = "Water"
    }

    enum ShelfMode { case files, clipboard }

    /// What can be hidden in Advanced. Files and Clipboard share the Shelf page.
    enum Section: String, CaseIterable, Identifiable {
        case music, pomodoro, files, clipboard, prayer, weather, todo, water
        var id: String { rawValue }
        var label: String {
            switch self {
            case .music: return "Music"
            case .pomodoro: return "Pomodoro"
            case .files: return "Shelf files"
            case .clipboard: return "Clipboard"
            case .prayer: return "Prayer times"
            case .weather: return "Weather"
            case .todo: return "Todo list"
            case .water: return "Water reminder"
            }
        }
    }

    /// With a camera, the menu and content start below it, so the camera never covers them.
    static func contentTop(hasNotch: Bool, notchHeight: CGFloat) -> CGFloat {
        hasNotch ? notchHeight + 6 : 2
    }

    var openSize: CGSize {
        CGSize(width: 600, height: 151 + Self.contentTop(hasNotch: hasNotch, notchHeight: closedSize.height) + 36)
    }

    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            updateBrowserReading()
            if isOpen, isShown(.weather) { weather.refresh() }
        }
    }
    var page = Page.music
    var shelfMode = ShelfMode.files
    /// Files are being dragged over the send-to-phone area.
    var isPhoneTargeted = false
    private(set) var hiddenSections: Set<Section>
    var pomodoroSettings: PomodoroSettings {
        didSet {
            if let data = try? JSONEncoder().encode(pomodoroSettings) { UserDefaults.standard.set(data, forKey: "notch.pomodoro") }
            // A running cycle keeps its lengths until it is reset.
            if !pomodoro.isStarted { pomodoro = Pomodoro(settings: pomodoroSettings) }
        }
    }
    var playsPomodoroSound: Bool {
        didSet { UserDefaults.standard.set(playsPomodoroSound, forKey: "notch.pomodoroSound") }
    }
    var closedSize = CGSize(width: 190, height: 32)
    var hasNotch = true
    /// On a screen with no camera, nothing is drawn while closed, and the top center still opens the panel.
    var hidesBar: Bool {
        didSet { UserDefaults.standard.set(hidesBar, forKey: "notch.hidesBar") }
    }
    var opensOnClick: Bool {
        didSet { UserDefaults.standard.set(opensOnClick, forKey: "notch.opensOnClick") }
    }
    private(set) var peek: String?
    /// From Music or Spotify.
    private(set) var appTrack: NowPlaying?
    /// From YouTube in a browser, read only while the panel is open.
    private(set) var browserTrack: NowPlaying?
    /// What plays wins. When nothing plays, Music or Spotify comes first.
    var nowPlaying: NowPlaying? {
        if let appTrack, appTrack.isPlaying { return appTrack }
        if let browserTrack, browserTrack.isPlaying { return browserTrack }
        return appTrack ?? browserTrack
    }
    var readsBrowsers: Bool {
        didSet {
            UserDefaults.standard.set(readsBrowsers, forKey: "notch.readsBrowsers")
            updateBrowserReading()
        }
    }
    private(set) var power = PowerStatus()
    private(set) var shelf: [ShelfItem] = []
    private(set) var pomodoro: Pomodoro
    private(set) var now = Date()
    let prayer: PrayerModel
    let weather: WeatherModel
    let phoneBattery: PhoneBatteryWatcher
    let todos: TodoModel
    let water: WaterModel

    @ObservationIgnored private let shelfFile: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var focusTimer: Timer?
    @ObservationIgnored private var peekWork: DispatchWorkItem?
    @ObservationIgnored private var browserTimer: Timer?
    @ObservationIgnored private var isReadingBrowsers = false
    /// After a click, the new state stays a moment, because a browser can keep sending sound briefly after a pause.
    @ObservationIgnored private var heldState: (title: String, isPlaying: Bool, until: Date)?

    init(directory: URL, isInert: Bool = false) {
        prayer = PrayerModel(directory: directory, isInert: isInert)
        weather = WeatherModel(isInert: isInert)
        phoneBattery = PhoneBatteryWatcher(isInert: isInert)
        todos = TodoModel(directory: directory, persists: !isInert)
        water = WaterModel(directory: directory, persists: !isInert)
        shelfFile = directory.appendingPathComponent("notch-shelf.json")
        opensOnClick = UserDefaults.standard.bool(forKey: "notch.opensOnClick")
        hidesBar = UserDefaults.standard.object(forKey: "notch.hidesBar") as? Bool ?? true
        let hidden = Set((UserDefaults.standard.stringArray(forKey: "notch.hidden") ?? []).compactMap(Section.init))
        hiddenSections = hidden.count == Section.allCases.count ? [] : hidden
        let settings = UserDefaults.standard.data(forKey: "notch.pomodoro")
            .flatMap { try? JSONDecoder().decode(PomodoroSettings.self, from: $0) }?.checked ?? PomodoroSettings()
        pomodoroSettings = settings
        pomodoro = Pomodoro(settings: settings)
        playsPomodoroSound = UserDefaults.standard.object(forKey: "notch.pomodoroSound") as? Bool ?? true
        readsBrowsers = UserDefaults.standard.object(forKey: "notch.readsBrowsers") as? Bool ?? true
        settle()
        phoneBattery.onAlert = { [weak self] text in self?.showPeek(text) }
        water.onRemind = { [weak self] text in self?.showPeek(text) }
        shelf = ShelfStore.load(from: shelfFile)
        power = PowerStatus.current()
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo
                MainActor.assumeIsolated { self?.updatePlayer(info) }
            })
        }
        power = PowerStatus.current()
        prayer.start()
        water.start()
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Shared.tools.notch.model.powerChanged() } }
        }, nil)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }
    }

    func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        prayer.stop()
        water.stop()
        resetPomodoro()
        isOpen = false
        appTrack = nil
        browserTrack = nil
    }

    /// Browsers are checked every second while the panel is open, and never while it is closed.
    private func updateBrowserReading() {
        let wanted = isOpen && readsBrowsers && !observers.isEmpty
        if !wanted {
            browserTimer?.invalidate()
            browserTimer = nil
            if !readsBrowsers { browserTrack = nil }
            return
        }
        guard browserTimer == nil else { return }
        readBrowsers()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBrowsers() }
        }
        RunLoop.main.add(timer, forMode: .common)
        browserTimer = timer
    }

    private func readBrowsers() {
        guard !isReadingBrowsers else { return }
        isReadingBrowsers = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let track = BrowserMedia.current()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isReadingBrowsers = false
                    guard self.readsBrowsers else { return }
                    var track = track
                    if let held = self.heldState, Date() < held.until, track?.title == held.title {
                        track?.isPlaying = held.isPlaying
                    }
                    // The same video keeps its place, so the view doesn't redraw for nothing.
                    if track?.title != self.browserTrack?.title || track?.isPlaying != self.browserTrack?.isPlaying
                        || track?.artist != self.browserTrack?.artist {
                        self.browserTrack = track
                    }
                }
            }
        }
    }

    private func updatePlayer(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" {
            appTrack = nil
            return
        }
        let title = info["Name"] as? String ?? appTrack?.title ?? ""
        let artist = info["Artist"] as? String ?? appTrack?.artist ?? ""
        let milliseconds = (info["Duration"] ?? info["Total Time"]) as? NSNumber
        appTrack = title.isEmpty ? nil : NowPlaying(
            title: title, artist: artist, isPlaying: state == "Playing",
            duration: milliseconds.map { $0.doubleValue / 1000 },
            position: (info["Playback Position"] as? NSNumber)?.doubleValue
        )
    }

    /// The button shows the new state at once, and the player confirms it afterwards.
    func playPause() {
        DeviceInput.media("play_pause")
        let now = Date()
        if let appTrack, appTrack.isPlaying || !(browserTrack?.isPlaying ?? false) {
            self.appTrack = appTrack.toggled(at: now)
        } else if let browserTrack {
            let next = browserTrack.toggled(at: now)
            self.browserTrack = next
            heldState = (next.title, next.isPlaying, now.addingTimeInterval(3))
        }
    }

    func powerChanged() {
        let next = PowerStatus.current()
        if next.isOnBattery != power.isOnBattery, let percent = next.percent {
            showPeek(next.isOnBattery ? "On battery · \(percent)%" : "Plugged in · \(percent)%")
        }
        power = next
    }

    /// Only while the Notch is on, so nothing is warned about with the tool off.
    func phoneInfo(peer: String, name: String, info: DeviceInfo) {
        guard !observers.isEmpty else { return }
        phoneBattery.handle(peer: peer, name: name, percent: info.batteryPercent, isCharging: info.isCharging)
    }

    func showPeek(_ text: String) {
        peekWork?.cancel()
        peek = text
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.peek = nil } }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: work)
    }

    func add(_ urls: [URL]) {
        shelf = ShelfStore.adding(urls, to: shelf)
        ShelfStore.save(shelf, to: shelfFile)
    }

    func remove(_ item: ShelfItem) {
        shelf.removeAll { $0 == item }
        ShelfStore.save(shelf, to: shelfFile)
    }

    func clearShelf() {
        shelf = []
        ShelfStore.save(shelf, to: shelfFile)
    }

    /// Prayer times and weather have no page until a city is chosen.
    func hasData(_ section: Section) -> Bool {
        switch section {
        case .prayer: return prayer.location != nil
        case .weather: return weather.place != nil
        default: return true
        }
    }

    /// Not hidden by the user, whether or not it has data to show yet.
    func isEnabled(_ section: Section) -> Bool { !hiddenSections.contains(section) }

    func isShown(_ section: Section) -> Bool { !hiddenSections.contains(section) && hasData(section) }

    /// The last shown section can't be hidden, so the panel always has a page.
    func canHide(_ section: Section) -> Bool {
        isShown(section) && Section.allCases.filter(isShown).count > 1
    }

    func setShown(_ section: Section, _ shown: Bool) {
        guard shown || canHide(section) else { return }
        if shown { hiddenSections.remove(section) } else { hiddenSections.insert(section) }
        UserDefaults.standard.set(hiddenSections.map(\.rawValue).sorted(), forKey: "notch.hidden")
        if section == .pomodoro, !shown { resetPomodoro() }
        settle()
    }

    var pages: [Page] {
        Page.allCases.filter {
            switch $0 {
            case .music: return isShown(.music)
            case .focus: return isShown(.pomodoro)
            case .shelf: return isShown(.files) || isShown(.clipboard)
            case .prayer: return isShown(.prayer)
            case .weather: return isShown(.weather)
            case .todo: return isShown(.todo)
            case .water: return isShown(.water)
            }
        }
    }

    /// Both shelf modes show a switch. With one hidden, the shelf shows the other.
    var hasShelfSwitch: Bool { isShown(.files) && isShown(.clipboard) }

    /// Moves off a page or shelf mode that was just hidden.
    private func settle() {
        if !pages.contains(page), let first = pages.first { page = first }
        if shelfMode == .files, !isShown(.files) { shelfMode = .clipboard }
        if shelfMode == .clipboard, !isShown(.clipboard) { shelfMode = .files }
    }

    /// The mode switch is a display setting, so the page rereads it after a change.
    private(set) var modeRevision = 0

    func modeChanged() { modeRevision += 1 }

    /// The closed notch shows the timer while it runs.
    var isFocusing: Bool { pomodoro.isRunning }

    /// How tall the closed shape is. Status always shows, even when the bar is hidden.
    func closedHeight(statusHeight: CGFloat) -> CGFloat {
        if peek != nil || isFocusing { return closedSize.height + statusHeight }
        return !hasNotch && hidesBar ? 0 : closedSize.height
    }

    var focusText: String { Self.clock(pomodoro.remaining(at: now)) }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    func togglePomodoro() {
        now = Date()
        if pomodoro.isRunning {
            pomodoro.pause(at: now)
            focusTimer?.invalidate()
            focusTimer = nil
            return
        }
        pomodoro.start(at: now)
        focusTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusTimer = timer
    }

    func resetPomodoro() {
        focusTimer?.invalidate()
        focusTimer = nil
        pomodoro = Pomodoro(settings: pomodoroSettings)
    }

    private func tick() {
        now = Date()
        var finished: Pomodoro.Phase?
        // A Mac that slept may have passed more than one step.
        for _ in 0..<pomodoro.steps.count {
            guard let phase = pomodoro.advance(at: now) else { break }
            finished = phase
        }
        guard let finished else { return }
        if playsPomodoroSound { NSSound(named: "Glass")?.play() }
        if !pomodoro.isRunning {
            resetPomodoro()
            showPeek("Pomodoro finished")
        } else {
            showPeek(finished == .focus ? "Time for a break" : "Back to focus")
        }
    }

    #if DEBUG
    func loadSnapshot(playing: NowPlaying?, pomodoro: Pomodoro, now: Date) {
        appTrack = playing
        self.pomodoro = pomodoro
        self.now = now
    }
    #endif
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Sits above the menu bar and ignores the mouse until the pointer reaches it, so the menu bar keeps working.
@MainActor
final class NotchController {
    let model: NotchModel

    private var panel: NSPanel?
    private var geometry = NotchGeometry(closed: .zero, hasNotch: false)
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var closeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?

    /// Passing over the notch on the way to a menu shouldn't open it.
    private static let hoverDelay = 0.2

    init(directory: URL) {
        model = NotchModel(directory: directory)
    }

    func start() {
        guard panel == nil else { return }
        model.start()
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = ClickThroughHostingView(rootView: NotchView(model: model, tools: Shared.tools))
        self.panel = panel
        layout()
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        let types: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] event in
            let kind = event.type
            MainActor.assumeIsolated { self?.pointerEvent(kind) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] event in
            let kind = event.type
            MainActor.assumeIsolated { self?.pointerEvent(kind) }
            return event
        }) { monitors.append(local) }
        log.info("Notch started")
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        closeWork?.cancel()
        openWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
        model.stop()
    }

    private static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } == true
        }
    }

    private func layout() {
        guard let panel, let screen = Self.builtInScreen() ?? NSScreen.main else { return }
        geometry = NotchGeometry.make(frame: screen.frame, safeTop: screen.safeAreaInsets.top,
                                      leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
        model.closedSize = geometry.closed.size
        model.hasNotch = geometry.hasNotch
        let size = CGSize(width: model.openSize.width + 40, height: model.openSize.height + 20)
        panel.setFrame(CGRect(x: geometry.closed.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private var openRect: CGRect {
        let size = model.openSize
        return CGRect(x: geometry.closed.midX - size.width / 2 - 14, y: geometry.closed.maxY - size.height - 14,
                      width: size.width + 28, height: size.height + 14)
    }

    private func pointerEvent(_ kind: NSEvent.EventType) {
        let mouse = NSEvent.mouseLocation
        if model.isOpen {
            if openRect.contains(mouse) || NSEvent.pressedMouseButtons != 0 {
                closeWork?.cancel()
                closeWork = nil
            } else if closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.setOpen(false) }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
            return
        }
        let isOver = geometry.trigger().contains(mouse)
        if kind == .leftMouseDragged {
            if isOver, model.isShown(.files), (NSPasteboard(name: .drag).types ?? []).contains(.fileURL) {
                model.page = .shelf
                model.shelfMode = .files
                setOpen(true)
            }
            return
        }
        if model.opensOnClick {
            if kind == .leftMouseDown, isOver { setOpen(true) }
            return
        }
        guard isOver else {
            openWork?.cancel()
            openWork = nil
            return
        }
        guard openWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.openWork = nil
                if self.geometry.trigger().contains(NSEvent.mouseLocation) { self.setOpen(true) }
            }
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    private func setOpen(_ open: Bool) {
        closeWork = nil
        panel?.ignoresMouseEvents = !open
        // A curve without overshoot, so the shape never bounces past the screen edge.
        withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: open ? 0.32 : 0.24)) { model.isOpen = open }
    }
}

/// Everything about the shape is animated as path data, with no layout, so it stays smooth at every frame.
struct NotchShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(width, height), AnimatablePair(bottomRadius, topRadius)) }
        set {
            (width, height) = (newValue.first.first, newValue.first.second)
            (bottomRadius, topRadius) = (newValue.second.first, newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.midX - width / 2 - topRadius
        let right = rect.midX + width / 2 + topRadius
        let bottom = rect.minY + height
        let top = min(topRadius, height / 2)
        let curve = min(bottomRadius, height / 2, width / 2)
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: right - topRadius, y: rect.minY + top), control: CGPoint(x: right - topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: right - topRadius, y: bottom - curve))
        path.addQuadCurve(to: CGPoint(x: right - topRadius - curve, y: bottom), control: CGPoint(x: right - topRadius, y: bottom))
        path.addLine(to: CGPoint(x: left + topRadius + curve, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left + topRadius, y: bottom - curve), control: CGPoint(x: left + topRadius, y: bottom))
        path.addLine(to: CGPoint(x: left + topRadius, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY), control: CGPoint(x: left + topRadius, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Two per-user macOS preferences that set the gap between menu bar icons. Removing them restores the default.
enum MenuBarSpacing {
    private static let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"] as [CFString]
    private static let tightValue = 6

    static var isTight: Bool {
        get {
            CFPreferencesCopyValue(keys[0], kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) != nil
        }
        set {
            for key in keys {
                CFPreferencesSetValue(key, newValue ? tightValue as CFNumber : nil,
                                      kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            }
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
    }
}
