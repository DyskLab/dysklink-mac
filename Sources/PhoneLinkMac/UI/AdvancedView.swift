import AppKit
import ServiceManagement
import SwiftUI

/// The optional tools. Each card only shows its controls while its switch is on.
struct AdvancedView: View {
    @Bindable var tools: ToolsModel
    var scrolls = true

    private static let donationURL = URL(string: "https://buymeacoffee.com/fannydevz")!

    var body: some View {
        OptionalScroll(enabled: scrolls) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advanced").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("Extra tools for this Mac. Each one stays off until you turn it on.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 4)
                loginCard
                ToolCard(icon: "gauge.with.dots.needle.33percent", title: "System Monitor",
                         detail: "CPU, memory, disk, network, battery, and the busiest apps.",
                         isOn: $tools.isMonitorOn) { monitorContent }
                ToolCard(icon: "cup.and.saucer.fill", title: "Keep Awake",
                         detail: "Stops this Mac or its screen from sleeping for as long as you choose.",
                         isOn: $tools.isAwakeOn) { awakeContent }
                ToolCard(icon: "doc.on.clipboard.fill", title: "Clipboard History",
                         detail: "Search everything you copied, and copy text from anywhere on screen.",
                         isOn: $tools.isClipboardOn) { clipboardContent }
                ToolCard(icon: "sun.max.fill", title: "Brightness and Volume",
                         detail: "Sliders for this Mac and external monitors, here and in the menu bar.",
                         isOn: $tools.isDisplaysOn) { DisplaySliders(control: tools.displays, showsOptions: true) }
                ToolCard(icon: "computermouse.fill", title: "Mouse",
                         detail: "Pointer speed, acceleration, and wheel direction for external mice only.",
                         isOn: $tools.isMouseOn) { mouseContent }
                ToolCard(icon: "macwindow.on.rectangle", title: "Window Previews",
                         detail: "See an app's windows when you point at its Dock icon, and switch windows with Option + Tab.",
                         isOn: $tools.isPreviewsOn) { previewsContent }
                ToolCard(icon: "rectangle.topthird.inset.filled", title: "Notch",
                         detail: "Point at the top of the screen for music, a focus timer, batteries, a file shelf, and recent copies.",
                         isOn: $tools.isNotchOn) { notchContent }
                supportCard
            }
            .padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 28)
        }
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
                            Text(String(format: "%.1f%%", process.cpu)).frame(width: 60, alignment: .trailing)
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
            Text("Text and images you copy are saved on this Mac, up to \(ClipboardHistory.maxEntries) items, and text recognition runs on this Mac. Content that apps mark as private is always skipped. Reading text from the screen needs Screen Recording, and pasting needs Accessibility.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("\(tools.clipboard.entries.count) saved").font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Clear history") { confirmClear() }.buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                    .disabled(tools.clipboard.unpinnedCount == 0)
            }
        }
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
        return VStack(alignment: .leading, spacing: 10) {
            Text(mouse.mouseNames.isEmpty ? "No external mouse found" : "Found: " + mouse.mouseNames.joined(separator: ", "))
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Toggle("Turn off pointer acceleration", isOn: Bindable(mouse).isLinear)
            HStack(spacing: 10) {
                Text("Pointer speed")
                Slider(value: Bindable(mouse).speed, in: 0.25...3)
                Text(String(format: "%.2g×", mouse.speed)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            Toggle("Reverse the wheel", isOn: Bindable(mouse).reverses)
            Toggle("Scroll a fixed distance per wheel notch", isOn: Bindable(mouse).usesFixedLines)
            if mouse.usesFixedLines {
                Stepper("\(mouse.lines) lines per notch", value: Bindable(mouse).lines, in: 1...15)
            }
            Text("Modifier + scroll").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .padding(.top, 4)
            ForEach(ScrollModifier.allCases) { modifier in
                Picker(modifier.label, selection: Binding(
                    get: { mouse.actions[modifier] ?? .standard },
                    set: { mouse.setAction($0, for: modifier) }
                )) {
                    ForEach(ScrollAction.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 420)
            }
            if mouse.needsAccessibility { accessibilityRow("The wheel options need Accessibility.") }
            Text("Your trackpad isn't changed, and the settings go back when you turn this off.")
                .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.textSecondary)
        .tint(Theme.mint)
    }

    // MARK: Window Previews

    private var previewsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Switch windows with Option + Tab", isOn: Bindable(tools.previews).usesSwitcher)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).tint(Theme.mint)
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
        VStack(alignment: .leading, spacing: 10) {
            Picker("Open the notch by", selection: Bindable(tools.notch.model).opensOnClick) {
                Text("Pointing at it").tag(false)
                Text("Clicking it").tag(true)
            }
            .frame(width: 330)
            .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            let _ = tools.notch.model.modeRevision
            Toggle("Hide the bar on screens without a camera", isOn: Bindable(tools.notch.model).hidesBar)
                .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
            Text("Nothing shows at the top of the screen until you point at its center, or click there if you chose clicking.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Fit more icons beside the camera", isOn: Binding(
                get: { MenuBarSpacing.isTight },
                set: { MenuBarSpacing.isTight = $0; tools.notch.model.modeChanged() }
            ))
            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).tint(Theme.mint)
            Text("Brings menu bar icons closer together so the camera hides fewer of them, without changing the screen size. It applies after you log out and back in, and turning it off puts the normal spacing back the same way.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It uses the built-in screen, or a thin bar at the top of the main screen when the lid is closed. The song title comes from Music and Spotify, and the buttons control whichever player is active. Shelf files aren't copied or moved.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.mint)
                        .frame(width: 34, height: 34)
                        .background(Theme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                }
                if isOn { content }
            }
        }
    }
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
