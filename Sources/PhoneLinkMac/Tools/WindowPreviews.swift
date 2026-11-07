import AppKit
import Observation
import os
import SwiftUI

private let log = Logger(subsystem: "id.phonelink.mac", category: "Windows")

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
@Observable
final class WindowListState {
    var windows: [WindowItem] = []
    var images: [CGWindowID: NSImage] = [:]
    var selection = 0
    var appName = ""
}

/// Follows the Dock's own Accessibility events, so nothing runs while the pointer is elsewhere.
@MainActor
final class DockWatcher {
    var onHover: ((NSRunningApplication?, CGRect) -> Void)?

    private var observer: AXObserver?
    private var dockPid: pid_t = 0
    private var retryTimer: Timer?

    func start() {
        attach()
        // The Dock restarts now and then, and Accessibility may be granted later.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        detach()
    }

    private func attachIfNeeded() {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier ?? 0
        if observer == nil || pid != dockPid { attach() }
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockPid = 0
    }

    private func attach() {
        detach()
        guard DeviceInput.isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
              let list = (children as? [AXUIElement])?.first(where: { Self.role(of: $0) == kAXListRole })
        else {
            log.error("The Dock list wasn't found")
            return
        }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, _ in
            MainActor.assumeIsolated { Shared.tools.previews.watcher.selectionChanged(element) }
        }
        guard AXObserverCreate(dock.processIdentifier, callback, &created) == .success, let created,
              AXObserverAddNotification(created, list, kAXSelectedChildrenChangedNotification as CFString, nil) == .success
        else {
            log.error("Couldn't follow the Dock")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        dockPid = dock.processIdentifier
        log.info("Following the Dock")
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        return value as? String
    }

    fileprivate func selectionChanged(_ list: AXUIElement) {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXSelectedChildrenAttribute as CFString, &value)
        guard let icon = (value as? [AXUIElement])?.first else { return onHover?(nil, .zero) ?? () }
        onHover?(Self.application(for: icon), Self.frame(of: icon))
    }

    private static func application(for icon: AXUIElement) -> NSRunningApplication? {
        var url: CFTypeRef?
        AXUIElementCopyAttributeValue(icon, kAXURLAttribute as CFString, &url)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let url = url as? URL, let match = apps.first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
            return match
        }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(icon, kAXTitleAttribute as CFString, &title)
        return apps.first { $0.localizedName == title as? String }
    }

    /// Accessibility measures from the top of the main screen, and AppKit from the bottom.
    private static func frame(of icon: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size = CGSize.zero
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(icon, kAXPositionAttribute as CFString, &value) == .success, let value {
            AXValueGetValue(value as! AXValue, .cgPoint, &position)
        }
        value = nil
        if AXUIElementCopyAttributeValue(icon, kAXSizeAttribute as CFString, &value) == .success, let value {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: position.x, y: height - position.y - size.height, width: size.width, height: size.height)
    }
}

@MainActor
@Observable
final class WindowPreviews {
    var usesSwitcher: Bool {
        didSet {
            UserDefaults.standard.set(usesSwitcher, forKey: "windows.switcher")
            applySwitcher()
        }
    }
    private(set) var shortcutProblem: String?

    @ObservationIgnored let watcher = DockWatcher()
    @ObservationIgnored private let dockState = WindowListState()
    @ObservationIgnored private let switcherState = WindowListState()
    @ObservationIgnored private var dockPanel: NSPanel?
    @ObservationIgnored private var switcherPanel: NSPanel?
    @ObservationIgnored private var dockTimer: Timer?
    @ObservationIgnored private var switcherTimer: Timer?
    @ObservationIgnored private var tapRetryTimer: Timer?
    @ObservationIgnored private var iconFrame = CGRect.zero
    @ObservationIgnored private var shownPid: pid_t = 0
    @ObservationIgnored private var isDockVisible = false
    @ObservationIgnored private var imageCache: [CGWindowID: NSImage] = [:]
    @ObservationIgnored private var outsideSince: Date?
    @ObservationIgnored private var isOn = false

