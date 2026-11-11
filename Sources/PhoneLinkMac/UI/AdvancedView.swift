import AppKit
import ServiceManagement
import SwiftUI

/// The optional tools. Each card only shows its controls while its switch is on.
struct AdvancedView: View {
    @Bindable var tools: ToolsModel
    var scrolls = true

    private static let donationURL = URL(string: "https://buymeacoffee.com/fannydevz")!

    /// One tool as the overview and the category pages know it.
    private struct Entry {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let category: AdvancedCategory
        let isOn: Binding<Bool>
    }

    private var entries: [Entry] {
        [
            Entry(id: "clipboard", icon: "doc.on.clipboard.fill", title: "Clipboard History",
                  detail: "Search everything you copied, and copy text from anywhere on screen.", category: .productivity, isOn: $tools.isClipboardOn),
            Entry(id: "launcher", icon: "magnifyingglass", title: "Launcher",
                  detail: "One shortcut opens a search box for apps, files, windows, copies, sums, units, and DyskLink actions.", category: .productivity, isOn: $tools.isLauncherOn),
            Entry(id: "awake", icon: "cup.and.saucer.fill", title: "Keep Awake",
                  detail: "Stops this Mac or its screen from sleeping for as long as you choose.", category: .productivity, isOn: $tools.isAwakeOn),
            Entry(id: "macs", icon: "laptopcomputer.and.arrow.down", title: "Other computers",
                  detail: "Pair with other Macs and Windows or Linux PCs on this network to share copies, pictures, and files.", category: .productivity, isOn: Bindable(Shared.model).macSyncEnabled),
            Entry(id: "layout", icon: "rectangle.split.3x1", title: "Window Layout",
                  detail: "Snap the front window to halves, thirds, or quarters with shortcuts, and save whole layouts.", category: .windows, isOn: $tools.isLayoutOn),
            Entry(id: "previews", icon: "macwindow.on.rectangle", title: "Window Previews",
                  detail: "See an app's windows when you point at its Dock icon, and switch windows with Option + Tab.", category: .windows, isOn: $tools.isPreviewsOn),
            Entry(id: "displays", icon: "sun.max.fill", title: "Brightness and Volume",
                  detail: "Sliders for this Mac and external monitors, here and in the menu bar.", category: .screen, isOn: $tools.isDisplaysOn),
            Entry(id: "mouse", icon: "computermouse.fill", title: "Mouse",
                  detail: "Pointer speed, acceleration, and wheel direction for external mice only.", category: .screen, isOn: $tools.isMouseOn),
            Entry(id: "monitor", icon: "gauge.with.dots.needle.33percent", title: "System Monitor",
                  detail: "CPU, memory, disk, network, battery, and the busiest apps.", category: .screen, isOn: $tools.isMonitorOn),
            Entry(id: "notch", icon: "rectangle.topthird.inset.filled", title: "Notch",
                  detail: "Point at the top of the screen for music, a focus timer, prayer times, weather, batteries, a file shelf, and recent copies.", category: .notch, isOn: $tools.isNotchOn),
        ]
    }

