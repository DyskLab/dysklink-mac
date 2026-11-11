import SwiftUI

/// The page for another Mac, or a Windows or Linux PC: clipboard sync, files, and finding it. Phone pages don't apply.
struct MacPeerDetail: View {
    @Bindable var model: AppModel
    let peer: Peer
    let scrolls: Bool
    let onUnpair: () -> Void

    /// "Mac", or "PC" for Windows and Linux.
    private var kind: String { peer.isMac ? "Mac" : "PC" }

    var body: some View {
        OptionalScroll(enabled: scrolls) {
            VStack(alignment: .leading, spacing: 16) {
                hero
                clipboardCard
                if peer.isConnected { fileCard; ringCard }
                HStack {
                    Spacer()
                    Button("Unpair", action: onUnpair).buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                }
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 24)
        }
    }

    private var hero: some View {
        Card(padding: 26) {
            HStack(spacing: 24) {
                Image(systemName: peer.isMac ? "laptopcomputer" : "pc")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(peer.isConnected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.textFaint))
                    .frame(width: 110, height: 110)
                    .background(Color.white.opacity(0.05), in: Circle())
                VStack(alignment: .leading, spacing: 9) {
                    StatusPill(text: peer.isConnected ? "Connected" : "Not connected",
                               color: peer.isConnected ? Theme.mint : Theme.textFaint)
                    Text(peer.name).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Text(details).font(.system(size: 13.5)).foregroundStyle(Theme.textSecondary)
                    if !peer.isConnected, let lastSeen = peer.lastSeen {
                        Text("Last seen \(lastSeen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var details: String {
        var parts = [peer.info?.model ?? peer.model, peer.info?.osVersion].compactMap { $0 }.filter { !$0.isEmpty }
        if let percent = peer.info?.batteryPercent, peer.isConnected {
            parts.append("Battery \(percent)%" + (peer.info?.isCharging == true ? ", charging" : ""))
        }
        return parts.joined(separator: " · ")
    }

    private var clipboardCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 20)).foregroundStyle(Theme.mint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Clipboard sync").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Text you copy on this Mac or the \(kind) can be pasted on the other. It goes straight between the two over this network, encrypted.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle("Share copies with paired devices", isOn: $model.clipboardEnabled)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                // Only DyskLink for Mac keeps a Clipboard History to merge.
                if peer.isMac {
                    Toggle("Merge Clipboard History when the Macs connect", isOn: $model.sharesClipboardHistory)
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                        .disabled(!model.clipboardEnabled)
                    Text(Shared.tools.isClipboardOn
                         ? "The newest 500 text copies are swapped, and ones you already have are skipped. Images stay on each Mac."
                         : "Turn on Clipboard History in Advanced to merge histories too.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.dyskSwitch)
    }

    private var fileCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Send files").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Files from the \(kind) go to Downloads/DyskLink.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Choose files") { model.pickFiles(for: peer.id) }.buttonStyle(PrimaryButtonStyle())
                }
                ForEach(model.transfers.filter { $0.peerId == peer.id }) { TransferRow(transfer: $0) }
            }
        }
    }

    private var ringCard: some View {
        let ringing = model.ringingPhones.contains(peer.id)
        return Card {
            HStack(spacing: 14) {
                Image(systemName: ringing ? "speaker.wave.3.fill" : "speaker.wave.2").font(.system(size: 20))
                    .foregroundStyle(ringing ? Theme.amber : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Find this \(kind)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Plays a sound and shows an alert on \(peer.name) for 30 seconds.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Button(ringing ? "Stop" : "Ring") { model.ringPhone(peer.id, !ringing) }
                    .buttonStyle(SecondaryButtonStyle(tint: ringing ? Theme.coral : Theme.textPrimary))
            }
        }
    }
}
