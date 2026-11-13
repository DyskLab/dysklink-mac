import AppKit
import SwiftUI

/// Decodes the small base64 pictures phones send with notifications, once each.
@MainActor
enum PhoneImages {
    private static let cache = NSCache<NSString, NSImage>()
    /// The last icon seen for each app, so a notification without one still gets its app's icon.
    private static var appIcons: [String: String] = [:]

    static func image(_ base64: String?) -> NSImage? {
        guard let base64, !base64.isEmpty, base64.count < 2_000_000 else { return nil }
        if let hit = cache.object(forKey: base64 as NSString) { return hit }
        guard let data = Data(base64Encoded: base64), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: base64 as NSString)
        return image
    }

    static func appIcon(_ item: NotificationItem) -> NSImage? {
        if let icon = item.icon, let pkg = item.pkg { appIcons[pkg] = icon }
        return image(item.icon ?? item.pkg.flatMap { appIcons[$0] })
    }
}

/// The app icon, or the sender's photo with the app icon in the corner, like on the phone.
struct NotificationIcon: View {
    let item: NotificationItem
    var size: CGFloat = 36

    var body: some View {
        let app = PhoneImages.appIcon(item)
        let avatar = PhoneImages.image(item.avatar)
        ZStack(alignment: .bottomTrailing) {
            if let avatar {
                Image(nsImage: avatar).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(Circle())
                if let app {
                    Image(nsImage: app).resizable().interpolation(.high)
                        .frame(width: size * 0.46, height: size * 0.46)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous).strokeBorder(Theme.panel, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            } else if let app {
                Image(nsImage: app).resizable().interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                // Older phone app: a letter on the app's color.
                Text(String(item.app.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(Color.white)
                    .frame(width: size, height: size)
                    .background(accent.opacity(0.75), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }

    private var accent: Color { item.color.map { Color(hex: UInt32($0 & 0xFFFFFF)) } ?? Theme.violet }
}

/// A picture sent with the notification, such as a photo in a chat.
struct NotificationPicture: View {
    let item: NotificationItem
    var size: CGFloat = 44

    var body: some View {
        if let picture = PhoneImages.image(item.picture) {
            Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}
