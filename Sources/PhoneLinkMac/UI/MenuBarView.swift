import AppKit
import SwiftUI

/// The height the menu's content wants, so the scroll view around it is no taller than that.
@Observable
final class MenuMetrics {
    static let shared = MenuMetrics()
    var contentHeight: CGFloat = 420
}

/// The menu under the DyskLink icon. Its parts and their order are set in Advanced › Menu bar.
struct MenuBarView: View {
    let model: AppModel
    var layout: MenuBarLayout = Shared.menuBar
    var tools: ToolsModel = Shared.tools
    /// Snapshots draw the menu without its scroll view, which renders empty off screen.
    var scrolls = true

    private typealias Section = MenuBarLayout.Section

    var body: some View {
        // Taller than the screen, the menu scrolls instead of running off the bottom.
        if scrolls { scrolling } else {
            content.background(Theme.panel).preferredColorScheme(.dark)
        }
    }

    private var scrolling: some View {
        let room = max(240, (NSScreen.main?.visibleFrame.height ?? 900) - 12)
        return ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { MenuMetrics.shared.contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(width: width, height: min(MenuMetrics.shared.contentHeight, room))
        .background(Theme.panel)
        .background(MenuWindowAnchor())
        .preferredColorScheme(.dark)
    }

    private var width: CGFloat { layout.visible.filter(isAvailable).contains(.powerFlow) ? 340 : 330 }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                LogoMark(size: 26)
                Text("DyskLink").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if case .listening = model.serverState {
                    Circle().fill(Theme.mint).frame(width: 8, height: 8)
                }
            }
            if model.hasUpdateWaiting {
                // Updates live in one card in Advanced › General, so the menu points there.
                Button { model.showUpdates() } label: {
                    row("arrow.down.circle.fill", updateTitle, tint: Theme.mint)
                }
                .buttonStyle(.plain)
                .help("Open Advanced › General › Updates")
            }
            let sections = layout.visible.filter(isAvailable)
            ForEach(sections) { section in
                Divider().overlay(Theme.stroke)
                content(section)
            }
            if sections.isEmpty { emptyHint }
            Divider().overlay(Theme.stroke)
            HStack {
                Button("Open DyskLink") { MainWindow.show() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        // The battery part has a power diagram and charts, so the menu is a little wider with it.
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var updateTitle: String {
        if let release = Shared.updates.available { return "DyskLink \(release.version) is available" }
        return "A phone needs a DyskLink update"
    }

    private var connectedPhones: [Peer] { model.peers.filter { $0.isPaired && $0.isConnected && !$0.isComputer } }
    private var recentCopies: [ClipEntry] { Array(tools.clipboard.entries.filter { $0.text?.isEmpty == false }.prefix(3)) }

    /// Parts with nothing to show are left out, so the menu has no empty sections.
    private func isAvailable(_ section: Section) -> Bool {
        switch section {
        case .batteryLimit, .batteryStatus, .powerFlow, .energyApps, .batteryLevel, .batteryDetails, .powerUse: Shared.care.hasBattery
        case .displays: tools.isDisplaysOn
        case .awake: tools.isAwakeOn
        case .layouts: tools.isLayoutOn && !tools.layout.layouts.isEmpty
        case .clipboard: tools.isClipboardOn && !recentCopies.isEmpty
        case .findPhone, .sendFile: !connectedPhones.isEmpty
        case .weather: tools.notch.model.weather.report != nil
        default: true
        }
    }

    @ViewBuilder
    private func content(_ section: Section) -> some View {
        switch section {
        case .devices: devices
        case .batteryLimit: MenuBatterySection(part: .limit)
        case .batteryStatus: MenuBatterySection(part: .status)
        case .powerFlow: MenuBatterySection(part: .flow)
        case .energyApps: MenuBatterySection(part: .apps)
        case .batteryLevel: MenuBatterySection(part: .level)
        case .batteryDetails: MenuBatterySection(part: .details)
        case .powerUse: MenuBatterySection(part: .power)
        case .displays: DisplaySliders(control: tools.displays)
        case .awake: awake
        case .layouts:
            ForEach(tools.layout.layouts) { saved in
                Button { tools.layout.restore(saved) } label: { row("rectangle.split.3x1", "Restore \(saved.name)") }
                    .buttonStyle(.plain)
            }
        case .clipboard:
            VStack(alignment: .leading, spacing: 8) {
                caption("RECENT COPIES")
                ForEach(recentCopies) { entry in
                    Button { tools.clipboard.copy(entry) } label: {
                        row("doc.on.doc", (entry.text ?? "").replacingOccurrences(of: "\n", with: " "))
                    }
                    .buttonStyle(.plain)
                    .help("Copy again")
                }
            }
        case .findPhone:
            ForEach(connectedPhones) { phone in
                let ringing = model.ringingPhones.contains(phone.id)
                Button { model.ringPhone(phone.id, !ringing) } label: {
                    row(ringing ? "bell.slash.fill" : "bell.and.waves.left.and.right.fill",
                        ringing ? "Stop ringing \(phone.name)" : "Ring \(phone.name)", tint: ringing ? Theme.coral : Theme.amber)
                }
                .buttonStyle(.plain)
            }
        case .sendFile:
            ForEach(connectedPhones) { phone in
                Button { chooseFiles(for: phone) } label: { row("paperplane.fill", "Send a file to \(phone.name)…", tint: Theme.mint) }
                    .buttonStyle(.plain)
                    .help("Or drop files here")
                    .dropDestination(for: URL.self) { urls, _ in
                        let files = urls.filter(\.isFileURL)
                        files.forEach { model.sendFile($0, to: phone.id) }
                        return !files.isEmpty
                    }
            }
        case .lock:
            Button { MacActions.lockScreen() } label: { row("lock.fill", "Lock screen") }.buttonStyle(.plain)
        case .pomodoro: pomodoro
        case .weather: weather
        case .note: note
        case .login:
            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text("Open at login").foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.dyskSwitch)
            .font(.system(size: 12.5, weight: .medium))
        }
    }

    private func chooseFiles(for phone: Peer) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to send to \(phone.name)"
        panel.prompt = "Send"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { model.sendFile($0, to: phone.id) }
    }

