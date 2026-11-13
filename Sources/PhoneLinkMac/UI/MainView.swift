import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel
    var animated = true

    private var selected: Peer? { model.peers.first { $0.id == model.selectedPeerId } }

    var body: some View {
        ZStack {
            AuroraBackground()
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Theme.stroke).frame(width: 1)
                // The top band holds the window buttons, so pages scroll below it instead of under them.
                VStack(spacing: 0) {
                    Color.clear.frame(height: 28)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
            }
            if let prompt = model.pairingPrompt {
                PairingOverlay(prompt: prompt, model: model)
            }
        }
        .toggleStyle(.dyskSwitch)
        .dyskAppearance()
        .frame(minWidth: 860, minHeight: 600)
        .dropDestination(for: URL.self) { urls, _ in model.sendDroppedFiles(urls) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 11) {
                LogoMark()
                VStack(alignment: .leading, spacing: 1) {
                    Text("DyskLink").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text(model.localName).font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            serverStatus
            Text("DEVICES")
                .font(.system(size: 10.5, weight: .bold)).tracking(1.2).foregroundStyle(Theme.textFaint)
            OptionalScroll(enabled: animated) {
                VStack(spacing: 8) {
                    ForEach(model.peers) { peer in
                        PeerRow(peer: peer, isSelected: peer.id == model.selectedPeerId,
                                alerts: peer.isConnected ? model.phone(peer.id).notifications.count : 0)
                            .onTapGesture {
                                model.selectedPeerId = peer.id
                                model.showsTools = false
                                model.showsHistory = false
                                model.showsCare = false
                            }
                    }
                    if model.peers.isEmpty {
                        Text("No devices yet")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
                    }
                }
            }
            Spacer(minLength: 0)
            historyButton
            careButton
            advancedButton
        }
        .padding(.horizontal, 18).padding(.top, 38).padding(.bottom, 18)
        .frame(width: 272)
        .background(Theme.sidebar)
    }

    private var historyButton: some View {
        sidebarButton("clock.arrow.circlepath", "File history", isOn: model.showsHistory) {
            model.showsTools = false
            model.showsCare = false
            model.showsHistory = true
        }
    }

    private var careButton: some View {
        sidebarButton("sparkles", "Mac care", isOn: model.showsCare) {
            model.showsTools = false
            model.showsHistory = false
            model.showsCare = true
        }
    }

    private func sidebarButton(_ icon: String, _ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? Theme.mint : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Theme.contrast.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(isOn ? Theme.panelRaised : Color.clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(isOn ? Theme.mint.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private var hasUpdate: Bool { model.hasUpdateWaiting }

    private var advancedButton: some View {
        HStack(spacing: 11) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.showsTools ? Theme.mint : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Theme.contrast.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Advanced").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            if hasUpdate {
                Text("Update").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.mint, in: Capsule())
            }
        }
        .padding(9)
        .background(model.showsTools ? Theme.panelRaised : Color.clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(model.showsTools ? Theme.mint.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.showsHistory = false
            model.showsCare = false
            model.showsTools = true
            // A waiting update opens the page that has it.
            if hasUpdate { AdvancedLayout.shared.category = .general }
            if Shared.tools.isMonitorOn { Shared.tools.monitor.refresh() }
        }
    }

    @ViewBuilder
    private var serverStatus: some View {
        switch model.serverState {
        case .starting: StatusPill(text: "Getting ready…", color: Theme.amber)
        case .listening: StatusPill(text: "Ready to connect", color: Theme.mint)
        case .failed: StatusPill(text: "Server failed", color: Theme.coral)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.showsTools {
            AdvancedView(tools: Shared.tools)
        } else if model.showsCare {
            MacCareView(care: Shared.care, scrolls: animated)
        } else if model.showsHistory {
            FileHistoryView(model: model, scrolls: animated)
        } else if case .failed(let message) = model.serverState {
            ErrorState(message: message)
        } else if let peer = selected {
            if peer.isPaired, peer.isComputer {
                MacPeerDetail(model: model, peer: peer, scrolls: animated, onUnpair: { model.unpair(peer.id) })
            } else if peer.isPaired {
                PeerDetail(model: model, peer: peer, scrolls: animated, onUnpair: { model.unpair(peer.id) })
            } else {
                NewPeerState(peer: peer, onPair: { model.requestPairing(with: peer.id) })
            }
        } else {
            EmptyState(model: model, addresses: model.addresses, animated: animated)
        }
    }
}

extension AppModel {
    /// A new DyskLink for this Mac, or a connected phone that's behind. Both are shown in Advanced > General.
    var hasUpdateWaiting: Bool {
        Shared.updates.available != nil || peers.contains {
            $0.isConnected && !$0.isComputer && Shared.updates.isPhoneBehind(phoneAppVersion($0.id))
        }
    }

    /// Opens the main window at Advanced › General, where the updates card is.
    func showUpdates() {
        showsHistory = false
        showsCare = false
        showsTools = true
        AdvancedLayout.shared.category = .general
        MainWindow.show()
    }
}

/// ImageRenderer doesn't draw ScrollView content, so snapshots use a plain view.
struct OptionalScroll<Content: View>: View {
    let enabled: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if enabled { ScrollView { content } } else { content.frame(maxHeight: .infinity, alignment: .top) }
    }
}

