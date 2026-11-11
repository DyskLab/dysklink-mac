import AppKit
import SwiftUI

/// Feature cards on the page of a paired device.
struct FeatureCards: View {
    enum Part { case transfers, settings, all }

    @Bindable var model: AppModel
    let peer: Peer
    var part: Part = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if part != .settings, peer.isConnected {
                fileCard
                mediaCard
            }
            if part != .transfers {
                if !model.isInputTrusted { accessibilityCard }
                clipboardCard
                codesCard
                if !peer.isMac { autoLockCard }
                commandsCard
                terminalCard
                screenShareCard
                audioCard
                usbCard
            }
        }
    }

    private var fileCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Send files").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Choose files, or drag them onto this window. Files from the phone go to Downloads/DyskLink.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Choose files") { model.pickFiles(for: peer.id) }.buttonStyle(PrimaryButtonStyle())
                }
                ForEach(model.transfers.filter { $0.peerId == peer.id }) { transfer in
                    TransferRow(transfer: transfer)
                }
            }
        }
    }

    private var mediaCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Media controls on the phone").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8) {
                    ForEach(Self.mediaButtons, id: \.action) { item in
                        Button { model.sendMedia(item.action, to: peer.id) } label: {
                            Image(systemName: item.icon).frame(width: 22, height: 16)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .help(item.label)
                    }
                }
            }
        }
    }

    private static let mediaButtons: [(action: String, icon: String, label: String)] = [
        ("previous", "backward.fill", "Previous"),
        ("play_pause", "playpause.fill", "Play or pause"),
        ("next", "forward.fill", "Next"),
    ]

    private var accessibilityCard: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "hand.raised.fill").font(.system(size: 20)).foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Accessibility permission needed").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("The touchpad, keyboard, and remotes on the phone won't work without this permission. If DyskLink already looks enabled in Settings, press Allow to redo it, then turn it on again.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Allow") { model.allowInput() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var clipboardCard: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic clipboard").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Text copied on the Mac goes straight to the phone. Content that password managers mark as secret is skipped.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $model.clipboardEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
            }
        }
    }

    private var autoLockCard: some View {
        let isOn = Binding(get: { model.autoLockPhone == peer.id },
                           set: { model.autoLockPhone = $0 ? peer.id : nil })
        let other = model.autoLockPhone.flatMap { id in id == peer.id ? nil : model.peers.first { $0.id == id }?.name }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lock when \(peer.name) goes away").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(other.map { "Now set for \($0). Turning this on moves it to \(peer.name)." }
                             ?? "This Mac locks when the phone stays disconnected, for example when you walk away with it or turn off its Wi-Fi.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                }
                if isOn.wrappedValue {
                    HStack(spacing: 8) {
                        Text("Lock after").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        Picker("", selection: $model.autoLockDelay) {
                            ForEach(AutoLock.delays, id: \.self) { Text(AutoLock.label($0)).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                    }
                }
            }
        }
    }

    private var codesCard: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codes in the notch").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("One-time codes from SMS and notifications on the phone show under the notch with a Copy button. The code isn't kept in the clipboard history.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $model.codesEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
            }
        }
    }

    private var commandsCard: some View {
        let name = model.newCommandName.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = model.newCommandScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = model.commands.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let hint: String? = name.isEmpty && script.isEmpty ? nil
            : name.isEmpty ? "Give it a name, which is what the phone shows."
            : script.isEmpty ? "Write the command to run."
            : duplicate ? "A command with this name is already on the list."
            : nil
        let unused = Self.examples.filter { example in !model.commands.contains { $0.script == example.script } }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Commands").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Buttons the phone can press to run something on this Mac. Only commands on this list can run, with your Mac account's privileges.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.commands.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(model.commands) { command in
                            HStack(spacing: 10) {
                                Image(systemName: "terminal").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                                    .frame(width: 28, height: 28)
                                    .background(Theme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                    Text(command.script).font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Theme.textFaint).lineLimit(1).truncationMode(.middle)
                                        .help(command.script)
                                }
                                Spacer(minLength: 8)
                                IconButton(icon: "trash", help: "Remove \(command.name)", tint: Theme.coral) { model.removeCommand(command.id) }
                            }
                            .padding(8)
                            .background(Theme.panelRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                Text("ADD A COMMAND").font(.system(size: 10.5, weight: .bold)).tracking(1.2).foregroundStyle(Theme.textFaint)
                    .padding(.top, 2)
                if !unused.isEmpty {
                    // Tapping fills the fields, so the command can be read and changed before adding it.
                    FlowChips(items: unused.map(\.name)) { picked in
                        guard let example = unused.first(where: { $0.name == picked }) else { return }
                        model.newCommandName = example.name
                        model.newCommandScript = example.script
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    DyskField(icon: "textformat", placeholder: "Name on the phone", text: $model.newCommandName) { addIfReady(hint) }
                        .frame(width: 170)
                    DyskField(icon: "chevron.right", placeholder: "Command, such as pmset displaysleepnow",
                              text: $model.newCommandScript, monospaced: true) { addIfReady(hint) }
                    Button("Add") { addIfReady(hint) }
                        .buttonStyle(SecondaryButtonStyle(tint: hint == nil && !name.isEmpty ? Theme.mint : Theme.textFaint))
                        .disabled(hint != nil || name.isEmpty || script.isEmpty)
                }
                if let hint {
                    Text(hint).font(.system(size: 11.5)).foregroundStyle(Theme.amber)
                }
            }
        }
    }

    private var usbCard: some View {
        let usb = model.usb
        let viaUsb = model.isUsb(peer.id)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cable.connector").font(.system(size: 18)).foregroundStyle(viaUsb ? Theme.mint : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background((viaUsb ? Theme.mint : Theme.textSecondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("USB connection").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(usbStatus(usb, viaUsb: viaUsb))
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(get: { usb.enabled }, set: { usb.enabled = $0 })).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                }
                if viaUsb {
                    StatusPill(text: "Connected over USB", color: Theme.mint)
                } else if usb.enabled && usb.adbPath == nil {
                    HStack(spacing: 10) {
                        Button(usb.downloading ? "Downloading…" : "Download Android tools") { usb.downloadAdb() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(usb.downloading)
                        Text("About 15 MB from Google, saved in DyskLink's folder.").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                    }
                    if let error = usb.downloadError {
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral)
                    }
                }
            }
        }
    }

    private func usbStatus(_ usb: UsbBridge, viaUsb: Bool) -> String {
        if !usb.enabled { return "Off. Phones connect over Wi-Fi only." }
        if viaUsb { return "Everything goes through the cable now: smoother screen and camera, faster files. Unplug to go back to Wi-Fi." }
        if usb.adbPath == nil { return "Needs Android's adb tool on this Mac. Download it once below, or install it with Homebrew (android-platform-tools)." }
        if !usb.waitingDevices.isEmpty { return "A phone is plugged in. Tap Allow on the phone's USB debugging prompt." }
        if !usb.readyDevices.isEmpty { return "Phone found on USB. Open DyskLink on the phone; it switches to the cable within a few seconds." }
        return "Plug the phone in with a cable and turn on USB debugging (Settings › Developer options) for a smoother, faster connection."
    }

    private var audioCard: some View {
        let listening = model.audioListeners.contains(peer.id)
        let playing = model.phoneAudioFrom == peer.id
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "hifispeaker.2.fill").font(.system(size: 17)).foregroundStyle(model.audioShareEnabled ? Theme.mint : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background((model.audioShareEnabled ? Theme.mint : Theme.textSecondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Let phones hear this Mac").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Paired phones can play this Mac's sound, for music in another room or on earphones. Needs Screen Recording. The notch shows while a phone listens. Sound from the phone to this Mac is started on the phone and needs no setting here.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(get: { model.audioShareEnabled }, set: { model.audioShareEnabled = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(Theme.mint)
                }
                if listening {
                    HStack {
                        StatusPill(text: "\(peer.name) is listening", color: Theme.mint)
                        Spacer()
                        Button("Stop") { model.stopListening(peer.id, error: "Stopped on the Mac") }
                            .buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                    }
                }
                if playing {
                    HStack {
                        StatusPill(text: "Playing sound from \(peer.name)", color: Theme.violet)
                        Spacer()
                        Button("Stop") { model.stopPhoneAudio() }
                            .buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                    }
                }
            }
        }
    }

    private var screenShareCard: some View {
        let viewing = model.macScreens[peer.id] != nil
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "display").font(.system(size: 18)).foregroundStyle(model.screenShareEnabled ? Theme.violet : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background((model.screenShareEnabled ? Theme.violet : Theme.textSecondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("View this screen from the phone").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Paired phones can see this Mac's screen and tap, type, and scroll on it. Needs Screen Recording, and Accessibility for control. This Mac shows a notification while it's viewed.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $model.screenShareEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.violet)
                }
                if viewing {
                    HStack {
                        StatusPill(text: "\(peer.name) is viewing", color: Theme.violet)
                        Spacer()
                        Button("Stop") { model.endMacScreen(peer.id, error: "Stopped on the Mac") }
                            .buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                    }
                }
            }
        }
    }

    private var terminalCard: some View {
        let open = model.terminalCount(of: peer.id)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "terminal.fill").font(.system(size: 18)).foregroundStyle(model.terminalEnabled ? Theme.amber : Theme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background((model.terminalEnabled ? Theme.amber : Theme.textSecondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Terminal from the phone").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Paired phones can open a shell on this Mac that runs as you and can do anything you can. The phone asks for its fingerprint or screen lock each time, and this Mac shows a notification when one opens.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $model.terminalEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.amber)
                }
                if open > 0 {
                    HStack {
                        StatusPill(text: open == 1 ? "1 terminal open" : "\(open) terminals open", color: Theme.amber)
                        Spacer()
                        Button("End") { model.endTerminals(of: peer.id) }
                            .buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                    }
                }
            }
        }
    }

    private func addIfReady(_ hint: String?) {
        guard hint == nil else { return }
        model.addCommand()
    }

    /// Safe, common commands to start from. None of them deletes anything.
    static let examples: [(name: String, script: String)] = [
        ("Sleep display", "pmset displaysleepnow"),
        ("Sleep Mac", "pmset sleepnow"),
        ("Mute Mac", "osascript -e 'set volume output muted true'"),
        ("Unmute Mac", "osascript -e 'set volume output muted false'"),
        ("Volume 50%", "osascript -e 'set volume output volume 50'"),
        ("Open Downloads", "open ~/Downloads"),
        ("Screenshot to Desktop", "screencapture -x ~/Desktop/Screenshot-$(date +%Y%m%d-%H%M%S).png"),
        ("Open Safari", "open -a Safari"),
        ("Say hello", "say 'Hello from the phone'"),
    ]
}

/// Chips that wrap onto new lines.
struct FlowChips: View {
    let items: [String]
    let onPick: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { onPick(item) } label: {
                    Text(item).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.panelRaised, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.stroke))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children left to right and wraps to a new line when the row is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: transfer.outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(Theme.mint)
                Text(transfer.name).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let location = transfer.location {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([location]) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                }
                Text(statusText).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(statusColor)
            }
            if transfer.status == .active {
                StorageBar(free: transfer.size - transfer.transferred, total: transfer.size)
            }
            if transfer.status == .failed, let detail = transfer.detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(10)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusText: String {
        switch transfer.status {
        case .active: return Format.bytes(transfer.transferred) + " / " + Format.bytes(transfer.size)
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    private var statusColor: Color {
        switch transfer.status {
        case .active: return Theme.textSecondary
        case .done: return Theme.mint
        case .failed: return Theme.coral
        }
    }
}
