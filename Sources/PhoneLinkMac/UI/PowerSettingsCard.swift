import SwiftUI

/// macOS power settings beside DyskLink's charge control: Low Power Mode, and Optimized Battery Charging explained.
struct PowerSettingsCard: View {
    @Bindable var power: PowerSettings
    var nativeLimit: Int?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("macOS power settings").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if power.busy { ProgressView().controlSize(.small) }
                    if power.lowPowerActive { StatusPill(text: "Low Power Mode on", color: Theme.amber) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "leaf").font(.system(size: 13)).foregroundStyle(Theme.textPrimary).frame(width: 20)
                        Text("Low Power Mode").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        ForEach(PowerSettings.LowPower.allCases) { mode in
                            let chosen = power.lowPower == mode
                            Button(mode.label) { power.setLowPower(mode) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(chosen ? Theme.ink : Theme.textPrimary)
                                .padding(.horizontal, 9).frame(height: 25)
                                .background(chosen ? Theme.mint : Theme.panelRaised, in: Capsule())
                                .disabled(power.busy)
                        }
                    }
                    note("Saves energy by slowing the Mac a little and dimming the screen. Changing it asks for your admin password, unless the charging helper is installed with this version.")
                }
                Divider().overlay(Theme.stroke)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "battery.100percent.bolt").font(.system(size: 13)).foregroundStyle(Theme.textPrimary).frame(width: 20)
                        Text("Optimized Battery Charging").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        Button("Open Battery Settings") { NSWorkspace.shared.open(PowerSettings.batterySettings) }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                    }
                    note("macOS learns your routine and may hold charging at 80% until you usually unplug. That can fight DyskLink's charge limit, so turn it off in System Settings › Battery › Battery Health (ⓘ) while you use the limit. macOS doesn't let other apps read or change it.")
                    if let nativeLimit, nativeLimit < 100 {
                        Text("macOS's own Charge Limit is set to \(nativeLimit)%.").font(.system(size: 12)).foregroundStyle(Theme.amber)
                    }
                }
                if let error = power.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral)
                }
            }
        }
        .onAppear { power.refresh() }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}
