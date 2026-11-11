import AppKit
import IOKit.ps
import Observation
import os
import SwiftUI

private let log = Logger(subsystem: "id.dysklink.mac", category: "Notch")

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
    /// The app it comes from, such as com.apple.Music or a browser's bundle ID.
    var source: String?
    /// A YouTube video's ID, for its thumbnail.
    var videoID: String?

    /// Identifies the song or video, for matching album art to it.
    var key: String { "\(source ?? "")|\(title)" }

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
        case music = "", focus = "Pomodoro", shelf = "Shelf", prayer = "Prayer", weather = "Weather", todo = "Todo", water = "Water", note = "Note", alerts = "Notifications"
    }

    enum ShelfMode { case files, clipboard }

    /// What can be hidden in Advanced. Files and Clipboard share the Shelf page.
    enum Section: String, CaseIterable, Identifiable {
        case music, pomodoro, files, clipboard, prayer, weather, todo, water, note, alerts
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
            case .note: return "Quick note"
            case .alerts: return "Notifications"
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
            updateDetailReading()
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
    /// Phones watching this Mac's screen. The closed notch says so the whole time, so it's never secret.
    var screenWatchers: [String] = []
    /// Phones hearing this Mac's sound, also always shown.
    var audioListeners: [String] = []
    var isWatched: Bool { !screenWatchers.isEmpty || !audioListeners.isEmpty }
    var watchText: String {
        if screenWatchers.isEmpty {
            return audioListeners.count == 1 ? "\(audioListeners[0]) is listening" : "\(audioListeners.count) phones listening"
        }
        return screenWatchers.count == 1 ? "\(screenWatchers[0]) is viewing" : "\(screenWatchers.count) phones viewing"
    }
    /// A phone notification shown under the closed notch for a few seconds.
    private(set) var notice: PhoneAlert?
    static let noticeHeight: CGFloat = 70
    /// A one-time code from the phone, with a Copy button. It stays longer than a notification.
    private(set) var code: CodeNotice?
    /// Something is shown under the closed notch.
    var hasBanner: Bool { notice != nil || code != nil }
    /// From Music or Spotify.
    private(set) var appTrack: NowPlaying?
    /// From YouTube in a browser, read only while the panel is open.
    private(set) var browserTrack: NowPlaying?
    /// From the Firefox extension. It knows more than the window title, so it stands in for the browser reading.
    private(set) var extensionTrack: NowPlaying?
    /// When the extension was last heard from, for the settings.
    private(set) var extensionHeard: Date?
    /// The extension speaks every few seconds; after this long without it, its track is dropped.
    static let extensionTimeout: TimeInterval = 15

    private var webTrack: NowPlaying? {
        if let extensionTrack, let heard = extensionHeard, now.timeIntervalSince(heard) < Self.extensionTimeout {
            if extensionTrack.isPlaying || browserTrack?.isPlaying != true { return extensionTrack }
        }
        return browserTrack
    }

    /// What plays wins. When nothing plays, Music or Spotify comes first.
    var nowPlaying: NowPlaying? {
        if let appTrack, appTrack.isPlaying { return appTrack }
        if let webTrack, webTrack.isPlaying { return webTrack }
        return appTrack ?? webTrack
    }
    /// Album art, Music's song position, and YouTube details, asked from the apps with AppleScript.
    var readsDetails: Bool {
        didSet {
            UserDefaults.standard.set(readsDetails, forKey: "notch.playerDetails")
            if !readsDetails { artwork = nil; artworkKey = nil; detailsProblem = nil }
            updateDetailReading()
            refreshAppDetails()
        }
    }
    /// The album art or video thumbnail for `artworkKey`.
    private(set) var artwork: NSImage?
    private(set) var artworkKey: String?
    /// What to change so the details can be read, such as an Automation permission.
    private(set) var detailsProblem: String?
    /// Art for what's showing now, never a leftover from the song before.
    var currentArtwork: NSImage? { nowPlaying.flatMap { $0.key == artworkKey ? artwork : nil } }
    var readsBrowsers: Bool {
        didSet {
            UserDefaults.standard.set(readsBrowsers, forKey: "notch.readsBrowsers")
            updateBrowserReading()
        }
    }
    private(set) var power = PowerStatus()
    private(set) var shelf: [ShelfItem] = []
    private(set) var pomodoro: Pomodoro
    /// Moved on start, pause, and each step of the timer, not every second: countdowns draw themselves.
    private(set) var now = Date()
    /// Snapshots freeze the clock at their own time.
    @ObservationIgnored private(set) var frozenNow: Date?
    let prayer: PrayerModel
    let weather: WeatherModel
    let phoneBattery: PhoneBatteryWatcher
    let todos: TodoModel
    let note: QuickNoteModel
    let water: WaterModel
    let lyrics: LyricsModel

    /// True while a connected phone shares its notifications, so the page only appears when it has something to show.
    @ObservationIgnored var alertsAvailable: () -> Bool = { false }
    @ObservationIgnored private let shelfFile: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var focusTimer: Timer?
    @ObservationIgnored private var peekWork: DispatchWorkItem?
    @ObservationIgnored private var noticeWork: DispatchWorkItem?
    @ObservationIgnored private var codeWork: DispatchWorkItem?
    @ObservationIgnored private var browserTimer: Timer?
    @ObservationIgnored private var detailTimer: Timer?
    @ObservationIgnored private var isReadingBrowsers = false
    /// After a click, the new state stays a moment, because a browser can keep sending sound briefly after a pause.
    @ObservationIgnored private var heldState: (title: String, isPlaying: Bool, until: Date)?

    init(directory: URL, isInert: Bool = false) {
        prayer = PrayerModel(directory: directory, isInert: isInert)
        weather = WeatherModel(isInert: isInert)
        phoneBattery = PhoneBatteryWatcher(isInert: isInert)
        todos = TodoModel(directory: directory, persists: !isInert)
        note = QuickNoteModel(directory: directory, persists: !isInert)
        water = WaterModel(directory: directory, persists: !isInert)
        lyrics = LyricsModel(isInert: isInert)
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
        readsDetails = UserDefaults.standard.bool(forKey: "notch.playerDetails")
        settle()
        phoneBattery.onAlert = { [weak self] text in self?.showPeek(text) }
        water.onRemind = { [weak self] text in self?.showPeek(text) }
        shelf = ShelfStore.load(from: shelfFile)
        power = PowerStatus.current()
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        for (name, app) in [("com.apple.Music.playerInfo", PlayerDetails.music), ("com.spotify.client.PlaybackStateChanged", PlayerDetails.spotify)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo
                MainActor.assumeIsolated { self?.updatePlayer(info, from: app) }
            })
        }
        observers.append(center.addObserver(forName: BrowserExtension.notification, object: nil, queue: .main) { [weak self] note in
            let json = note.userInfo?["json"] as? String
            MainActor.assumeIsolated { self?.extensionMessage(json) }
        })
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
        detailTimer?.invalidate()
        detailTimer = nil
    }

    // MARK: Player details

    /// YouTube's position and channel are checked every few seconds while the panel is open.
    private func updateDetailReading() {
        let wanted = isOpen && readsDetails && !observers.isEmpty
        if !wanted {
            detailTimer?.invalidate()
            detailTimer = nil
            return
        }
        refreshAppDetails()
        guard detailTimer == nil else { return }
        refreshVideoDetails()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVideoDetails() }
        }
        RunLoop.main.add(timer, forMode: .common)
        detailTimer = timer
    }

    /// Music's position and the album art of Music or Spotify, after a song change or when the panel opens.
    private func refreshAppDetails() {
        guard readsDetails, let track = appTrack, let source = track.source else { return }
        let key = track.key
        let needsArt = artworkKey != key
        PlayerDetails.queue.async { [weak self] in
            var song: PlayerDetails.Song?
            var problem: PlayerDetails.Failure?
            var artData: Data?
            var artURL: URL?
            if source == PlayerDetails.music {
                switch PlayerDetails.musicSong() {
                case .success(let found): song = found
                case .failure(let failure): problem = failure
                case nil: break
                }
                if needsArt, problem == nil { artData = PlayerDetails.musicArtwork() }
            } else if source == PlayerDetails.spotify, needsArt {
                artURL = PlayerDetails.spotifyArtwork()
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.readsDetails, self.appTrack?.key == key else { return }
                    self.detailsProblem = problem?.message
                    if let song, var track = self.appTrack {
                        track.position = song.position ?? track.position
                        track.duration = song.duration ?? track.duration
                        track.positionDate = Date()
                        self.appTrack = track
                    }
                    if let artData, let image = NSImage(data: artData) { self.setArtwork(image, for: key) }
                    if let artURL { self.loadArtwork(artURL, for: key) }
                }
            }
        }
    }

    /// A YouTube video's position, length, channel, and thumbnail from the browser it plays in.
    private func refreshVideoDetails() {
        guard readsDetails, let track = browserTrack, let source = track.source,
              source == PlayerDetails.safari || PlayerDetails.chromium.contains(source) else { return }
        let key = track.key
        PlayerDetails.queue.async { [weak self] in
            let result = PlayerDetails.video(in: source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.readsDetails, var current = self.browserTrack, current.key == key else { return }
                    switch result {
                    case .success(let video):
                        self.detailsProblem = nil
                        current.position = video.position
                        current.duration = video.duration
                        current.positionDate = Date()
                        if let channel = video.channel, !current.artist.hasPrefix(channel) {
                            current.artist = "\(channel) · \(current.artist)"
                        }
                        self.browserTrack = current
                        if self.artworkKey != key, let url = video.thumbnail { self.loadArtwork(url, for: key) }
                    case .failure(let failure):
                        self.detailsProblem = failure.message
                    case nil:
                        break
                    }
                }
            }
        }
    }

    private func extensionMessage(_ json: String?) {
        guard let json, let parsed = BrowserExtension.parse(json) else { return }
        extensionHeard = Date()
        now = Date()
        guard let track = parsed else { extensionTrack = nil; return }
        let changed = track.key != extensionTrack?.key
        extensionTrack = track
        // The thumbnail needs no permission: it comes from YouTube's image server by the video's ID.
        if changed || artworkKey != track.key, let id = track.videoID, let url = URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") {
            loadArtwork(url, for: track.key)
        }
    }

    private func loadArtwork(_ url: URL, for key: String) {
        artworkKey = key
        Task { [weak self] in
            let image = await PlayerDetails.image(from: url)
            guard let self, let image, self.artworkKey == key else { return }
            self.artwork = image
        }
    }

    private func setArtwork(_ image: NSImage, for key: String) {
        artworkKey = key
        artwork = image
    }

    /// Browsers are checked every second while the panel is open, and never while it is closed.
    private func updateBrowserReading() {
        let wanted = isOpen && readsBrowsers && !observers.isEmpty
        if !wanted {
            browserTimer?.invalidate()
            browserTimer = nil
            if !readsBrowsers {
                browserTrack = nil
            } else if let track = browserTrack, track.isPlaying {
                // Nothing reads the browser while closed, so it isn't known to still play.
                browserTrack = track.toggled(at: Date())
            }
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
                    // The same video keeps its place, and what was read from the page, so nothing flickers.
                    if var fresh = track, let old = self.browserTrack, old.key == fresh.key {
                        if old.isPlaying == fresh.isPlaying { return }
                        let elapsed = old.elapsed(at: Date())
                        fresh.artist = old.artist
                        fresh.duration = old.duration
                        fresh.position = elapsed
                        fresh.positionDate = Date()
                        self.browserTrack = fresh
                    } else if track != self.browserTrack {
                        self.browserTrack = track
                        self.refreshVideoDetails()
                    }
                }
            }
        }
    }

    private func updatePlayer(_ info: [AnyHashable: Any]?, from app: String) {
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
            position: (info["Playback Position"] as? NSNumber)?.doubleValue,
            source: app
        )
        refreshAppDetails()
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

    /// Shows the notification under the notch, with its icon and picture, then hides it after a few seconds.
    func showNotice(_ alert: PhoneAlert) {
        noticeWork?.cancel()
        peek = nil
        notice = alert
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.notice = nil } }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5, execute: work)
    }

    func hideNotice() {
        noticeWork?.cancel()
        notice = nil
    }

    func showCode(_ notice: CodeNotice) {
        hideNotice()
        peek = nil
        code = notice
        hideCode(after: 30)
    }

    func copyCode() {
        guard var current = code else { return }
        OneTimeCode.copy(current.code)
        current.copied = true
        code = current
        hideCode(after: 1.4)
    }

    func hideCode(after delay: Double = 0) {
        codeWork?.cancel()
        guard delay > 0 else { code = nil; return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.code = nil } }
        codeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        case .alerts: return alertsAvailable()
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
            case .note: return isShown(.note)
            case .alerts: return isShown(.alerts)
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
        if hasBanner { return closedSize.height + Self.noticeHeight }
        if peek != nil || isFocusing || isWatched { return closedSize.height + statusHeight }
        return !hasNotch && hidesBar ? 0 : closedSize.height
    }

    var focusText: String { focusText(at: Date()) }

    func focusText(at date: Date) -> String { Self.clock(pomodoro.remaining(at: clockDate(date))) }

    /// The time countdowns show: the live time, or a snapshot's.
    func clockDate(_ live: Date) -> Date { frozenNow ?? live }

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
        let date = Date()
        var finished: Pomodoro.Phase?
        // A Mac that slept may have passed more than one step. The timer is a copy until something changes, so
        // a second that passes without a step doesn't redraw anything.
        var timer = pomodoro
        for _ in 0..<timer.steps.count {
            guard let phase = timer.advance(at: date) else { break }
            finished = phase
        }
        guard let finished else { return }
        pomodoro = timer
        now = date
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
        frozenNow = now
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

    /// The banner under the closed notch, in screen points.
    private var codeRect: CGRect {
        let width = max(geometry.closed.width, NotchView.noticeWidth)
        return CGRect(x: geometry.closed.midX - width / 2, y: geometry.closed.minY - NotchModel.noticeHeight,
                      width: width, height: NotchModel.noticeHeight)
    }

    private var openRect: CGRect {
        let size = model.openSize
        return CGRect(x: geometry.closed.midX - size.width / 2 - 14, y: geometry.closed.maxY - size.height - 14,
                      width: size.width + 28, height: size.height + 14)
    }

    private func pointerEvent(_ kind: NSEvent.EventType) {
        let mouse = NSEvent.mouseLocation
        // The panel lets clicks through, except over a code's banner so its Copy button works.
        // Set only when it changes: this runs on every mouse move anywhere on screen.
        if !model.isOpen, let panel {
            let ignores = !(model.code != nil && codeRect.contains(mouse))
            if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
        }
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

    /// The choices offered, from macOS's own spacing (nil) to tight.
    static let levels: [(label: String, value: Int?)] = [("Normal", nil), ("A bit closer", 10), ("Close", 6)]

    /// The gap in points, or nil for macOS's default.
    static var value: Int? {
        get {
            CFPreferencesCopyValue(keys[0], kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Int
        }
        set {
            for key in keys {
                CFPreferencesSetValue(key, newValue.map { $0 as CFNumber },
                                      kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
            }
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
    }
}

/// The chosen spacing, observed so the settings show a new choice straight away.
@MainActor
@Observable
final class MenuBarSpacingChoice {
    static let shared = MenuBarSpacingChoice()
    var value: Int? = MenuBarSpacing.value {
        didSet { MenuBarSpacing.value = value }
    }
}