private struct PeerRow: View {
    let peer: Peer
    let isSelected: Bool
    var alerts = 0

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: peer.isMac ? "laptopcomputer" : peer.isComputer ? "pc" : "iphone.gen3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(peer.isConnected ? Theme.mint : Theme.textFaint)
                .frame(width: 34, height: 34)
                .background(Theme.contrast.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                // The battery sits in the subtitle so a long name keeps its room next to the badge.
                HStack(spacing: 0) {
                    Text(subtitle).foregroundStyle(Theme.textSecondary)
                    if let percent = peer.info?.batteryPercent, peer.isConnected, peer.isPaired {
                        Text(" · ").foregroundStyle(Theme.textFaint)
                        Text("\(percent)%").fontWeight(.bold).foregroundStyle(Theme.text(Theme.batteryColor(percent)))
                    }
                }
                .font(.system(size: 11)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if alerts > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bell.fill").font(.system(size: 8.5, weight: .bold))
                    Text("\(alerts)").font(.system(size: 10.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.mint, in: Capsule())
                .fixedSize()
                .help("\(alerts) notifications on \(peer.name)")
            }
        }
        .padding(9)
        .background(isSelected ? Theme.panelRaised : Color.clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(isSelected ? Theme.mint.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if !peer.isPaired { return "Not paired" }
        return peer.isConnected ? "Connected" : "Not connected"
    }
}

private struct PeerDetail: View {
    let model: AppModel
    let peer: Peer
    let scrolls: Bool
    let onUnpair: () -> Void

    var body: some View {
        OptionalScroll(enabled: scrolls) {
            VStack(alignment: .leading, spacing: 14) {
                hero
                PeerTabBar(model: model, peer: peer)
                switch model.peerTab {
                case .overview: overview
                case .notifications: NotificationsTab(model: model, peer: peer)
                case .messages: MessagesTab(model: model, peer: peer, scrolls: scrolls)
                case .contacts: ContactsTab(model: model, peer: peer)
                case .files: FilesTab(model: model, peer: peer)
                case .gallery: GalleryTab(model: model, peer: peer)
                case .screen: ScreenTab(model: model, peer: peer)
                }
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var overview: some View {
        SectionLabel("At a glance")
        // Always the full width: one row of four, or two rows of two when the window is narrow.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 10) { statTiles(minWidth: 130) }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                let tiles = statTileList
                GridRow { tiles[0]; tiles[1] }
                GridRow { tiles[2]; tiles[3] }
            }
        }
        if model.phone(peer.id).features.contains("screentime") {
            SectionLabel("Screen time")
            ScreenTimeCard(model: model, peer: peer)
        }
        if peer.isConnected {
            SectionLabel("Send and control")
            FeatureCards(model: model, peer: peer, part: .transfers)
        }
        SectionLabel("On this Mac")
        FeatureCards(model: model, peer: peer, part: .settings)
        if model.phone(peer.id).features.contains("calls") { callMusicCard }
        Button(action: onUnpair) {
            Label("Unpair this phone", systemImage: "link.badge.plus").labelStyle(.titleOnly)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.coralText)
        }
        .buttonStyle(.plain)
        .padding(.top, 6).padding(.leading, 2)
    }

    private var statTileList: [StatTile] {
        [
            StatTile(icon: "wifi", title: "Network", value: networkText),
            StatTile(icon: "antenna.radiowaves.left.and.right", title: "Cellular", value: cellularText),
            StatTile(icon: "internaldrive", title: "Storage", value: storageText, bar: storageBar),
            StatTile(icon: "phone.fill", title: "Last call", value: lastCallText),
        ]
    }

    @ViewBuilder
    private func statTiles(minWidth: CGFloat) -> some View {
        ForEach(Array(statTileList.enumerated()), id: \.offset) { _, tile in
            tile.frame(minWidth: minWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hero: some View {
        let full = model.peerTab == .overview
        let data = model.phone(peer.id)
        let ringing = model.ringingPhones.contains(peer.id)
        return Card(padding: full ? 22 : 16) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: full ? 22 : 16) {
                    BatteryRing(percent: peer.info?.batteryPercent, charging: peer.info?.isCharging ?? false, size: full ? 112 : 76)
                    VStack(alignment: .leading, spacing: 6) {
                        StatusPill(
                            text: peer.isConnected ? "Connected" : "Not connected",
                            color: peer.isConnected ? Theme.mint : Theme.textFaint
                        )
                        Text(peer.name).font(.system(size: full ? 26 : 20, weight: .bold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text([peer.info?.model ?? peer.model, peer.info?.osVersion].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        if !peer.isConnected, let lastSeen = peer.lastSeen {
                            Text("Last seen \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if full, peer.isConnected {
                    HStack(spacing: 10) {
                        QuickTile(icon: "arrow.up.doc.fill", title: "Send files") { model.pickFiles(for: peer.id) }
                        QuickTile(icon: ringing ? "speaker.slash.fill" : "speaker.wave.3.fill",
                                  title: ringing ? "Stop ringing" : "Find phone", tint: ringing ? Theme.amber : Theme.mint) {
                            model.ringPhone(peer.id, !ringing)
                        }
                        if data.features.contains("sms") {
                            QuickTile(icon: "message.fill", title: "New SMS") { model.composeSms(to: "") }
                        }
                        if data.features.contains("screen") {
                            QuickTile(icon: "rectangle.on.rectangle", title: "Phone screen") { model.peerTab = .screen }
                        }
                    }
                }
            }
        }
    }

    private var storageText: String {
        guard let free = peer.info?.storageFreeBytes, let total = peer.info?.storageTotalBytes else { return "No data yet" }
        return "\(Format.bytes(free)) free of \(Format.bytes(total))"
    }

    private var storageBar: (free: Int64, total: Int64)? {
        guard let free = peer.info?.storageFreeBytes, let total = peer.info?.storageTotalBytes else { return nil }
        return (free, total)
    }

    private var callMusicCard: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "pause.circle").font(.system(size: 20)).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pause the Mac during calls").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("When the phone rings, whatever plays on the Mac pauses, and it plays again when the call ends. Uses the Accessibility permission.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Bindable(Shared.callPauser).isEnabled).labelsHidden().toggleStyle(.switch).tint(Theme.mint)
            }
        }
    }

    private var networkText: String {
        let network = peer.info?.network ?? "Unknown"
        guard let level = peer.info?.wifiLevel else { return network }
        return "\(network), signal \(level)/4"
    }

    private var cellularText: String {
        let info = peer.info
        var parts = [info?.carrier, info?.cellType].compactMap { $0 }
        if let level = info?.signalLevel { parts.append("signal \(level)/4") }
        return parts.isEmpty ? "Unknown" : parts.joined(separator: ", ")
    }

    private var lastCallText: String {
        let data = model.phone(peer.id)
        guard data.features.contains("calls") else { return "Turned off on the phone" }
        guard let call = data.lastCall else { return "None yet" }
        let name = call.number.map(data.name(for:)) ?? "Unknown number"
        return "\(CallText.label(call.state)): \(name)"
    }

}

private struct EmptyState: View {
    let model: AppModel
    let addresses: [String]
    let animated: Bool

    /// What outside DyskLink can keep phones from finding this Mac, each with where it's fixed.
    private var hints: [(text: String, pane: String)] {
        var list: [(String, String)] = []
        if addresses.isEmpty {
            list.append(("This Mac isn't on a network. Turn on Wi-Fi and join the same network as the phone.", SystemPane.wifi))
        }
        if let problem = model.firewallProblem { list.append((problem.message, SystemPane.firewall)) }
        if model.localNetworkDenied {
            list.append(("Local Network access is off for DyskLink, so it can't find devices nearby. Turn on DyskLink in Privacy & Security › Local Network.", SystemPane.localNetwork))
        }
        return list
    }

    var body: some View {
        VStack(spacing: 12) {
            RadarView(animated: animated)
            Text("Waiting for your phone").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text("Open DyskLink on Android and make sure the phone is on the same Wi-Fi.\nThis Mac will show up on the phone automatically.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).lineSpacing(3)
            if let address = addresses.first {
                HStack(spacing: 7) {
                    Text("Manual connection").foregroundStyle(Theme.textFaint)
                    Text("\(address):\(String(PhoneLinkProtocol.port))")
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.mintText).textSelection(.enabled)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .padding(.top, 8)
            }
            ForEach(hints, id: \.text) { hint in
                HintRow(text: hint.text) { SystemPane.open(hint.pane) }
                    .padding(12)
                    .frame(maxWidth: 520)
                    .background(Theme.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .padding(.top, 4)
        }
        .padding(30)
        .onAppear { model.refreshFirewall() }
    }
}

private struct NewPeerState: View {
    let peer: Peer
    let onPair: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: peer.isComputer ? "laptopcomputer.and.arrow.down" : "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 42, weight: .semibold)).foregroundStyle(Theme.accentGradient)
            Text(peer.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text("This device is connected but not trusted yet.\nPair them so the two devices can exchange data.")
                .font(.system(size: 13.5)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).lineSpacing(3)
            Button("Start pairing", action: onPair).buttonStyle(PrimaryButtonStyle()).padding(.top, 8)
        }
        .padding(30)
    }
}

private struct ErrorState: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 38)).foregroundStyle(Theme.coral)
            Text("The server couldn't start").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(message).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
        }
        .padding(30)
    }
}

