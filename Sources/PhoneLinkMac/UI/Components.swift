import SwiftUI

struct BatteryRing: View {
    let percent: Int?
    let charging: Bool
    var size: CGFloat = 148

    var body: some View {
        let color = percent.map(Theme.batteryColor) ?? Theme.textFaint
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: size * 0.075)
            Circle()
                .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 10)
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(percent.map(String.init) ?? "-")
                        .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    if percent != nil {
                        Text("%").font(.system(size: size * 0.11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(spacing: 4) {
                    if charging { Image(systemName: "bolt.fill").foregroundStyle(color) }
                    Text(charging ? "Charging" : "Battery")
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.system(size: 11.5, weight: .medium))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Radar animation for the waiting-for-device state.
struct RadarView: View {
    var animated = true

    private static let duration = 2.7

    var body: some View {
        ZStack {
            if animated {
                TimelineView(.animation) { timeline in
                    rings(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                rings(time: 1.1)
            }
            Circle().fill(Theme.accentGradient).frame(width: 66, height: 66)
                .shadow(color: Theme.mint.opacity(0.5), radius: 22)
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .frame(width: 230, height: 230)
    }

    private func rings(time: TimeInterval) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let offset = Double(index) * Self.duration / 3
                let progress = (time + offset).truncatingRemainder(dividingBy: Self.duration) / Self.duration
                Circle()
                    .strokeBorder(Theme.mint.opacity(0.55 * (1 - progress)), lineWidth: 1.5)
                    .scaleEffect(0.25 + 0.75 * progress)
            }
        }
    }
}

struct StorageBar: View {
    let free: Int64
    let total: Int64

    var body: some View {
        let used = max(0, Double(total - free) / Double(max(total, 1)))
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Theme.accentGradient).frame(width: max(6, proxy.size.width * used))
            }
        }
        .frame(height: 7)
    }
}

struct InfoTile: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.mint)
                    .frame(width: 34, height: 34)
                    .background(Theme.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text(value).font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary).lineLimit(2)
            }
        }
    }
}

struct LogoMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24).fill(Theme.logo)
            LogoGlyph().fill(Color.white).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}