    private static let dockWidth: CGFloat = 250
    private static let switcherWidth: CGFloat = 220
    private static let closeDelay = 0.08
    private static let maxCachedImages = 60

    init() {
        usesSwitcher = UserDefaults.standard.object(forKey: "windows.switcher") as? Bool ?? true
    }

    func start() {
        guard !isOn else { return }
        isOn = true
        watcher.onHover = { [weak self] app, frame in self?.hover(app, frame) }
        watcher.start()
        applySwitcher()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        watcher.stop()
        closeDock()
        dockPanel = nil
        imageCache = [:]
        closeSwitcher(commit: false)
        stopSwitcherKeys()
    }

    private func applySwitcher() {
        guard isOn else { return }
        guard usesSwitcher else {
            closeSwitcher(commit: false)
            stopSwitcherKeys()
            return
        }
        guard !startSwitcherKeys() else { return }
        shortcutProblem = "Option + Tab needs Accessibility."
        guard tapRetryTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.startSwitcherKeys() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tapRetryTimer = timer
    }

    private func startSwitcherKeys() -> Bool {
        let isStarted = SwitcherTap.shared.start { [weak self] command in self?.run(command) }
        if isStarted {
            tapRetryTimer?.invalidate()
            tapRetryTimer = nil
            shortcutProblem = nil
        }
        return isStarted
    }

    private func stopSwitcherKeys() {
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        SwitcherTap.shared.stop()
        shortcutProblem = nil
    }

    private func run(_ command: SwitcherCommand) {
        switch command {
        case .forward: advanceSwitcher(by: 1)
        case .back: advanceSwitcher(by: -1)
        case .commit: closeSwitcher(commit: true)
        case .cancel: closeSwitcher(commit: false)
        }
    }

    // MARK: Dock

