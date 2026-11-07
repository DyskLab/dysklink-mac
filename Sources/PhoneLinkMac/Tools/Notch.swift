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
}

@MainActor
@Observable
final class NotchModel {
    enum Page: String, CaseIterable { case home = "Home", shelf = "Shelf", clipboard = "Clipboard" }

    /// With a camera, the menu and content start below it, so the camera never covers them.
    static func contentTop(hasNotch: Bool, notchHeight: CGFloat) -> CGFloat {
        hasNotch ? notchHeight + 6 : 2
    }

    var openSize: CGSize {
        CGSize(width: 560, height: 198 + Self.contentTop(hasNotch: hasNotch, notchHeight: closedSize.height) + 36)
    }

    var isOpen = false
    var page = Page.home
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
    private(set) var nowPlaying: NowPlaying?
    private(set) var power = PowerStatus()
    private(set) var shelf: [ShelfItem] = []
    private(set) var focusEnd: Date?
    private(set) var now = Date()

    @ObservationIgnored private let shelfFile: URL
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var focusTimer: Timer?
    @ObservationIgnored private var peekWork: DispatchWorkItem?

    init(directory: URL) {
        shelfFile = directory.appendingPathComponent("notch-shelf.json")
        opensOnClick = UserDefaults.standard.bool(forKey: "notch.opensOnClick")
        hidesBar = UserDefaults.standard.object(forKey: "notch.hidesBar") as? Bool ?? true
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
        stopFocus()
        isOpen = false
        nowPlaying = nil
    }