    private var devices: some View {
        let paired = model.peers.filter(\.isPaired)
        return VStack(alignment: .leading, spacing: 10) {
            if paired.isEmpty {
                Text("No paired devices yet.").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
            ForEach(paired) { peer in
                HStack(spacing: 9) {
                    Image(systemName: peer.isComputer ? "laptopcomputer" : "iphone.gen3")
                        .foregroundStyle(peer.isConnected ? Theme.mint : Theme.textFaint)
                    Text(peer.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    if peer.isConnected, let percent = peer.info?.batteryPercent {
                        Text("\(percent)%").font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.batteryColor(percent))
                    }
                }
            }
        }
    }

    /// Shown when every part is turned off, so the menu doesn't look broken.
    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.stroke)
            Text("Nothing to show here. Choose what appears in this menu in Advanced › Menu bar.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Self.openMenuSettings()
            } label: {
                row("slider.horizontal.3", "Choose what to show", tint: Theme.mint)
            }
            .buttonStyle(.plain)
        }
    }

    static func openMenuSettings() {
        Shared.model.showsHistory = false
        Shared.model.showsCare = false
        Shared.model.showsTools = true
        MainWindow.show()
    }

    private func awakeLabel(_ minutes: Int) -> String {
        if minutes == KeepAwake.customChoice { return "Custom (\(tools.awake.customHours)h \(tools.awake.customMinutes)m)" }
        return KeepAwake.durations.first { $0.minutes == minutes }?.label ?? "1 hour"
    }

    private var awake: some View {
        let awake = tools.awake
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(awake.isActive ? Theme.mint : Theme.textFaint).frame(width: 16)
                Text(awake.isActive ? "Keep Awake is on" : "Keep Awake").foregroundStyle(Theme.textPrimary)
                Spacer()
                if awake.isActive {
                    Text(awake.isPaused ? "Paused" : awake.remainingText)
                        .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            HStack(spacing: 8) {
                if awake.isActive {
                    Spacer()
                } else {
                    Menu {
                        ForEach(KeepAwake.durations, id: \.minutes) { choice in
                            Button {
                                awake.minutes = choice.minutes
                            } label: {
                                if choice.minutes == awake.minutes {
                                    Label(awakeLabel(choice.minutes), systemImage: "checkmark")
                                } else {
                                    Text(awakeLabel(choice.minutes))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(awakeLabel(awake.minutes)).lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textFaint)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    if awake.isActive { awake.stop() } else { awake.start() }
                } label: {
                    Text(awake.isActive ? "Stop" : "Start")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(awake.isActive ? Theme.coral : Theme.ink)
                        .frame(width: 64, height: 26)
                        .background(awake.isActive ? Theme.coral.opacity(0.15) : Theme.mint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!awake.isActive && !awake.canStart)
            }
        }
    }

    private var pomodoro: some View {
        let notch = tools.notch.model
        // Ticks only while a timer runs.
        return TimelineView(.animation(minimumInterval: 1, paused: !notch.isFocusing)) { context in
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(notch.isFocusing ? Theme.coral : Theme.textFaint)
                Text("Pomodoro").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(notch.focusText(at: context.date)).font(.system(size: 12.5, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(notch.isFocusing ? "Pause" : "Start") { notch.togglePomodoro() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
            }
        }
    }

    @ViewBuilder private var weather: some View {
        let model = tools.notch.model.weather
        if let report = model.report {
            HStack(spacing: 8) {
                Image(systemName: WeatherAPI.symbol(report.code, isDay: report.isDay)).symbolRenderingMode(.multicolor)
                Text("\(Int(report.temperature.rounded()))° \(WeatherAPI.describe(report.code))")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                if let place = model.place {
                    Text(place.shortName).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
        }
    }

    private var note: some View {
        let note = tools.notch.model.note
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                caption("QUICK NOTE")
                Spacer()
                Button("Edit") { NoteEditor.show(note) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
            }
            Text(note.text.isEmpty ? "Empty" : note.text).font(.system(size: 12.5))
                .foregroundStyle(note.text.isEmpty ? Theme.textFaint : Theme.textPrimary).lineLimit(4)
                .textSelection(.enabled)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .bold)).tracking(0.8).foregroundStyle(Theme.textFaint)
    }

    private func row(_ icon: String, _ title: String, tint: Color = Theme.textFaint) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            Text(title).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer()
        }
        .font(.system(size: 12.5, weight: .medium))
        .contentShape(Rectangle())
    }
}

/// One part of the Mac battery and charging view in the menu. Power is only sampled while the menu is open.
struct MenuBatterySection: View {
    let part: BatteryDashboard.Part
    var power = PowerMonitor.shared

    var body: some View {
        Group {
            if let battery = power.battery ?? Shared.care.battery {
                BatteryDashboard(battery: battery, control: ChargeControl.shared, power: power, compact: true, only: part)
            } else {
                Text("Reading the battery…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        // The menu's window stays alive while it's closed, so onAppear and onDisappear don't follow it.
        // Sampling follows the window being on screen instead.
        .background {
            // Snapshots can't draw this AppKit view, and don't sample anyway.
            if !power.previewing {
                WindowVisibility { visible in
                    if visible { power.begin() } else { power.end() }
                }
            }
        }
    }
}

/// Tells when the window holding this view comes on screen and goes away: ordered in or out, or fully covered.
/// Each "true" is followed by one "false", also when the view leaves the window.
struct WindowVisibility: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> WatchView { WatchView(changed: changed) }
    func updateNSView(_ view: WatchView, context: Context) { view.changed = changed }
    static func dismantleNSView(_ view: WatchView, coordinator: ()) { view.set(false) }

    final class WatchView: NSView {
        var changed: @MainActor (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var isVisible = false

        init(changed: @escaping @MainActor (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return set(false) }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        self?.check(closing: note.name == NSWindow.willCloseNotification)
                        // A menu window is ordered out just after it loses focus, so it's looked at again then.
                        if note.name == NSWindow.didResignKeyNotification {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                                MainActor.assumeIsolated { self?.check(closing: false) }
                            }
                        }
                    }
                })
            }
            check(closing: false)
            // The menu's window doesn't always post a notification when it's shown, so this also looks once a second.
            // It only reads a flag, so it costs next to nothing.
            timer?.invalidate()
            let poll = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check(closing: false) }
            }
            poll.tolerance = 0.5
            RunLoop.main.add(poll, forMode: .common)
            timer = poll
        }

        private var timer: Timer?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { timer?.invalidate(); timer = nil }
        }

        private func check(closing: Bool) {
            guard let window, !closing else { return set(false) }
            // Ordered in is what counts: a menu window can report itself occluded while it's open.
            set(window.isVisible)
        }

        func set(_ visible: Bool) {
            guard visible != isVisible else { return }
            isVisible = visible
            changed(visible)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            timer?.invalidate()
        }
    }
}


/// Keeps the menu's window right under the menu bar. When its content changes size while it's open, the window keeps
/// its bottom edge, so without this the top drops away from the menu bar and leaves a gap.
struct MenuWindowAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) { view.pin() }

    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pin() }
                })
            }
            pin()
        }

        func pin() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let frame = window.frame
            let top = MenuWindowAnchor.top(frame: frame, visible: screen.visibleFrame)
            guard top != frame.maxY else { return }
            window.setFrameOrigin(CGPoint(x: frame.minX, y: top - frame.height))
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    /// Where the window's top edge belongs: just under the menu bar.
    static func top(frame: CGRect, visible: CGRect) -> CGFloat {
        abs(frame.maxY - visible.maxY) <= 1 ? frame.maxY : visible.maxY
    }
}
