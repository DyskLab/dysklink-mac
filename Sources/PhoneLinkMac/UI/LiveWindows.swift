#if DEBUG
import AppKit
import SwiftUI

/// Opens one real window with sample data, to check the look with window materials, switches and text fields
/// drawn by AppKit: `DYSKLINK_LIVE_WINDOW=<scenario> PhoneLinkMac`. It prints `LIVE_WINDOW <number>` for
/// `screencapture -l`, and the appearance comes from the saved setting.
@MainActor
enum LiveWindows {
    private static var windows: [NSWindow] = []

    static let scenarios = ["empty", "devices", "pairing", "pairing-enter", "overview", "notifications", "messages",
                            "contacts", "files", "screen", "off", "advanced-general", "advanced-overview", "advanced-productivity",
                            "advanced-screen", "advanced-notch", "care-cleaner", "care-battery", "care-duplicates", "history",
                            "menubar", "alert"]

    static func open(_ scenario: String) {
        CareIcons.loadsSynchronously = true
        let phone = Peer(id: "demo-1", name: "Sample Phone", platform: "android", model: "Android 36",
                         isPaired: true, isConnected: true,
                         info: DeviceInfo(batteryPercent: 76, isCharging: true, network: "Wi-Fi",
                                          storageFreeBytes: 82_000_000_000, storageTotalBytes: 256_000_000_000,
                                          osVersion: "Android 16", model: "Android 36"),
                         lastSeen: nil)
        let offline = Peer(id: "demo-2", name: "Second Phone", platform: "android", model: "Android 34",
                           isPaired: true, isConnected: false, info: nil, lastSeen: nil)
        let fresh = Peer(id: "demo-3", name: "New Phone", platform: "android", model: "Android 35",
                         isPaired: false, isConnected: true, info: nil, lastSeen: nil)
        let model = AppModel()
        let tabs: [String: PeerTab] = ["overview": .overview, "notifications": .notifications, "messages": .messages,
                                       "contacts": .contacts, "files": .files, "screen": .screen, "off": .messages]
        switch scenario {
        case "empty":
            model.loadSnapshotState([], prompt: nil, addresses: ["192.168.1.20"])
        case "devices":
            model.loadSnapshotState([phone, offline, fresh], prompt: nil, addresses: ["192.168.1.20"])
            model.selectedPeerId = fresh.id
        case "pairing":
            model.loadSnapshotState([fresh, phone], prompt: PairingPrompt(peerId: "demo-3", peerName: "New Phone", code: "482915",
                                                                          startedByPeer: true), addresses: ["192.168.1.20"])
        case "pairing-enter":
            model.loadSnapshotState([fresh, phone], prompt: PairingPrompt(peerId: "demo-3", peerName: "New Phone", code: "",
                                                                          startedByPeer: false), addresses: ["192.168.1.20"])
        case let name where tabs[name] != nil:
            var demo = Snapshots.demoPhone()
            if name == "off" { demo = PhoneSnapshot(); demo.apply(features: []) }
            model.loadSnapshotState([phone, offline], prompt: nil, addresses: ["192.168.1.20"], phone: demo, tab: tabs[name]!)
        case let name where name.hasPrefix("advanced-"):
            let categories: [String: AdvancedCategory] = ["general": .general, "overview": .overview,
                                                                 "productivity": .productivity, "screen": .screen, "notch": .notch]
            AdvancedLayout.shared.persists = false
            AdvancedLayout.shared.category = categories[String(name.dropFirst(9))] ?? .general
            model.loadSnapshotState([phone], prompt: nil, addresses: ["192.168.1.20"], phone: Snapshots.demoPhone())
            model.showsTools = true
        case let name where name.hasPrefix("care-"):
            model.loadSnapshotState([phone], prompt: nil, addresses: ["192.168.1.20"], phone: Snapshots.demoPhone())
            let care = Shared.care
            care.loadsOnShow = false
            let home = URL(fileURLWithPath: "/Users/sample")
            func item(_ path: String, _ size: Int64, _ detail: String = "") -> CareItem {
                CareItem(url: home.appendingPathComponent(path), size: size, detail: detail, date: Date().addingTimeInterval(-40 * 86_400))
            }
            switch name {
            case "care-battery":
                care.tab = .battery
                care.battery = BatteryReading(percent: 80, cycles: 163, designCycles: 1000, designMah: 4629, fullMah: 4421, voltageMv: 12401,
                                              amperageMa: -700, isCharging: false, isPluggedIn: false, isFull: false, adapterWatts: 30,
                                              minutesToFull: nil, minutesToEmpty: 198, temperatureC: 37.9, appleMaxCapacity: 97, condition: "Good")
                care.batteryHistory = (0..<40).map { i in
                    BatteryDay(day: String(format: "2026-%02d-%02d", 9 + i / 30, 1 + i % 30), health: 100 - i / 12, fullMah: 4500, cycles: 120 + i)
                }
            case "care-duplicates":
                care.tab = .duplicates
                care.dupScanned = true
                care.dupGroups = [DuplicateGroup(id: "a", size: 48_000_000, files: [item("Documents/Video/intro.mp4", 48_000_000),
                                                                                     item("Downloads/intro.mp4", 48_000_000)])]
                care.dupSelected = Set(care.dupGroups.flatMap { $0.files.dropFirst().map(\.id) })
            default:
                care.cleanGroups = [
                    .caches: [item("Library/Caches/com.spotify.client", 2_400_000_000), item("Library/Caches/Homebrew", 420_000_000)],
                    .developer: [item("Library/Developer/Xcode/DerivedData", 9_800_000_000, "~/Library/Developer/Xcode")],
                ]
                care.cleanSelected = Set(care.cleanGroups.filter { $0.key.selectedByDefault }.flatMap { $0.value.map(\.id) })
                care.cleanScanned = true
            }
            model.showsCare = true
        case "history":
            let now = Date()
            model.loadSnapshotState([phone], prompt: nil, addresses: ["192.168.1.20"])
            model.loadSnapshotHistory([
                FileRecord(id: "1", device: "Sample Phone", name: "IMG_2041.jpg", size: 3_400_000, outgoing: false, date: now.addingTimeInterval(-300), ok: true),
                FileRecord(id: "3", device: "Second Phone", name: "rekaman.m4a", size: 8_100_000, outgoing: false, date: now.addingTimeInterval(-86_400), ok: false, detail: "Connection lost"),
            ], filter: .all)
        case "menubar":
            let window = makeWindow(NSHostingView(rootView: MenuBarView(model: model, scrolls: false).fixedSize()), size: CGSize(width: 340, height: 640))
            report(window)
            return
        case "alert":
            model.loadSnapshotState([phone], prompt: nil, addresses: ["192.168.1.20"])
            let window = makeWindow(NSHostingView(rootView: MainView(model: model)), size: CGSize(width: 980, height: 660))
            let alert = NSAlert()
            alert.messageText = "Unpair Sample Phone?"
            alert.informativeText = "It will need the code again to connect."
            alert.addButton(withTitle: "Unpair")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { _ in }
            report(window)
            return
        default:
            print("Unknown scenario \(scenario). Known: \(scenarios.joined(separator: ", "))")
            exit(2)
        }
        let window = makeWindow(NSHostingView(rootView: MainView(model: model)), size: CGSize(width: 980, height: 760))
        report(window)
    }

    private static func makeWindow(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(name: nil) { $0.isDark ? NSColor(hex: 0x090D13) : NSColor(hex: 0xF3F5F8) }
        window.contentView = view
        NSApp.setActivationPolicy(.accessory)
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private static func report(_ window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            print("LIVE_WINDOW \(window.windowNumber)")
        }
    }
}
#endif