    /// The Dock can report the same icon many times, so only a real change to another app updates the panel.
    private func hover(_ app: NSRunningApplication?, _ icon: CGRect) {
        // An empty selection is left to the pointer check, which follows the pointer itself.
        guard icon != .zero else { return }
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            closeDock()
            return
        }
        if isDockVisible, shownPid == app.processIdentifier {
            iconFrame = icon
            return
        }
        let windows = WindowCatalog.windows(of: app)
        guard !windows.isEmpty else {
            closeDock()
            return
        }
        showDock(windows, app: app, icon: icon)
    }

    private func showDock(_ windows: [WindowItem], app: NSRunningApplication, icon: CGRect) {
        iconFrame = icon
        shownPid = app.processIdentifier
        dockState.appName = app.localizedName ?? ""
        dockState.windows = windows
        // Pictures seen before appear at once, and newer ones replace them without a blank moment.
        dockState.images = imageCache.filter { id, _ in windows.contains { $0.id == id } }
        outsideSince = nil
        placeDock(windowCount: windows.count)
        startDockTimer()
        isDockVisible = true
        requestImages(for: windows)
    }

    /// The panel's size is calculated, so it never has to resize after the content appears.
    private func placeDock(windowCount: Int) {
        let panel = dockPanel ?? makeDockPanel()
        dockPanel = panel
        let size = WindowStrip.size(count: windowCount, cardWidth: Self.dockWidth, isSwitcher: false,
                                    showsHint: !CGPreflightScreenCaptureAccess())
        let screen = NSScreen.screens.first { $0.frame.intersects(iconFrame) } ?? NSScreen.main
        let origin = WindowCatalog.placement(panel: size, icon: iconFrame, screen: screen?.frame ?? .zero)
        panel.setFrame(CGRect(origin: origin, size: size), display: false)
        panel.orderFrontRegardless()
    }

    private func makeDockPanel() -> NSPanel {
        let view = WindowStrip(state: dockState, cardWidth: Self.dockWidth, isSwitcher: false) { [weak self] window in
            WindowCatalog.focus(window)
            self?.closeDock()
        } onClose: { [weak self] window in
            WindowCatalog.close(window)
            self?.removeSoon(window)
        } onMinimize: { [weak self] window in
            WindowCatalog.minimize(window)
            self?.closeDock()
        }
        let panel = Self.makePanel()
        panel.contentView = ClickThroughHostingView(rootView: AnyView(view))
        return panel
    }

    private func requestImages(for windows: [WindowItem]) {
        let ids = windows.filter { !$0.isMinimized }.map(\.id)
        let pid = shownPid
        Task {
            let images = await WindowCatalog.thumbnails(for: ids, width: Int(Self.dockWidth * 2))
            imageCache.merge(images) { _, new in new }
            if imageCache.count > Self.maxCachedImages { imageCache = images }
            if isDockVisible, shownPid == pid { dockState.images.merge(images) { _, new in new } }
        }
    }

    private func removeSoon(_ window: WindowItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.isDockVisible, let app = NSRunningApplication(processIdentifier: window.pid) else { return }
            let left = WindowCatalog.windows(of: app)
            if left.isEmpty {
                self.closeDock()
            } else {
                self.dockState.windows = left
                self.placeDock(windowCount: left.count)
            }
        }
    }

    private func startDockTimer() {
        guard dockTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDockPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dockTimer = timer
    }

    /// The Dock doesn't always report that the pointer left, so the pointer itself decides.
    private func checkDockPointer() {
        guard let panel = dockPanel else { return }
        if WindowCatalog.keepsPreview(pointer: NSEvent.mouseLocation, icon: iconFrame, panel: panel.frame) {
            outsideSince = nil
        } else if let since = outsideSince {
            if Date().timeIntervalSince(since) >= Self.closeDelay { closeDock() }
        } else {
            outsideSince = Date()
        }
    }

    private func closeDock() {
        dockTimer?.invalidate()
        dockTimer = nil
        dockPanel?.orderOut(nil)
        isDockVisible = false
        shownPid = 0
        outsideSince = nil
    }

    // MARK: Switcher

    private func advanceSwitcher(by step: Int) {
        guard switcherPanel != nil else {
            if step > 0 { showSwitcher() }
            return
        }
        let count = switcherState.windows.count
        guard count > 0 else { return }
        switcherState.selection = (switcherState.selection + step + count) % count
    }

    private func showSwitcher() {
        let windows = WindowCatalog.allWindows(limit: 24)
        guard !windows.isEmpty else { return }
        switcherState.windows = windows
        switcherState.images = [:]
        // The first press goes to the window behind the current one, as Command + Tab does for apps.
        switcherState.selection = windows.count > 1 ? 1 : 0
        let view = WindowStrip(state: switcherState, cardWidth: Self.switcherWidth, isSwitcher: true) { [weak self] window in
            self?.switcherState.selection = self?.switcherState.windows.firstIndex { $0.id == window.id } ?? 0
            self?.closeSwitcher(commit: true)
        } onClose: { _ in } onMinimize: { _ in }
        let hosting = ClickThroughHostingView(rootView: AnyView(view))
        let panel = Self.makePanel()
        panel.contentView = hosting
        let size = WindowStrip.size(count: windows.count, cardWidth: Self.switcherWidth, isSwitcher: true,
                                    showsHint: !CGPreflightScreenCaptureAccess())
        let mouse = NSEvent.mouseLocation
        let area = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        // The app in front keeps its keyboard focus, and the tap handles keys while this is open.
        panel.orderFrontRegardless()
        switcherPanel = panel
        SwitcherTap.shared.setOpen(true)
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if !CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) { self?.closeSwitcher(commit: true) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        switcherTimer = timer
        let state = switcherState
        let ids = windows.filter { !$0.isMinimized }.map(\.id)
        Task {
            let images = await WindowCatalog.thumbnails(for: ids, width: Int(Self.switcherWidth * 2))
            if self.switcherPanel != nil { state.images = images }
        }
    }

    private func closeSwitcher(commit: Bool) {
        switcherTimer?.invalidate()
        switcherTimer = nil
        SwitcherTap.shared.setOpen(false)
        guard let panel = switcherPanel else { return }
        panel.orderOut(nil)
        switcherPanel = nil
        let list = switcherState.windows
        if commit, list.indices.contains(switcherState.selection) { WindowCatalog.focus(list[switcherState.selection]) }
        switcherState.windows = []
    }

    private static func makePanel() -> NSPanel {
        let panel = ClickablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

struct WindowStrip: View {
    let state: WindowListState
    let cardWidth: CGFloat
    let isSwitcher: Bool
    let onChoose: (WindowItem) -> Void
    let onClose: (WindowItem) -> Void
    let onMinimize: (WindowItem) -> Void

    private static let perRow = 4
    private static let outerPadding: CGFloat = 12
    private static let cardPadding: CGFloat = 7
    private static let spacing: CGFloat = 10
    private static let headerHeight: CGFloat = 16
    private static let titleHeight: CGFloat = 18
    private static let hintHeight: CGFloat = 14

    private static func thumbnailHeight(_ width: CGFloat) -> CGFloat { (width * 0.62).rounded() }

    /// Every part has a fixed size, so long titles can't stretch a card.
    static func size(count: Int, cardWidth: CGFloat, isSwitcher: Bool, showsHint: Bool) -> CGSize {
        let columns = CGFloat(min(max(count, 1), perRow))
        let rows = CGFloat((max(count, 1) + perRow - 1) / perRow)
        let card = CGSize(width: cardWidth + cardPadding * 2, height: titleHeight + 7 + thumbnailHeight(cardWidth) + cardPadding * 2)
        var height = rows * card.height + (rows - 1) * spacing + outerPadding * 2
        if !isSwitcher { height += headerHeight + spacing }
        if showsHint { height += hintHeight + spacing }
        return CGSize(width: columns * card.width + (columns - 1) * spacing + outerPadding * 2, height: height)
    }

    var body: some View {
        let rows = stride(from: 0, to: state.windows.count, by: Self.perRow).map { start in
            Array(state.windows.indices[start..<min(start + Self.perRow, state.windows.count)])
        }
        VStack(alignment: .leading, spacing: Self.spacing) {
            if !isSwitcher {
                Text(state.appName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).padding(.horizontal, 4).frame(height: Self.headerHeight)
            }
            ForEach(rows, id: \.first) { row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row, id: \.self) { index in card(index) }
                }
            }
            if !CGPreflightScreenCaptureAccess() {
                Text("Allow Screen Recording in Advanced to see pictures of windows.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1)
                    .padding(.horizontal, 4).frame(height: Self.hintHeight)
            }
        }
        .padding(Self.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
        .preferredColorScheme(.dark)
    }

    private func card(_ index: Int) -> some View {
        let window = state.windows[index]
        let isSelected = isSwitcher && state.selection == index
        let thumbnail = Self.thumbnailHeight(cardWidth)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let icon = window.icon { Image(nsImage: icon).resizable().frame(width: 15, height: 15) }
                Text(window.title.isEmpty ? window.appName : window.title)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isSwitcher {
                    iconButton("minus", label: "Minimize") { onMinimize(window) }
                    iconButton("xmark", label: "Close") { onClose(window) }
                }
            }
            .frame(width: cardWidth, height: Self.titleHeight)
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.panelRaised)
                if let image = state.images[window.id] {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else if let icon = window.icon {
                    VStack(spacing: 6) {
                        Image(nsImage: icon).resizable().frame(width: 38, height: 38)
                        if window.isMinimized {
                            Text("Minimized").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        }
                    }
                }
            }
            .frame(width: cardWidth, height: thumbnail)
        }
        .padding(Self.cardPadding)
        .background(isSelected ? Theme.panelRaised : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? Theme.mint : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { onChoose(window) }
    }

    private func iconButton(_ name: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}
