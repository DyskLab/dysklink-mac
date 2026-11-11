import SwiftUI

/// A phone notification with the phone it came from, for the notch.
struct PhoneAlert: Identifiable, Equatable {
    let peerId: String
    let phone: String
    let item: NotificationItem
    var id: String { "\(peerId):\(item.key)" }
}

extension NotchView {
    var alertsPage: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            AlertsPanel(alerts: alertsProvider(), now: context.date, scrolls: scrolls, dismiss: dismissAlert)
        }
    }
}

/// Notifications from connected phones that have Notifications turned on, newest first.
/// Notifications from other Mac apps can't be shown, because macOS has no public way to read them.
struct AlertsPanel: View {
    let alerts: [PhoneAlert]
    let now: Date
    var scrolls = true
    let dismiss: (PhoneAlert) -> Void

    var body: some View {
        if alerts.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "bell.slash").font(.system(size: 22)).foregroundStyle(Color.white.opacity(0.7))
                Text("No phone notifications").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white)
                Text("Turn on Notifications in DyskLink on the phone to see them here")
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            OptionalScroll(enabled: scrolls) {
                VStack(spacing: 6) {
                    ForEach(alerts) { row($0) }
                }
            }
        }
    }

    private func row(_ alert: PhoneAlert) -> some View {
        HStack(alignment: .center, spacing: 11) {
            NotificationIcon(item: alert.item, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(alert.item.app).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                    Text("·").foregroundStyle(Color.white.opacity(0.3))
                    Text(Self.age(alert.item.time, now: now)).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4))
                }
                .font(.system(size: 11))
                Text(alert.item.title ?? alert.item.app).font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white).lineLimit(1)
                if let text = alert.item.text, !text.isEmpty {
                    Text(text).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            NotificationPicture(item: alert.item, size: 42)
            Button { dismiss(alert) } label: {
                Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss on \(alert.phone)")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static func age(_ milliseconds: Int64, now: Date) -> String {
        let seconds = now.timeIntervalSince(Date(timeIntervalSince1970: Double(milliseconds) / 1000))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86400)) d"
    }
}

/// A new phone notification under the closed notch: who it's from, what it says, and its picture.
struct NoticeBanner: View {
    let alert: PhoneAlert

    var body: some View {
        HStack(spacing: 11) {
            NotificationIcon(item: alert.item, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(alert.item.app).fontWeight(.semibold).lineLimit(1)
                    Text("· \(alert.phone)").lineLimit(1)
                }
                .font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.5))
                Text(alert.item.title ?? alert.item.app).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white).lineLimit(1)
                if let text = alert.item.text, !text.isEmpty {
                    Text(text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.75)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            NotificationPicture(item: alert.item, size: 46)
        }
        .padding(.horizontal, 4)
    }
}

/// A one-time code under the notch. Click Copy, then paste it where it's asked.
struct CodeBanner: View {
    let notice: CodeNotice
    let copy: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "key.fill")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.black)
                .frame(width: 40, height: 40)
                .background(Color(red: 0.36, green: 0.86, blue: 0.69), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Code from \(notice.source) · \(notice.phone)").lineLimit(1)
                    .font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.5))
                Text(Self.spaced(notice.code))
                    .font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(Color.white).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: copy) {
                Label(notice.copied ? "Copied" : "Copy", systemImage: notice.copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.black)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Color.white.opacity(notice.copied ? 0.75 : 0.95), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Copy the code")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 24, height: 24).background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Hide")
        }
        .padding(.horizontal, 4)
    }

    /// 482915 reads as 482 915.
    static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }
}