    var body: some View {
        let layout = AdvancedLayout.shared
        let category = layout.category
        OptionalScroll(enabled: scrolls) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advanced").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("Extra tools for this Mac. Each one stays off until you turn it on.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                categoryBar(category)
                    .padding(.bottom, 4)
                switch category {
                case .overview:
                    overview
                case .general:
                    // A waiting update comes first, since that's what the update badges point at.
                    let updateFirst = Shared.model.hasUpdateWaiting
                    if updateFirst {
                        sectionLabel("UPDATES")
                        updatesCard
                    }
                    sectionLabel("START AND MENU BAR")
                    loginCard
                    MenuBarSettings(layout: Shared.menuBar)
                    if !updateFirst {
                        sectionLabel("UPDATES")
                        updatesCard
                    }
                    sectionLabel("ABOUT")
                    supportCard
                default:
                    Text(category.detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    ForEach(entries.filter { $0.category == category }, id: \.id) { entry in
                        ToolCard(id: entry.id, icon: entry.icon, title: entry.title, detail: entry.detail, isOn: entry.isOn) {
                            content(for: entry.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 28)
        }
    }

    @ViewBuilder private func content(for id: String) -> some View {
        switch id {
        case "clipboard": clipboardContent
        case "launcher": launcherContent
        case "awake": awakeContent
        case "macs": otherMacsContent
        case "layout": layoutContent
        case "previews": previewsContent
        case "displays": DisplaySliders(control: tools.displays, showsOptions: true)
        case "mouse": mouseContent
        case "monitor": monitorContent
        case "notch": notchContent
        default: EmptyView()
        }
    }

    /// The pages of Advanced, each with how many of its tools are on. In a narrow window only the icons show.
    private func categoryBar(_ selected: AdvancedCategory) -> some View {
        ViewThatFits(in: .horizontal) {
            chips(selected, showsLabels: true)
            chips(selected, showsLabels: false)
        }
    }

    private func chips(_ selected: AdvancedCategory, showsLabels: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(AdvancedCategory.allCases) { category in
                let tools = entries.filter { $0.category == category }
                let on = tools.filter { $0.isOn.wrappedValue }.count
                TabPill(icon: category.icon, title: category.label, isSelected: category == selected,
                        showsTitle: showsLabels, count: on > 0 ? on : nil) {
                    AdvancedLayout.shared.category = category
                }
            }
        }
    }

    /// Every tool at a glance, grouped by page. A tile opens its page; the switch turns it on or off here.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(AdvancedCategory.allCases.filter { $0.hasTools }) { category in
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel(category.label.uppercased())
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(entries.filter { $0.category == category }, id: \.id) { entry in
                            ToolTile(icon: entry.icon, title: entry.title, detail: entry.detail, isOn: entry.isOn) {
                                AdvancedLayout.shared.category = category
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5, weight: .bold)).tracking(1.2).foregroundStyle(Theme.textFaint)
            .padding(.top, 8)
    }

    private var loginCard: some View {
        let model = Shared.model
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.mint)
                        .frame(width: 34, height: 34)
                        .background(Theme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Starts DyskLink in the menu bar when you log in, with the tools you turned on.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLogin || model.loginNeedsApproval },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                }
                if model.loginNeedsApproval {
                    HStack {
                        Text("macOS needs your approval in Login Items.").font(.system(size: 12)).foregroundStyle(Theme.amber)
                        Spacer()
                        Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let problem = model.loginProblem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Connected phones whose DyskLink is older than the newest Android release.
    private var phonesBehind: [Peer] {
        Shared.model.peers.filter { $0.isConnected && !$0.isComputer && Shared.updates.isPhoneBehind(Shared.model.phoneAppVersion($0.id)) }
    }

    private func phoneUpdateText(_ peer: Peer) -> String {
        let latest = Shared.updates.latestPhone?.version
        guard let version = Shared.model.phoneAppVersion(peer.id) else {
            return "\(peer.name) has a DyskLink older than 0.2.0. Update it on the phone."
        }
        return "\(peer.name) has DyskLink \(version)" + (latest.map { ", and \($0) is out for the phone." } ?? ".")
    }

    private var updatesCard: some View {
        let updates = Shared.updates
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.mint)
                        .frame(width: 34, height: 34)
                        .background(Theme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Once a day, reads the list of releases on GitHub and tells you when a new version is out. Nothing is downloaded until you choose Install or Download.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Bindable(updates).checksAutomatically)
                        .labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                }
                HStack(spacing: 10) {
                    Text("This is version \(UpdateChecker.currentVersion ?? "unknown").")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    if let release = updates.available {
                        Text("\(release.version) is available.").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                    } else if let status = updates.status {
                        Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if updates.available != nil {
                        if updates.canInstall {
                            Button(updates.isInstalling ? "Installing…" : "Install and restart") { updates.install() }
                                .buttonStyle(PrimaryButtonStyle()).disabled(updates.isInstalling)
                            Button("Download") { updates.download() }.buttonStyle(SecondaryButtonStyle())
                        } else {
                            Button("Download") { updates.download() }.buttonStyle(PrimaryButtonStyle())
                        }
                        Button("Skip") { updates.skip() }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button(updates.isChecking ? "Checking…" : "Check now") { updates.check(manual: true) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(updates.isChecking)
                }
                ForEach(phonesBehind) { peer in
                    Divider().overlay(Theme.stroke)
                    HStack(spacing: 10) {
                        Image(systemName: "iphone.gen3").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.amber)
                            .frame(width: 18)
                        Text(phoneUpdateText(peer)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Get it") { updates.openPhoneRelease() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: System Monitor

    private var monitorContent: some View {
        let sample = tools.monitor.sample
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    StatValue(title: "CPU", value: "\(Int((sample.cpu * 100).rounded()))%")
                    Sparkline(values: tools.monitor.cpuHistory).frame(height: 26)
                }
                VStack(alignment: .leading, spacing: 6) {
                    StatValue(title: "Memory", value: Format.bytes(sample.memoryUsed))
                    Meter(fraction: Self.fraction(sample.memoryUsed, sample.memoryTotal))
                    Text("of \(Format.bytes(sample.memoryTotal))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
                VStack(alignment: .leading, spacing: 6) {
                    StatValue(title: "Disk free", value: Format.bytes(sample.diskFree))
                    Meter(fraction: Self.fraction(sample.diskFree, sample.diskTotal))
                    Text("of \(Format.bytes(sample.diskTotal))")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
            HStack(alignment: .top, spacing: 18) {
                StatValue(title: "Download", value: Format.rate(sample.downloadRate))
                StatValue(title: "Upload", value: Format.rate(sample.uploadRate))
                StatValue(title: "Battery", value: batteryText(sample.power))
            }
            if !tools.monitor.processes.isEmpty {
                VStack(spacing: 6) {
                    HStack {
                        Text("Busiest apps").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CPU").frame(width: 60, alignment: .trailing)
                        Text("Memory").frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
                    ForEach(tools.monitor.processes) { process in
                        HStack {
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(LocalFormat.decimal(process.cpu))%").frame(width: 60, alignment: .trailing)
                            Text(Format.bytes(process.memory)).frame(width: 80, alignment: .trailing)
                        }
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private static func fraction(_ part: Int64, _ total: Int64) -> Double {
        total > 0 ? min(max(Double(part) / Double(total), 0), 1) : 0
    }

    private func batteryText(_ power: PowerStatus) -> String {
        guard let percent = power.percent else { return "None" }
        return "\(percent)%" + (power.isCharging ? ", charging" : power.isOnBattery ? "" : ", plugged in")
    }

    // MARK: Keep Awake

    private var awakeContent: some View {
        let awake = tools.awake
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if awake.isActive {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(awake.isPaused ? "Paused, on battery" : "Staying awake")
                            .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(awake.remainingText).font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Picker("Stay awake for", selection: Bindable(awake).minutes) {
                        ForEach(KeepAwake.durations, id: \.minutes) { Text($0.label).tag($0.minutes) }
                    }
                    .frame(width: 270)
                    if awake.minutes == KeepAwake.customChoice {
                        NumberField(value: Bindable(awake).customHours, unit: "h")
                        NumberField(value: Bindable(awake).customMinutes, unit: "min")
                    }
                }
                Spacer()
                if awake.isActive {
                    Button("Stop") { awake.stop() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Start") { awake.start() }.buttonStyle(PrimaryButtonStyle()).disabled(!awake.canStart)
                }
            }
            if awake.isActive, let idle = awake.idleText {
                Text(idle).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            }
            if let note = awake.note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Picker("End after no activity for", selection: Bindable(awake).idleChoice) {
                    ForEach(KeepAwake.idleChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                }
                .frame(width: 330)
                if awake.idleChoice == KeepAwake.customChoice {
                    NumberField(value: Bindable(awake).customIdleMinutes, unit: "min")
                }
            }
            Text("Any key press, click, or mouse movement restarts this count. Watching a video without touching anything counts as no activity.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Keep the screen on too", isOn: Bindable(awake).keepsDisplayOn)
            Toggle("Only while plugged in", isOn: Bindable(awake).onlyOnPower)
            Picker("End when battery falls below", selection: Bindable(awake).stopBelow) {
                ForEach(KeepAwake.batteryLimits, id: \.self) { limit in
                    Text(limit == 0 ? "Never" : "\(limit)%").tag(limit)
                }
            }
            .frame(width: 330)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.textSecondary)
        .tint(Theme.mint)
    }

    // MARK: Clipboard History

    private var clipboardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShortcutRow(tools: tools, slot: .history, combo: tools.historyShortcut, text: "Show the history, then press Return to paste")
            ShortcutRow(tools: tools, slot: .capture, combo: tools.captureShortcut, text: "Drag over part of the screen to copy its text")
            if tools.historyShortcut != .historyDefault || tools.captureShortcut != .captureDefault {
                Button("Reset shortcuts") { tools.resetShortcuts() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
            }
            Toggle("Control + Option + 1 to 9 pastes the 1st to 9th item", isOn: $tools.isQuickPasteOn)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
            if let problem = tools.shortcutProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
            Toggle("Ignore passwords", isOn: Bindable(tools.clipboard).ignoresPasswords)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
            Text("Skips copies from password apps, and one-word text that mixes letters, numbers, and symbols, like Kucing#2024. A plain password such as kucingmanis can still be saved, and some code or product codes can be skipped by mistake.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if tools.clipboard.passwordLikeCount > 0 {
                HStack {
                    Text("\(tools.clipboard.passwordLikeCount) saved items look like passwords.")
                        .font(.system(size: 12)).foregroundStyle(Theme.amber)
                    Spacer()
                    Button("Remove them") { confirmRemovePasswords() }.buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                }
            }
            HStack(spacing: 6) {
                Text("Keep up to")
                limitPicker(ClipboardHistory.entryChoices, tools.clipboard.maxEntries) { setClipboardLimits(entries: $0) }
                Text("items and")
                limitPicker(ClipboardHistory.imageChoices, tools.clipboard.maxImages) { setClipboardLimits(images: $0) }
                Text("images. Pinned items don't count.")
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            Text("Text and images you copy are saved on this Mac, and text recognition runs on this Mac. Content that apps mark as private is always skipped. Reading text from the screen needs Screen Recording, and pasting needs Accessibility.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("\(tools.clipboard.entries.count) saved").font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Import from Ditto or CopyQ…") { importClipboard() }.buttonStyle(SecondaryButtonStyle())
                Button("Clear history") { confirmClear() }.buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                    .disabled(tools.clipboard.unpinnedCount == 0)
            }
            Text("Choose Ditto.db copied from Windows, a CopyQ export (.cpq) saved without a password, or CopyQ's data folder (~/.config/copyq). Items already saved here are skipped.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func importClipboard() {
        let panel = NSOpenPanel()
        panel.message = "Choose Ditto.db, a CopyQ .cpq file, or CopyQ's data folder"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let copyq = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/copyq")
        if FileManager.default.fileExists(atPath: copyq.path) { panel.directoryURL = copyq }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        do {
            let clips = try ClipboardImport.read(url)
            let result = tools.clipboard.importClips(clips)
            if result.added == 0 {
                alert.messageText = clips.isEmpty ? "Nothing to import" : "Everything here is already saved"
                alert.informativeText = clips.isEmpty ? "No text or images were found in this file." : "\(clips.count) items were found, and all of them are already in Clipboard History."
            } else {
                alert.messageText = "Imported \(result.added) items"
                alert.informativeText = result.trimmed > 0
                    ? "\(result.trimmed) of the oldest items didn't fit the limit and were removed. Choose Unlimited to keep everything, then import again."
                    : "They are in Clipboard History, sorted by date."
            }
        } catch {
            alert.messageText = "Couldn't import"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private func limitPicker(_ choices: [Int], _ value: Int, set: @escaping (Int) -> Void) -> some View {
        Picker("", selection: Binding(get: { value }, set: set)) {
            ForEach(choices, id: \.self) { Text($0 == ClipboardHistory.unlimited ? "Unlimited" : "\($0)").tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    /// Lowering a limit removes the oldest unpinned items, so that is confirmed first.
    private func setClipboardLimits(entries: Int? = nil, images: Int? = nil) {
        let history = tools.clipboard
        let newEntries = entries ?? history.maxEntries
        let newImages = images ?? history.maxImages
        let removed = history.removedCount(maxEntries: newEntries, maxImages: newImages)
        if removed > 0 {
            let alert = NSAlert()
            alert.messageText = "Remove the \(removed) oldest clipboard items?"
            alert.informativeText = "They don't fit the new limit. Pinned items stay. This can't be undone."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        history.setLimits(maxEntries: newEntries, maxImages: newImages)
    }

    private func confirmRemovePasswords() {
        let alert = NSAlert()
        alert.messageText = "Remove \(tools.clipboard.passwordLikeCount) items that look like passwords?"
        alert.informativeText = "This can't be undone, and it also removes pinned items that match."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { tools.clipboard.removePasswordLike() }
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear \(tools.clipboard.unpinnedCount) clipboard items?"
        alert.informativeText = "This can't be undone. Pinned items stay."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { tools.clipboard.clearUnpinned() }
    }

    // MARK: Mouse

    private var mouseContent: some View {
        let mouse = tools.mouse
        let found = !mouse.mouseNames.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: found ? "computermouse.fill" : "computermouse")
                    .foregroundStyle(found ? Theme.mint : Theme.textFaint)
                Text(found ? "Found: " + mouse.mouseNames.joined(separator: ", ") : "No external mouse found. These settings apply once one is plugged in.")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(found ? Theme.textPrimary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Without a mouse the controls are dimmed: they still save, and take effect when one is found.
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Turn off pointer acceleration", isOn: Bindable(mouse).isLinear)
                HStack(spacing: 10) {
                    Text("Pointer speed")
                    Slider(value: Bindable(mouse).speed, in: 0.25...3)
                    Text("\(mouse.speed.formatted(.number.precision(.significantDigits(1...2))))×")
                        .monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                Toggle("Reverse the wheel", isOn: Bindable(mouse).reverses)
                Toggle("Scroll a fixed distance per wheel notch", isOn: Bindable(mouse).usesFixedLines)
                if mouse.usesFixedLines {
                    Stepper("\(mouse.lines) lines per notch", value: Bindable(mouse).lines, in: 1...15)
                }
                Text("Modifier + scroll").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .padding(.top, 4)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(ScrollModifier.allCases) { modifier in
                        GridRow {
                            // The heading already says "+ scroll", so the label column only names the keys.
                            Text(modifier.label.replacingOccurrences(of: " + scroll", with: "")).lineLimit(1).fixedSize()
                            Picker("", selection: Binding(
                                get: { mouse.actions[modifier] ?? .standard },
                                set: { mouse.setAction($0, for: modifier) }
                            )) {
                                ForEach(ScrollAction.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 300, alignment: .leading)
                        }
                    }
                }
            }
            .opacity(found ? 1 : 0.5)
            if mouse.needsAccessibility { accessibilityRow("The wheel options need Accessibility.") }
            Text("Your trackpad isn't changed, and the settings go back when you turn this off.")
                .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.textSecondary)
        .tint(Theme.mint)
    }

    // MARK: Other Macs

    private var otherMacsContent: some View {
        let model = Shared.model
        let paired = model.peers.filter { $0.isComputer && $0.isPaired }
        let waiting = model.nearbyMacs.subtracting(model.peers.map(\.id)).count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Turn this on in DyskLink on each Mac, and on Windows or Linux PCs with DyskLink. They find each other on the same Wi-Fi or Ethernet, then appear in the sidebar. Pair once with the 6-digit code, the same way as a phone.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if paired.isEmpty {
                Text(waiting > 0 ? "Found \(waiting) computer\(waiting == 1 ? "" : "s"). Connecting…" : "No other computers paired yet.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textFaint)
            }
            ForEach(paired) { mac in
                HStack(spacing: 9) {
                    Image(systemName: mac.isMac ? "laptopcomputer" : "pc").foregroundStyle(mac.isConnected ? Theme.mint : Theme.textFaint)
                    Text(mac.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(mac.isConnected ? "Connected" : "Not connected").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
            }
            sharedInputContent(paired.filter(\.isMac))
            Toggle("Merge Clipboard History when the Macs connect", isOn: Bindable(model).sharesClipboardHistory)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            Text("Copies, including pictures, go straight between the computers, encrypted, and never through the internet. A paired computer can share copies and files and ring this Mac. It can only use the mouse and keyboard here while that's allowed below, and never run commands.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One mouse and keyboard for two Macs.
    @ViewBuilder
    private func sharedInputContent(_ macs: [Peer]) -> some View {
        let model = Shared.model
        Divider().overlay(Theme.stroke)
        Text("Mouse and keyboard").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
        if macs.isEmpty {
            Text("Pair another Mac to use this Mac's mouse and keyboard on it.")
                .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
        }
        ForEach(macs) { mac in
            HStack(spacing: 10) {
                Text(mac.name).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.remoteArrangement[mac.id] },
                    set: { model.remoteArrangement[mac.id] = $0 }
                )) {
                    Text("Off").tag(ScreenEdge?.none)
                    ForEach(ScreenEdge.allCases, id: \.self) { edge in Text(edge.label).tag(ScreenEdge?.some(edge)) }
                }
                .labelsHidden().frame(width: 170)
            }
            if model.remoteArrangement[mac.id] != nil, mac.info?.remoteControl != true {
                Text("Turn on \"Let paired Macs use their mouse and keyboard here\" on \(mac.name) too.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
            }
        }
        if !model.remoteArrangement.isEmpty {
            Text(model.sharedInput.isWatching
                 ? "Move the pointer past that edge to use the other Mac, and back to come home. Control-Option-Command brings it home at once. Copy and paste works across, through the shared clipboard."
                 : "Needs Accessibility for DyskLink in System Settings > Privacy & Security, to follow the pointer to the edge.")
                .font(.system(size: 12)).foregroundStyle(model.sharedInput.isWatching ? Theme.textSecondary : Theme.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
        Toggle("Let paired Macs use their mouse and keyboard here", isOn: Bindable(model).acceptsRemoteInput)
            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
        Text(model.acceptsRemoteInput && !DeviceInput.isTrusted
             ? "Needs Accessibility for DyskLink in System Settings > Privacy & Security."
             : "Off by default. While it's on, a paired Mac can move the pointer and type here, as if its mouse and keyboard were plugged in.")
            .font(.system(size: 12)).foregroundStyle(model.acceptsRemoteInput && !DeviceInput.isTrusted ? Theme.amber : Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
        Divider().overlay(Theme.stroke)
    }

    // MARK: Launcher

    private var launcherContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Shortcut", selection: $tools.launcherKey) {
                ForEach(ToolsModel.LauncherKey.allCases) { Text($0.label).tag($0) }
            }
            .frame(width: 260)
            if let problem = tools.launcherProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            Text("Type to find apps, files, and open windows, or a sum such as 12*(3+4), or a unit such as 10 km to mi. Copies show when Clipboard History is on, and saved window layouts when Window Layout is on. Files come from the Spotlight index, so the results match Spotlight. DyskLink doesn't change any macOS settings, so to use Command + Space, turn off Spotlight's shortcut first.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
    }

    // MARK: Window Layout

    private var layoutContent: some View {
        let layout = tools.layout
        return VStack(alignment: .leading, spacing: 10) {
            if !Shared.model.isInputTrusted { accessibilityRow("Moving windows needs Accessibility.") }
            if let problem = layout.shortcutProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
            Text("Press Control + Option with a key to move the front window.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                ForEach(WindowSpot.allCases) { spot in
                    HStack(spacing: 8) {
                        Text(spot.key.name).font(.system(size: 11.5, weight: .semibold).monospaced())
                            .foregroundStyle(Theme.textPrimary)
                            .frame(minWidth: 52).padding(.vertical, 3)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(spot.label).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Text("Control + Option + Command + ← or → moves the window to the other screen. Control + Option + Shift + G puts every window on that screen into a grid.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.stroke)
            Text("Saved layouts").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                DyskField(icon: "rectangle.3.group", placeholder: "Name, such as Work", text: Bindable(layout).draftName) {
                    layout.saveCurrent()
                }
                .frame(width: 240)
                Button("Save the windows as they are") { layout.saveCurrent() }.buttonStyle(SecondaryButtonStyle())
            }
            ForEach(layout.layouts) { saved in
                HStack(spacing: 10) {
                    Text(saved.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("\(saved.windows.count) windows").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    Spacer()
                    Button("Restore") { layout.restore(saved) }.buttonStyle(SecondaryButtonStyle())
                    Button { layout.delete(saved) } label: { Image(systemName: "trash").foregroundStyle(Theme.coral) }
                        .buttonStyle(.plain).help("Delete")
                }
            }
            Text("Restoring puts each app's windows back where they were, matched by app and title. Apps that aren't open are skipped. Saved layouts can also be restored from the menu bar.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Window Previews

    private var previewsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Switch windows with Option + Tab", isOn: Bindable(tools.previews).usesSwitcher)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).tint(Theme.mint)
            HStack(spacing: 16) {
                Picker("Option + Tab shows", selection: Bindable(tools.previews).switcherLayout) {
                    ForEach(WindowPreviews.SwitcherLayout.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 290)
                .disabled(!tools.previews.usesSwitcher)
                Picker("Style", selection: Bindable(tools.previews).style) {
                    ForEach(WindowPreviews.Style.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 190)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            if let problem = tools.previews.shortcutProblem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
            if !Shared.model.isInputTrusted { accessibilityRow("Finding windows needs Accessibility.") }
            if !CGPreflightScreenCaptureAccess() {
                HStack {
                    Text("Pictures of windows need Screen Recording. Without it, you see icons and titles.")
                        .font(.system(size: 12)).foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Allow") { CGRequestScreenCaptureAccess() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            Text("Lists windows on the current Space and minimized windows. Pictures stay in memory while the preview is open.")
                .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Notch

    private var notchContent: some View {
        let notch = tools.notch.model
        let _ = notch.modeRevision
        return VStack(alignment: .leading, spacing: 12) {
            group("pages", "Pages") {
                Picker("Open the notch by", selection: Bindable(notch).opensOnClick) {
                    Text("Pointing at it").tag(false)
                    Text("Clicking it").tag(true)
                }
                .frame(width: 330)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                notchSections
            }
            if notch.isShown(.music) {
                group("music", "Music") { browserMusic }
            }
            if notch.isShown(.pomodoro) {
                group("pomodoro", "Pomodoro", summary: "\(notch.pomodoroSettings.focusMinutes) min focus") { pomodoroSettings }
            }
            if notch.isShown(.todo) {
                group("todo", "Todo list", summary: "\(notch.todos.list.items.filter { !$0.isDone }.count) open") { todoSettings }
            }
            if notch.isShown(.water) {
                group("water", "Water reminder", summary: "\(WaterModel.litres(notch.water.settings.goalMl)) L a day") { waterSettings }
            }
            group("prayer", "Prayer times", summary: notch.prayer.location?.label ?? "Not set") { prayerSettings }
            group("weather", "Weather", summary: notch.weather.place?.shortName ?? "Not set") { weatherSettings }
            group("battery", "Phone battery", summary: notch.phoneBattery.isOn ? "At \(notch.phoneBattery.limit)%" : "Off") {
                phoneBatterySettings
            }
            group("screen", "Screen and bar") {
                Toggle("Hide the bar on screens without a camera", isOn: Bindable(notch).hidesBar)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
                Text("Nothing shows at the top of the screen until you point at its center, or click there if you chose clicking.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Menu bar icon spacing").font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    ForEach(MenuBarSpacing.levels, id: \.label) { level in
                        let chosen = MenuBarSpacingChoice.shared.value == level.value
                        Button(level.label) {
                            MenuBarSpacingChoice.shared.value = level.value
                            notch.modeChanged()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(chosen ? Theme.ink : Theme.textPrimary)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(chosen ? Theme.mint : Theme.panelRaised, in: Capsule())
                    }
                }
                Text("Closer icons fit more beside the camera, so it hides fewer of them, without changing the screen size. Applies to every app's icon after you log out and back in.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("It uses the built-in screen, or a thin bar at the top of the main screen when the lid is closed. The song title comes from Music, Spotify, or YouTube in a browser, and the buttons control whichever player is active. Shelf files aren't copied or moved.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A part of a card that opens and closes, so a long list of settings stays short until it's needed.
    private func group<Content: View>(_ id: String, _ title: String, summary: String? = nil,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        let layout = AdvancedLayout.shared
        let isOpen = layout.isOpen(id)
        return VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.stroke)
            Button { layout.toggle(id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 12)
                        .foregroundStyle(Theme.textSecondary)
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let summary {
                        Text(summary).font(.system(size: 12)).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen { content() }
        }
    }

    private var notchSections: some View {
        let notch = tools.notch.model
        return VStack(alignment: .leading, spacing: 6) {
            Text("Show in the notch").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            // Three even columns of one-line labels, so the rows stay lined up.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3),
                      alignment: .leading, spacing: 8) {
                ForEach(NotchModel.Section.allCases) { section in
                    Toggle(isOn: Binding(
                        get: { notch.isEnabled(section) && notch.hasData(section) },
                        set: { notch.setShown(section, $0) }
                    )) {
                        Text(section.label).lineLimit(1).truncationMode(.tail)
                    }
                    .help(section.label)
                    .disabled(!notch.hasData(section) || (notch.isShown(section) && !notch.canHide(section)))
                }
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            Text("Hidden pages leave the arrows and dots. At least one stays on.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if !notch.hasData(.prayer) || !notch.hasData(.weather) {
                Text("Prayer times and Weather can be turned on once you choose a city in their own sections below.")
                    .font(.system(size: 12)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var browserMusic: some View {
        let notch = tools.notch.model
        if notch.isShown(.music) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show YouTube from your browser", isOn: Bindable(notch).readsBrowsers)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
                Text("Reads the window titles of Firefox, Safari, Chrome, and other browsers while the notch is open, and shows a YouTube video when its tab is the one in front. Whether it plays comes from which app is making sound. Song length and channel aren't shown. Nothing leaves this Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if notch.readsBrowsers, !Shared.model.isInputTrusted {
                    accessibilityRow("Reading browser windows needs Accessibility.")
                }
                Toggle("Show album art, song position, and video details", isOn: Bindable(notch).readsDetails)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
                    .padding(.top, 4)
                Text("Asks Music and Spotify for album art, Music for where the song is, and Safari or Chrome-based browsers for a YouTube video's position, length, channel, and thumbnail. macOS asks once for each app (Automation). Browsers also need Allow JavaScript from Apple Events turned on. Firefox isn't supported yet. Apps are only asked while they're open, and art comes from Spotify's and YouTube's own image servers.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if notch.readsDetails, let problem = notch.detailsProblem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                }
                FirefoxExtensionRow(heard: notch.extensionHeard).padding(.top, 4)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var pomodoroSettings: some View {
        let notch = tools.notch.model
        if notch.isShown(.pomodoro) {
            let settings = Bindable(notch).pomodoroSettings
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Focus for")
                    minutesPicker(PomodoroSettings.focusChoices, settings.focusMinutes)
                    Text("with breaks of")
                    minutesPicker(PomodoroSettings.shortBreakChoices, settings.shortBreakMinutes)
                }
                HStack(spacing: 6) {
                    Text("After")
                    Picker("", selection: settings.sessions) {
                        ForEach(PomodoroSettings.sessionChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    Text("sessions, take a long break of")
                    minutesPicker(PomodoroSettings.longBreakChoices, settings.longBreakMinutes)
                }
                Toggle("Play a sound when a round or break ends", isOn: Bindable(notch).playsPomodoroSound)
                    .tint(Theme.mint)
                Text(notch.pomodoro.isStarted && notch.pomodoro.settings != notch.pomodoroSettings
                     ? "The timer that's running keeps its lengths until you reset it."
                     : "One cycle takes \(NotchView.duration(notch.pomodoroSettings.cycleLength)).")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            .padding(.top, 2)
        }
    }

    private var phoneBatterySettings: some View {
        let watcher = tools.notch.model.phoneBattery
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Warn about the phone's battery", isOn: Bindable(watcher).isOn)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
            if watcher.isOn {
                Picker("Warn when it falls to", selection: Bindable(watcher).limit) {
                    ForEach(PhoneBatteryAlerts.limitChoices, id: \.self) { Text("\($0)%").tag($0) }
                }
                .frame(width: 330)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                Toggle("Also send a notification", isOn: Bindable(watcher).sendsNotification)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
            }
            Text("The notch shows a short warning when a connected phone is low, and when it reaches 100% while charging. Each warning shows once. The phone reports its battery about every 30 seconds.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var waterSettings: some View {
        let water = tools.notch.model.water
        let settings = Bindable(water).settings
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Goal")
                Picker("", selection: settings.goalMl) {
                    ForEach(WaterSettings.goalChoices, id: \.self) { Text("\(WaterModel.litres($0)) L").tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Text("a day, one glass is")
                Picker("", selection: settings.glassMl) {
                    ForEach(WaterSettings.glassChoices, id: \.self) { Text("\($0) ml").tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Toggle("Remind me to drink", isOn: settings.reminds).tint(Theme.mint)
            if water.settings.reminds {
                HStack(spacing: 6) {
                    Text("Every")
                    Picker("", selection: settings.remindEveryMinutes) {
                        ForEach(WaterSettings.intervalChoices, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    Text("from")
                    Picker("", selection: settings.fromHour) {
                        ForEach(WaterSettings.hourChoices.dropLast(), id: \.self) { Text(LocalFormat.clock(hour: $0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                    Text("to")
                    Picker("", selection: settings.toHour) {
                        ForEach(WaterSettings.hourChoices.dropFirst(), id: \.self) { Text(LocalFormat.clock(hour: $0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                if water.settings.fromHour >= water.settings.toHour {
                    Text("The end hour must come after the start hour, or no reminder is sent.")
                        .font(.system(size: 12)).foregroundStyle(Theme.amber)
                }
            }
            Text("Press Drink in the notch each time you drink. A reminder comes when the time you chose has passed since your last drink or reminder, only during those hours, and stops once the goal is reached. Reminders only run while the Notch is on. The last 7 days are kept on this Mac.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
        .padding(.top, 2)
    }

    private var todoSettings: some View {
        let todos = tools.notch.model.todos
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DyskField(icon: "plus", placeholder: "New task", text: Bindable(todos).draft) { todos.addDraft() }
                    .frame(width: 300)
                Button("Add") { todos.addDraft() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(todos.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(todos.visible(Date())) { task in
                TodoRenameRow(todos: todos, task: task)
            }
            if todos.list.items.contains(where: \.isDone) {
                Button("Clear finished tasks") { todos.clearDone() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
            }
            Text("Add, check off, rename, and remove tasks here, in the notch, or from the phone. Up to \(TodoList.maxItems) tasks are kept on this Mac, and tasks finished on an earlier day are removed.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var prayerSettings: some View {
        let prayer = tools.notch.model.prayer
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Province", selection: Bindable(prayer).draftProvince) {
                    Text("Choose").tag(String?.none)
                    ForEach(prayer.provinces, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(width: 270)
                Picker("City", selection: Binding(
                    get: { prayer.location?.province == prayer.draftProvince ? prayer.location?.city : nil },
                    set: { city in
                        if let city, let province = prayer.draftProvince {
                            prayer.location = PrayerLocation(province: province, city: city)
                        }
                    }
                )) {
                    Text("Choose").tag(String?.none)
                    ForEach(prayer.cities, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .frame(width: 250)
                .disabled(prayer.draftProvince == nil)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            .onAppear { prayer.loadProvinces() }
            if prayer.location != nil {
                Toggle("Notify at prayer times", isOn: Bindable(prayer).notifies)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
                if prayer.notifies {
                    Toggle("10 minutes before instead of at the time", isOn: Bindable(prayer).notifiesEarly)
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
                }
            }
            if let problem = prayer.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
            Text("Times come from equran.id, for cities in Indonesia. A month is saved on this Mac, so they keep working offline. Notifications only run while the Notch is on.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var weatherSettings: some View {
        let weather = tools.notch.model.weather
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DyskField(icon: "magnifyingglass", placeholder: "Search a city", text: Bindable(weather).query) {
                    weather.search(weather.query)
                }
                .frame(width: 220)
                Button("Search") { weather.search(weather.query) }.buttonStyle(SecondaryButtonStyle())
                if let place = weather.place {
                    Text(place.label).font(.system(size: 12)).foregroundStyle(Theme.mint).lineLimit(1)
                }
            }
            ForEach(weather.results) { place in
                Button { weather.choose(place) } label: {
                    HStack {
                        Text(place.label).foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).font(.system(size: 12.5))
            }
            if let note = weather.searchNote {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
            Toggle("Show temperatures in Fahrenheit", isOn: Bindable(weather).usesFahrenheit)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
            Text("Weather comes from Open-Meteo. The city you search for and its coordinates are sent to Open-Meteo, with nothing else about you or your Mac. It updates at most every 30 minutes, only while the panel is open.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func minutesPicker(_ choices: [Int], _ value: Binding<Int>) -> some View {
        Picker("", selection: value) {
            ForEach(choices, id: \.self) { Text("\($0) min").tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private func accessibilityRow(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.amber)
            Spacer()
            Button("Allow") { Shared.model.allowInput() }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private var supportCard: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "heart.fill").font(.system(size: 18)).foregroundStyle(Theme.coral)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Support DyskLink").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Donations help keep this project going.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Buy me a coffee") { NSWorkspace.shared.open(Self.donationURL) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

private struct ToolCard<Content: View>: View {
    let id: String
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        let layout = AdvancedLayout.shared
        let isOpen = !layout.isOpen("folded.\(id)")
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ToolIcon(icon: icon, isOn: isOn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if isOn {
                        Button { layout.toggle("folded.\(id)") } label: {
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                                .rotationEffect(.degrees(isOpen ? 0 : -90))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 26, height: 26)
                                .background(Theme.panelRaised, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help(isOpen ? "Hide settings" : "Show settings")
                    }
                    Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                }
                if isOn, isOpen {
                    Divider().overlay(Theme.stroke)
                    content
                }
            }
        }
    }
}

private struct ToolIcon: View {
    let icon: String
    let isOn: Bool

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(isOn ? Theme.mint : Theme.textSecondary)
            .frame(width: 34, height: 34)
            .background((isOn ? Theme.mint : Color.white).opacity(isOn ? 0.12 : 0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A tool in the overview: its name, a line about it, and its switch.
private struct ToolTile: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ToolIcon(icon: icon, isOn: isOn)
                Spacer()
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
            }
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(isOn ? "Settings" : "Details")
                Image(systemName: "arrow.right")
            }
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(isOn ? Theme.mint : Theme.textFaint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Theme.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isOn ? Theme.mint.opacity(0.35) : Theme.stroke))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: open)
    }
}

enum AdvancedCategory: String, CaseIterable, Identifiable {
    case overview, general, productivity, windows, screen, notch
    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .general: "General"
        case .productivity: "Productivity"
        case .windows: "Windows"
        case .screen: "Screen"
        case .notch: "Notch"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .general: "gearshape.fill"
        case .productivity: "bolt.fill"
        case .windows: "macwindow"
        case .screen: "display"
        case .notch: "rectangle.topthird.inset.filled"
        }
    }

    var detail: String {
        switch self {
        case .productivity: "Copy, find, and share faster, and keep this Mac awake."
        case .windows: "Arrange windows and see them before you switch."
        case .screen: "Brightness, sound, the mouse, and how hard this Mac is working."
        case .notch: "The panel that opens from the top of the screen."
        default: ""
        }
    }

    var hasTools: Bool { self != .overview && self != .general }
}

private struct StatValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.textPrimary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Meter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Theme.mint).frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

/// CPU over the last two minutes on a fixed scale of 0 to 100%.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step, y: proxy.size.height * (1 - min(max(value, 0), 1)))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(Theme.mint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .background(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

/// Click the key, then press the new shortcut. Escape cancels.
private struct ShortcutRow: View {
    let tools: ToolsModel
    let slot: ToolsModel.ShortcutSlot
    let combo: KeyCombo
    let text: String

    var body: some View {
        let isRecording = tools.recordingSlot == slot
        HStack(spacing: 10) {
            Button {
                if isRecording { tools.cancelRecording() } else { tools.startRecording(slot) }
            } label: {
                Text(isRecording ? "Press keys…" : combo.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(isRecording ? Theme.mint : Theme.textPrimary)
                    .frame(minWidth: 72)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isRecording ? Theme.mint : Theme.stroke))
            }
            .buttonStyle(.plain)
            .help("Change this shortcut")
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct NumberField: View {
    @Binding var value: Int
    let unit: String

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 50)
                .multilineTextAlignment(.trailing)
            Text(unit)
        }
    }
}

/// Used on the Advanced page and in the menu bar.
struct DisplaySliders: View {
    let control: DisplayControl
    var showsOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsOptions { options }
            if control.linksScreens && control.displays.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("All screens").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    sliderRow("sun.max.fill", value: control.allScreensBrightness) { control.setAllScreens($0) }
                }
            }
            ForEach(control.displays) { display in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(display.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if display.method == .monitor {
                            Text("DDC").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        Spacer(minLength: 0)
                        if showsOptions, display.canUseDDC {
                            Button(display.method == .monitor ? "Use dimming instead" : "Use DDC") {
                                control.setUsesDDC(display.method != .monitor, for: display.id)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.mint)
                        }
                    }
                    sliderRow("sun.max.fill", value: display.brightness) { control.setBrightness($0, for: display.id) }
                    if let volume = display.volume {
                        sliderRow("speaker.wave.2.fill", value: volume) { control.setMonitorVolume($0, for: display.id) }
                    }
                    if display.method == .dimming {
                        Text(display.canUseDDC ? "Dimming the picture instead of changing the monitor's backlight." : "This monitor can't be reached over DDC, so DyskLink dims the picture instead.")
                            .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let problem = control.matchProblem {
                Text(problem).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if control.isReading && control.displays.isEmpty {
                Text("Checking screens…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Sound: " + control.outputName).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let level = control.outputVolume {
                    sliderRow("speaker.wave.2.fill", value: level) { control.setOutputVolume($0) }
                } else {
                    Text("This output has no volume control on the Mac.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .onAppear { control.refreshOutput() }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Change all screens together", isOn: Bindable(control).linksScreens)
            Toggle("Use the brightness keys for these screens", isOn: Bindable(control).usesKeys)
            Toggle("Allow darker than the normal minimum", isOn: Bindable(control).goesDarker)
            Text("Below 25% on the slider, the backlight stays at its lowest and the picture gets darker too.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            if control.needsAccessibility {
                HStack {
                    Text("The brightness keys need Accessibility.").font(.system(size: 12)).foregroundStyle(Theme.amber)
                    Spacer()
                    Button("Allow") { Shared.model.allowInput() }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).tint(Theme.mint)
    }

    private func sliderRow(_ icon: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 16)
            Slider(value: Binding(get: { value }, set: set), in: 0...1).tint(Theme.mint)
            Text("\(Int((value * 100).rounded()))%").font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textSecondary).frame(width: 36, alignment: .trailing)
        }
    }
}

@Observable
final class AdvancedLayout {
    static let shared = AdvancedLayout()
    private(set) var open: Set<String>
    /// Snapshots change what is open without saving it.
    var persists = true

    /// The page of Advanced on show.
    var category: AdvancedCategory {
        didSet { if persists { UserDefaults.standard.set(category.rawValue, forKey: "advanced.category") } }
    }

    private init() {
        open = Set(UserDefaults.standard.stringArray(forKey: "advanced.open") ?? ["pages"])
        category = UserDefaults.standard.string(forKey: "advanced.category").flatMap(AdvancedCategory.init) ?? .overview
    }

    func isOpen(_ id: String) -> Bool { open.contains(id) }

    func toggle(_ id: String) {
        if open.contains(id) { open.remove(id) } else { open.insert(id) }
        if persists { UserDefaults.standard.set(open.sorted(), forKey: "advanced.open") }
    }

    func setOpen(_ ids: Set<String>) { open = ids }
}

/// One task in Advanced, with its title editable in place. Return or Save keeps the new title.
private struct TodoRenameRow: View {
    let todos: TodoModel
    let task: TodoItem

    var body: some View {
        let draft = todos.renameDrafts[task.id]
        HStack(spacing: 8) {
            Button { todos.toggle(task.id) } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? Theme.mint : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            DyskField(placeholder: "Task", text: Binding(
                get: { todos.renameDrafts[task.id] ?? task.title },
                set: { todos.renameDrafts[task.id] = $0 }
            ), clearable: false) { todos.saveRename(task.id) }
            .frame(width: 268)
            if let draft, draft != task.title {
                Button("Save") { todos.saveRename(task.id) }.buttonStyle(SecondaryButtonStyle())
            }
            Button { todos.delete(task.id) } label: {
                Image(systemName: "trash").foregroundStyle(Theme.coral)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
    }
}


/// Installs the Firefox extension's helper and shows whether the extension has spoken lately.
private struct FirefoxExtensionRow: View {
    let heard: Date?
    @Bindable private var state = FirefoxExtensionState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Firefox and Zen").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if state.installed {
                    Button("Remove") { state.remove() }.buttonStyle(.borderless).font(.system(size: 12))
                }
                Button(state.installed ? "Reinstall extension" : "Install Firefox extension") { state.install() }
                    .font(.system(size: 12))
            }
            Text("Firefox can't be asked with AppleScript, so a small DyskLink extension tells the notch what YouTube plays: title, channel, progress, and thumbnail. It talks only to DyskLink on this Mac. After installing, open about:debugging in Firefox, choose This Firefox › Load Temporary Add-on, and pick manifest.json in the folder that opens.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let heard, Date().timeIntervalSince(heard) < NotchModel.extensionTimeout {
                Text("Extension connected.").font(.system(size: 12)).foregroundStyle(Theme.mint)
            } else if state.installed {
                Text("Helper installed. Waiting for the extension: open a YouTube video in Firefox.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            if let error = state.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
        }
    }
}

@MainActor
@Observable
final class FirefoxExtensionState {
    static let shared = FirefoxExtensionState()
    private(set) var installed = BrowserExtension.isInstalled
    private(set) var error: String?

    func install() {
        do {
            try BrowserExtension.install()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        installed = BrowserExtension.isInstalled
    }

    func remove() {
        BrowserExtension.remove()
        installed = BrowserExtension.isInstalled
    }
}
