import SwiftUI

/// The phone's screen time today: the total, unlocks, and the most used apps with a bar each.
struct ScreenTimeCard: View {
    let model: AppModel
    let peer: Peer

    static func duration(_ ms: Int64) -> String {
        let minutes = Int(ms / 60_000)
        if minutes < 1 { return "Under a minute" }
        let hours = minutes / 60
        if hours == 0 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
    }

    var body: some View {
        let data = model.phone(peer.id)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen time today").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        Text(data.usage.map { Self.duration($0.totalMs) } ?? "—")
                            .font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        if let unlocks = data.usage?.unlocks, unlocks >= 0 {
                            Text("\(unlocks) unlocks").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        }
                        if let time = data.usageTime {
                            Text("Updated \(time.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                        }
                    }
                    Button { model.requestScreenTime(peer.id, force: true) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 26, height: 26)
                            .background(Theme.panelRaised, in: Circle())
                    }
                    .buttonStyle(.plain).help("Refresh").disabled(!peer.isConnected)
                }
                if let usage = data.usage {
                    if usage.apps.isEmpty {
                        Text("No app used for more than half a minute yet today.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    let longest = max(1, usage.apps.first?.ms ?? 1)
                    ForEach(usage.apps) { app in
                        HStack(spacing: 10) {
                            Group {
                                if let icon = PhoneImages.image(app.icon) {
                                    Image(nsImage: icon).resizable().interpolation(.high)
                                } else {
                                    RoundedRectangle(cornerRadius: 6).fill(Theme.panelRaised)
                                        .overlay(Image(systemName: "app.fill").font(.system(size: 11)).foregroundStyle(Theme.textFaint))
                                }
                            }
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(app.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    Spacer()
                                    Text(Self.duration(app.ms)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                }
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.07))
                                        Capsule().fill(Theme.mint).frame(width: max(4, proxy.size.width * CGFloat(app.ms) / CGFloat(longest)))
                                    }
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                } else {
                    Text(peer.isConnected ? "Asking the phone…" : "Connect the phone to see today's screen time.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        // Every five minutes while it's on screen.
        .task(id: peer.id) {
            while !Task.isCancelled {
                model.requestScreenTime(peer.id)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}
