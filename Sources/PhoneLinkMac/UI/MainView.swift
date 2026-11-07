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
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let prompt = model.pairingPrompt {
                PairingOverlay(prompt: prompt, model: model)
            }
        }
        .preferredColorScheme(.dark)
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
                        PeerRow(peer: peer, isSelected: peer.id == model.selectedPeerId)
                            .onTapGesture {
                                model.selectedPeerId = peer.id
                                model.showsTools = false
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
            advancedButton
        }
        .padding(.horizontal, 18).padding(.top, 38).padding(.bottom, 18)
        .frame(width: 272)
        .background(Theme.ink.opacity(0.42))
    }

    private var advancedButton: some View {
        HStack(spacing: 11) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(model.showsTools ? Theme.mint : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Advanced").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(model.showsTools ? Theme.panelRaised : Color.clear, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(model.showsTools ? Theme.mint.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.showsTools = true
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
        } else if case .failed(let message) = model.serverState {
            ErrorState(message: message)
        } else if let peer = selected {
            if peer.isPaired {
                PeerDetail(model: model, peer: peer, scrolls: animated, onUnpair: { model.unpair(peer.id) })
            } else {
                NewPeerState(peer: peer, onPair: { model.requestPairing(with: peer.id) })
            }
        } else {
            EmptyState(addresses: model.addresses, animated: animated)
        }
    }
}

/// ImageRenderer doesn't draw ScrollView content, so snapshots use a plain view.
struct OptionalScroll<Content: View>: View {
    let enabled: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if enabled { ScrollView { content } } else { content }
    }
}

private struct PeerRow: View {
    let peer: Peer
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(peer.isConnected ? Theme.mint : Theme.textFaint)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let percent = peer.info?.batteryPercent, peer.isConnected {
                Text("\(percent)%").font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.batteryColor(percent))
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
            VStack(alignment: .leading, spacing: 16) {
                if model.peerTab == .overview { hero }
                PeerTabBar(model: model, peer: peer)
                switch model.peerTab {
                case .overview: overview
                case .notifications: NotificationsTab(model: model, peer: peer)
                case .messages: MessagesTab(model: model, peer: peer, scrolls: scrolls)
                case .contacts: ContactsTab(model: model, peer: peer)
                case .files: FilesTab(model: model, peer: peer)
                case .screen: ScreenTab(model: model, peer: peer)
                }
            }
            .padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var overview: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            InfoTile(icon: "wifi", title: "Network", value: networkText)
            InfoTile(icon: "antenna.radiowaves.left.and.right", title: "Cellular", value: cellularText)
            InfoTile(icon: "cpu", title: "System", value: peer.info?.osVersion ?? "Unknown")
            InfoTile(icon: "phone.fill", title: "Last call", value: lastCallText)
        }
        storage
        FeatureCards(model: model, peer: peer)
        HStack {
            Spacer()
            Button("Unpair", action: onUnpair)
                .buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
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

    private var hero: some View {
        Card(padding: 26) {
            HStack(spacing: 28) {
                BatteryRing(percent: peer.info?.batteryPercent, charging: peer.info?.isCharging ?? false)
                VStack(alignment: .leading, spacing: 9) {
                    StatusPill(
                        text: peer.isConnected ? "Connected" : "Not connected",
                        color: peer.isConnected ? Theme.mint : Theme.textFaint
                    )
                    Text(peer.name).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(peer.info?.model ?? peer.model).font(.system(size: 13.5))
                        .foregroundStyle(Theme.textSecondary)
                    if !peer.isConnected, let lastSeen = peer.lastSeen {
                        Text("Last seen \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var storage: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Storage").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if let free = peer.info?.storageFreeBytes {
                        Text("\(Format.bytes(free)) free").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                if let free = peer.info?.storageFreeBytes, let total = peer.info?.storageTotalBytes {
                    StorageBar(free: free, total: total)
                    Text("\(Format.bytes(total)) total").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                } else {
                    Text("No data yet").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
            }
        }
    }
}

private struct EmptyState: View {
    let addresses: [String]
    let animated: Bool

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
                        .foregroundStyle(Theme.mint).textSelection(.enabled)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .padding(.top, 8)
            }
        }
        .padding(30)
    }
}

private struct NewPeerState: View {
    let peer: Peer
    let onPair: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
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
    let model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
            VStack(spacing: 18) {
                LogoMark(size: 46)
                VStack(spacing: 5) {
                    Text("Match the code").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Text("Make sure the code on \(prompt.peerName) is exactly the same.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
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
                if prompt.localAccepted {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for confirmation from the phone…")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(height: 42)
                } else {
                    HStack(spacing: 10) {
                        Button("Decline") { model.rejectPairing() }.buttonStyle(SecondaryButtonStyle())
                        Button("Codes match") { model.acceptPairing() }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .padding(32)
            .frame(width: 440)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
        }
    }
}
