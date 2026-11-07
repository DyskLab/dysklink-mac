import AppKit
import ScreenCaptureKit

/// Available for many years and used by most window tools, but not in a public header.
@_silgen_name("_AXUIElementGetWindow")
private func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowItem: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    let pid: pid_t
    let icon: NSImage?
    let isMinimized: Bool
    let element: AXUIElement
}

/// Finds windows through Accessibility and draws them through ScreenCaptureKit.
enum WindowCatalog {
    private static func attribute<T>(_ element: AXUIElement, _ name: String, as type: T.Type = T.self) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func windows(of app: NSRunningApplication) -> [WindowItem] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // An app that has stopped responding must not hold up the whole list.
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let list: [AXUIElement] = attribute(element, kAXWindowsAttribute) else { return [] }
        return list.compactMap { window in
            let subrole: String? = attribute(window, kAXSubroleAttribute)
            guard subrole == nil || subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
            var id: CGWindowID = 0
            guard axWindowID(window, &id) == .success, id != 0 else { return nil }
            let title: String = attribute(window, kAXTitleAttribute) ?? ""
            let minimized: Bool = attribute(window, kAXMinimizedAttribute) ?? false
            return WindowItem(id: id, title: title, appName: app.localizedName ?? "", pid: app.processIdentifier,
                              icon: app.icon, isMinimized: minimized, element: window)
        }
    }

    /// Every window on the current Space, frontmost first. Minimized windows come last.
    static func allWindows(limit: Int) -> [WindowItem] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let all = apps.flatMap(windows)
        let order = frontToBack()
        return Array(sortWindows(all.map { (item: $0, id: $0.id, isMinimized: $0.isMinimized) }, order: order).map(\.item).prefix(limit))
    }

    static func sortWindows<T>(_ rows: [(item: T, id: CGWindowID, isMinimized: Bool)], order: [CGWindowID]) -> [(item: T, id: CGWindowID, isMinimized: Bool)] {
        var rank: [CGWindowID: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        return rows.enumerated().sorted { first, second in
            let a = first.element, b = second.element
            if a.isMinimized != b.isMinimized { return !a.isMinimized }
            let left = rank[a.id] ?? .max, right = rank[b.id] ?? .max
            return left == right ? first.offset < second.offset : left < right
        }.map(\.element)
    }

    private static func frontToBack() -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    static func focus(_ window: WindowItem) {
        if window.isMinimized {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        // macOS can ignore activate() from an app in the background, so ask through Accessibility too.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(window.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    static func minimize(_ window: WindowItem) {
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// Presses the window's own close button, so the app can still ask about unsaved work.
    static func close(_ window: WindowItem) {
        if let button: AXUIElement = attribute(window.element, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    static func thumbnails(for ids: [CGWindowID], width: Int) async -> [CGWindowID: NSImage] {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }
        var images: [CGWindowID: NSImage] = [:]
        for id in ids {
            guard let window = content.windows.first(where: { $0.windowID == id }), window.frame.width > 0 else { continue }
            let config = SCStreamConfiguration()
            config.width = width
            config.height = max(1, Int(CGFloat(width) * window.frame.height / window.frame.width))
            config.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                images[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
        return images
    }

    /// The preview stays while the pointer is on the icon, on the panel, or crossing the gap between them.
    static func keepsPreview(pointer: CGPoint, icon: CGRect, panel: CGRect) -> Bool {
        if panel.insetBy(dx: -2, dy: -2).contains(pointer) || icon.insetBy(dx: -1, dy: -1).contains(pointer) { return true }
        let isAbove = panel.minY >= icon.maxY
        let isBelow = panel.maxY <= icon.minY
        let gap: CGRect
        if isAbove {
            gap = CGRect(x: icon.minX, y: icon.maxY, width: icon.width, height: panel.minY - icon.maxY)
        } else if isBelow {
            gap = CGRect(x: icon.minX, y: panel.maxY, width: icon.width, height: icon.minY - panel.maxY)
        } else if panel.minX >= icon.maxX {
            gap = CGRect(x: icon.maxX, y: icon.minY, width: panel.minX - icon.maxX, height: icon.height)
        } else {
            gap = CGRect(x: panel.maxX, y: icon.minY, width: icon.minX - panel.maxX, height: icon.height)
        }
        return gap.insetBy(dx: -1, dy: -1).contains(pointer)
    }

    /// Where the preview goes beside a Dock icon. All values use AppKit's bottom-left coordinates.
    static func placement(panel: CGSize, icon: CGRect, screen: CGRect, gap: CGFloat = 10) -> CGPoint {
        let isLeftDock = icon.maxX < screen.minX + screen.width * 0.25 && icon.height >= icon.width * 0.5 && icon.midY > screen.minY + 120
        let isRightDock = icon.minX > screen.maxX - screen.width * 0.25 && icon.midY > screen.minY + 120
        var origin: CGPoint
        if isLeftDock {
            origin = CGPoint(x: icon.maxX + gap, y: icon.midY - panel.height / 2)
        } else if isRightDock {
            origin = CGPoint(x: icon.minX - gap - panel.width, y: icon.midY - panel.height / 2)
        } else {
            origin = CGPoint(x: icon.midX - panel.width / 2, y: icon.maxY + gap)
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - panel.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - panel.height - 8)
        return origin
    }
}