struct PairingOverlay: View {
    let prompt: PairingPrompt
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            Theme.scrim
            VStack(spacing: 18) {
                LogoMark(size: 46)
                if prompt.outdated {
                    title("Can't pair yet", prompt.error ?? "")
                    Button("Close") { model.rejectPairing() }.buttonStyle(SecondaryButtonStyle())
                } else if prompt.showsCode {
                    title("Pair with \(prompt.peerName)", "Type this code on \(prompt.peerName). It works only for this pairing.")
                    HStack(spacing: 8) {
                        ForEach(Array(prompt.code.enumerated()), id: \.offset) { index, digit in
                            Text(String(digit))
                                .font(.system(size: 31, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(width: 48, height: 62)
                                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Theme.mint.opacity(0.28)))
                                .padding(.trailing, index == 2 ? 8 : 0)
                        }
                    }
                    if let error = prompt.error { errorText(error) }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the code…").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                    Button("Cancel") { model.rejectPairing() }.buttonStyle(SecondaryButtonStyle())
                } else {
                    title("Enter the code", "Type the 6-digit code shown on \(prompt.peerName).")
                    DyskField(icon: "number", placeholder: "000000", text: $model.pairingEntry, monospaced: true, clearable: false) {
                        model.submitPairingCode(model.pairingEntry)
                    }
                    .frame(width: 220)
                    .onChange(of: model.pairingEntry) { _, value in
                        let digits = String(value.filter(\.isNumber).prefix(6))
                        if digits != value { model.pairingEntry = digits }
                        if digits.count == 6, !prompt.localAccepted { model.submitPairingCode(digits) }
                    }
                    if let error = prompt.error { errorText(error) }
                    if prompt.localAccepted {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking the code…").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        }
                        .frame(height: 42)
                    } else {
                        HStack(spacing: 10) {
                            Button("Cancel") { model.rejectPairing() }.buttonStyle(SecondaryButtonStyle())
                            Button("Pair") { model.submitPairingCode(model.pairingEntry) }.buttonStyle(PrimaryButtonStyle())
                                .disabled(model.pairingEntry.count != 6)
                                .opacity(model.pairingEntry.count == 6 ? 1 : 0.5)
                        }
                    }
                }
            }
            .padding(32)
            .frame(width: 440)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.stroke))
            .shadow(color: Theme.shadow, radius: 40, y: 18)
        }
    }

    private func title(_ text: String, _ detail: String) -> some View {
        VStack(spacing: 5) {
            Text(text).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorText(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.coralText)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
}

/// Shown above Advanced when a newer version is out.
/// A big button under the phone's name for the most used actions.
private struct QuickTile: View {
    let icon: String
    let title: String
    var tint: Color = Theme.mint
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A small fact about the phone, in the "At a glance" grid.
private struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    var bar: (free: Int64, total: Int64)?

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mint)
                    Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let bar { StorageBar(free: bar.free, total: bar.total) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        }
    }
}