    private func updatePlayer(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" {
            nowPlaying = nil
            return
        }
        let title = info["Name"] as? String ?? nowPlaying?.title ?? ""
        let artist = info["Artist"] as? String ?? nowPlaying?.artist ?? ""
        nowPlaying = title.isEmpty ? nil : NowPlaying(title: title, artist: artist, isPlaying: state == "Playing")
    }

    func powerChanged() {
        let next = PowerStatus.current()
        if next.isOnBattery != power.isOnBattery, let percent = next.percent {
            showPeek(next.isOnBattery ? "On battery · \(percent)%" : "Plugged in · \(percent)%")
        }
        power = next
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

    /// The mode switch is a display setting, so the page rereads it after a change.
    private(set) var modeRevision = 0

    func modeChanged() { modeRevision += 1 }

    var isFocusing: Bool { focusEnd != nil }

    /// How tall the closed shape is. Status always shows, even when the bar is hidden.
    func closedHeight(statusHeight: CGFloat) -> CGFloat {
        if peek != nil || isFocusing { return closedSize.height + statusHeight }
        return !hasNotch && hidesBar ? 0 : closedSize.height
    }

    var focusText: String {
        guard let focusEnd else { return "25:00" }
        let seconds = max(0, Int(focusEnd.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func startFocus(minutes: Int = 25) {
        focusEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        now = Date()
        focusTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let end = self.focusEnd else { return }
                self.now = Date()
                if self.now >= end {
                    self.stopFocus()
                    NSSound(named: "Glass")?.play()
                    self.showPeek("Focus finished")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        focusTimer = timer
    }

    func stopFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
        focusEnd = nil
    }

    #if DEBUG
    func loadSnapshot(playing: NowPlaying?, focus: Date?) {
        nowPlaying = playing
        focusEnd = focus
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
            if isOver, (NSPasteboard(name: .drag).types ?? []).contains(.fileURL) {
                model.page = .shelf
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

struct NotchView: View {
    let model: NotchModel
    let tools: ToolsModel
    var phoneProvider: () -> [Peer] = { Shared.model.peers.filter { $0.isPaired && $0.isConnected } }

    /// Status sits under the notch, so it never covers the menu bar on either side.
    private static let statusHeight: CGFloat = 24

    private var hasStatus: Bool { model.peek != nil || model.isFocusing }

    private var shape: NotchShape {
        if model.isOpen {
            return NotchShape(width: model.openSize.width - 16, height: model.openSize.height,
                              bottomRadius: 22, topRadius: 8)
        }
        let base = model.closedSize
        return NotchShape(width: base.width, height: model.closedHeight(statusHeight: Self.statusHeight),
                          bottomRadius: hasStatus ? 12 : (model.hasNotch ? 9 : 3), topRadius: 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            statusRow
                .opacity(!model.isOpen && hasStatus ? 1 : 0)
                .padding(.top, model.closedSize.height)
            // The open content is always laid out, so opening only has to reveal it.
            openContent
                .frame(width: model.openSize.width - 28, height: model.openSize.height, alignment: .top)
                .opacity(model.isOpen ? 1 : 0)
                .allowsHitTesting(model.isOpen)
                .mask(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if let peek = model.peek {
                Text(peek).lineLimit(1)
            } else if model.isFocusing {
                Image(systemName: "timer").foregroundStyle(Theme.mint)
                Text(model.focusText).monospacedDigit()
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.white)
        .frame(width: model.closedSize.width, height: Self.statusHeight)
    }

    private var openContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(NotchModel.Page.allCases, id: \.self) { page in
                    Button(page.rawValue) { model.page = page }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.page == page ? Color.white : Theme.textFaint)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(model.page == page ? Color.white.opacity(0.12) : Color.clear, in: Capsule())
                }
                Spacer(minLength: 10)
                clock
            }
            .frame(height: 26)
            switch model.page {
            case .home: home
            case .shelf: shelf
            case .clipboard: clipboard
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, NotchModel.contentTop(hasNotch: model.hasNotch, notchHeight: model.closedSize.height))
        .padding(.bottom, 14)
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(context.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white)
        }
    }

    // MARK: Home

    private var home: some View {
        HStack(alignment: .top, spacing: 10) {
            tile { media }.frame(maxWidth: .infinity)
            VStack(spacing: 10) {
                tile { focus }
                tile { batteries }
            }
            .frame(width: 210)
        }
        .frame(maxHeight: .infinity)
    }

    private func tile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var media: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Now playing").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
            Text(model.nowPlaying?.title ?? "Nothing from Music or Spotify")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.white).lineLimit(2)
            if let artist = model.nowPlaying?.artist, !artist.isEmpty {
                Text(artist).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 22) {
                mediaButton("backward.fill", label: "Previous", action: "previous", size: 15)
                mediaButton(model.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill", label: "Play or pause", action: "play_pause", size: 20)
                mediaButton("forward.fill", label: "Next", action: "next", size: 15)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func mediaButton(_ icon: String, label: String, action: String, size: CGFloat) -> some View {
        Button { DeviceInput.media(action) } label: {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(Color.white).frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var focus: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Focus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
                Text(model.focusText).font(.system(size: 19, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.white)
            }
            Spacer()
            Button(model.isFocusing ? "Stop" : "Start") {
                if model.isFocusing { model.stopFocus() } else { model.startFocus() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.white.opacity(0.14), in: Capsule())
        }
    }

    private var batteries: some View {
        VStack(alignment: .leading, spacing: 6) {
            batteryRow("laptopcomputer", "This Mac", model.power.percent, model.power.isCharging)
            ForEach(phoneProvider().prefix(1)) { peer in
                batteryRow("iphone.gen3", peer.name, peer.info?.batteryPercent, peer.info?.isCharging == true)
            }
        }
    }

    private func batteryRow(_ icon: String, _ name: String, _ percent: Int?, _ charging: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 16)
            Text(name).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer(minLength: 4)
            if charging { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.textSecondary) }
            Text(percent.map { "\($0)%" } ?? "-").font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white)
        }
    }

    // MARK: Shelf

    private var shelf: some View {
        Group {
            if model.shelf.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22)).foregroundStyle(Theme.textSecondary)
                    Text("Drop files here").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white)
                    Text("Files stay where they are. The shelf only remembers them.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.shelf) { item in shelfCard(item) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        }
    }

    private func shelfCard(_ item: ShelfItem) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 46, height: 46)
            Text(item.name).font(.system(size: 11)).foregroundStyle(Color.white)
                .lineLimit(2).multilineTextAlignment(.center).frame(width: 92)
            Button("Remove") { model.remove(item) }.buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textFaint)
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
    }

    // MARK: Clipboard

    private var clipboard: some View {
        Group {
            if !tools.isClipboardOn {
                Text("Turn on Clipboard History in Advanced to see it here.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let items = tools.clipboard.matches("").filter { $0.text != nil }.prefix(4)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(items)) { entry in
                        Button { tools.clipboard.copy(entry); model.showPeek("Copied") } label: {
                            Text(entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                                .font(.system(size: 12)).foregroundStyle(Color.white).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if items.isEmpty {
                        Text("Nothing copied yet").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
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
