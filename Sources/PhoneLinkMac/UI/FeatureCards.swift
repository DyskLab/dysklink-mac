import AppKit
import SwiftUI

/// Feature cards on the page of a paired device.
struct FeatureCards: View {
    @Bindable var model: AppModel
    let peer: Peer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if peer.isConnected {
                fileCard
                mediaCard
            }
            if !model.isInputTrusted { accessibilityCard }
            clipboardCard
            commandsCard
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

    private var commandsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Commands").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("The phone can only run commands on this list. They run with your Mac account's privileges.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                ForEach(model.commands) { command in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                            Text(command.script).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textFaint).lineLimit(1)
                        }
                        Spacer()
                        Button("Remove") { model.removeCommand(command.id) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.coral)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Name", text: $model.newCommandName).textFieldStyle(.roundedBorder).frame(width: 130)
                    TextField("Shell command, for example pmset displaysleepnow", text: $model.newCommandScript)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") { model.addCommand() }.buttonStyle(SecondaryButtonStyle())
                }
            }
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
