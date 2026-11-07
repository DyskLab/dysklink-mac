import SwiftUI

struct MenuBarView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                LogoMark(size: 26)
                Text("DyskLink").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if case .listening = model.serverState {
                    Circle().fill(Theme.mint).frame(width: 8, height: 8)
                }
            }
            let paired = model.peers.filter(\.isPaired)
            if paired.isEmpty {
                Text("No paired devices yet.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
            ForEach(paired) { peer in
                HStack(spacing: 9) {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(peer.isConnected ? Theme.mint : Theme.textFaint)
                    Text(peer.name).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    if peer.isConnected, let percent = peer.info?.batteryPercent {
                        Text("\(percent)%").font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.batteryColor(percent))
                    }
                }
            }
            if Shared.tools.isDisplaysOn {
                Divider().overlay(Theme.stroke)
                DisplaySliders(control: Shared.tools.displays)
            }
            if Shared.tools.isAwakeOn {
                Divider().overlay(Theme.stroke)
                let awake = Shared.tools.awake
                Button {
                    if awake.isActive { awake.stop() } else { awake.start() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer.fill")
                            .foregroundStyle(awake.isActive ? Theme.mint : Theme.textFaint)
                        Text(awake.isActive ? "Keep Awake is on" : "Start Keep Awake").foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if awake.isActive {
                            Text(awake.remainingText).font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
            }
            Divider().overlay(Theme.stroke)
            Button {
                model.setLaunchAtLogin(!model.launchAtLogin)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.launchAtLogin ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.launchAtLogin ? Theme.mint : Theme.textFaint)
                    Text("Open at login").foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
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
        .frame(width: 280)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}
