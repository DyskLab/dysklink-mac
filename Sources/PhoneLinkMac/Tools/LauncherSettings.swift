import AppKit

/// Settings the launcher can open: macOS System Settings pages, and DyskLink's own pages.
/// Each has extra words, in English and Indonesian, so "baterai" or "wifi" finds the right page.
enum LauncherSettings {
    struct Entry {
        let id: String
        let title: String
        let words: String
        let symbol: String
        /// A System Settings page, or nil for a DyskLink page.
        let pane: String?
    }

    /// System Settings pages by their extension ID (macOS 13 and later), opened with `x-apple.systempreferences:`.
    static let system: [Entry] = [
        Entry(id: "battery", title: "Battery", words: "baterai power low power mode hemat daya energy charging optimized", symbol: "battery.75percent", pane: "com.apple.Battery-Settings.extension"),
        Entry(id: "wifi", title: "Wi-Fi", words: "wireless internet jaringan wlan", symbol: "wifi", pane: "com.apple.wifi-settings-extension"),
        Entry(id: "bluetooth", title: "Bluetooth", words: "headphones airpods mouse keyboard", symbol: "dot.radiowaves.left.and.right", pane: "com.apple.BluetoothSettings"),
        Entry(id: "network", title: "Network", words: "jaringan ethernet vpn firewall proxy dns", symbol: "network", pane: "com.apple.Network-Settings.extension"),
        Entry(id: "displays", title: "Displays", words: "layar monitor resolution resolusi night shift brightness kecerahan", symbol: "display", pane: "com.apple.Displays-Settings.extension"),
        Entry(id: "sound", title: "Sound", words: "suara audio volume speaker microphone mikrofon output input", symbol: "speaker.wave.2.fill", pane: "com.apple.Sound-Settings.extension"),
        Entry(id: "notifications", title: "Notifications", words: "notifikasi alerts pemberitahuan", symbol: "bell.badge.fill", pane: "com.apple.Notifications-Settings.extension"),
        Entry(id: "focus", title: "Focus", words: "do not disturb jangan ganggu fokus", symbol: "moon.fill", pane: "com.apple.Focus-Settings.extension"),
        Entry(id: "screentime", title: "Screen Time", words: "waktu layar usage limits batas", symbol: "hourglass", pane: "com.apple.Screen-Time-Settings.extension"),
        Entry(id: "general", title: "General", words: "umum about tentang", symbol: "gearshape.fill", pane: "com.apple.systempreferences.GeneralSettings"),
        Entry(id: "about", title: "About This Mac", words: "tentang serial model info", symbol: "info.circle.fill", pane: "com.apple.SystemProfiler.AboutExtension"),
        Entry(id: "update", title: "Software Update", words: "pembaruan update upgrade macos", symbol: "arrow.down.circle.fill", pane: "com.apple.Software-Update-Settings.extension"),
        Entry(id: "storage", title: "Storage", words: "penyimpanan disk ruang space", symbol: "internaldrive.fill", pane: "com.apple.settings.Storage"),
        Entry(id: "login", title: "Login Items", words: "startup open at login item masuk background", symbol: "power", pane: "com.apple.LoginItems-Settings.extension"),
        Entry(id: "sharing", title: "Sharing", words: "berbagi airdrop file sharing screen sharing remote", symbol: "shareplay", pane: "com.apple.Sharing-Settings.extension"),
        Entry(id: "datetime", title: "Date & Time", words: "tanggal jam waktu timezone zona", symbol: "clock.fill", pane: "com.apple.Date-Time-Settings.extension"),
        Entry(id: "language", title: "Language & Region", words: "bahasa wilayah region format", symbol: "globe", pane: "com.apple.Localization-Settings.extension"),
        Entry(id: "appearance", title: "Appearance", words: "tampilan dark mode gelap terang accent warna", symbol: "circle.lefthalf.filled", pane: "com.apple.Appearance-Settings.extension"),
        Entry(id: "accessibility", title: "Accessibility", words: "aksesibilitas zoom voiceover", symbol: "accessibility", pane: "com.apple.Accessibility-Settings.extension"),
        Entry(id: "controlcenter", title: "Control Center", words: "pusat kontrol menu bar ikon", symbol: "switch.2", pane: "com.apple.ControlCenter-Settings.extension"),
        Entry(id: "siri", title: "Apple Intelligence & Siri", words: "siri ai asisten", symbol: "sparkles", pane: "com.apple.Siri-Settings.extension"),
        Entry(id: "spotlight", title: "Spotlight", words: "search pencarian cari", symbol: "magnifyingglass", pane: "com.apple.Spotlight-Settings.extension"),
        Entry(id: "privacy", title: "Privacy & Security", words: "privasi keamanan permissions izin filevault", symbol: "hand.raised.fill", pane: "com.apple.settings.PrivacySecurity.extension"),
        Entry(id: "privacy-accessibility", title: "Accessibility permission", words: "izin aksesibilitas privacy control", symbol: "hand.raised.fill", pane: "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"),
        Entry(id: "privacy-screen", title: "Screen Recording permission", words: "izin rekam layar screen capture privacy", symbol: "record.circle", pane: "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"),
        Entry(id: "privacy-automation", title: "Automation permission", words: "izin automation applescript privacy", symbol: "gearshape.2.fill", pane: "com.apple.settings.PrivacySecurity.extension?Privacy_Automation"),
        Entry(id: "desktop", title: "Desktop & Dock", words: "dock desktop mission control stage manager hot corners sudut", symbol: "dock.rectangle", pane: "com.apple.Desktop-Settings.extension"),
        Entry(id: "wallpaper", title: "Wallpaper", words: "latar background gambar", symbol: "photo.fill", pane: "com.apple.Wallpaper-Settings.extension"),
        Entry(id: "screensaver", title: "Screen Saver", words: "screensaver", symbol: "sparkles.tv", pane: "com.apple.ScreenSaver-Settings.extension"),
        Entry(id: "lockscreen", title: "Lock Screen", words: "kunci layar sleep tidur password", symbol: "lock.fill", pane: "com.apple.Lock-Screen-Settings.extension"),
        Entry(id: "touchid", title: "Touch ID & Password", words: "sidik jari fingerprint kata sandi", symbol: "touchid", pane: "com.apple.Touch-ID-Settings.extension"),
        Entry(id: "users", title: "Users & Groups", words: "pengguna akun account", symbol: "person.2.fill", pane: "com.apple.Users-Groups-Settings.extension"),
        Entry(id: "passwords", title: "Passwords", words: "kata sandi keychain", symbol: "key.fill", pane: "com.apple.Passwords-Settings.extension"),
        Entry(id: "keyboard", title: "Keyboard", words: "papan ketik shortcuts pintasan dictation dikte input source", symbol: "keyboard", pane: "com.apple.Keyboard-Settings.extension"),
        Entry(id: "trackpad", title: "Trackpad", words: "gestures gerakan klik tap scroll", symbol: "rectangle.and.hand.point.up.left.fill", pane: "com.apple.Trackpad-Settings.extension"),
        Entry(id: "mouse", title: "Mouse", words: "tetikus scroll pointer", symbol: "computermouse.fill", pane: "com.apple.Mouse-Settings.extension"),
        Entry(id: "printers", title: "Printers & Scanners", words: "printer cetak scanner pemindai", symbol: "printer.fill", pane: "com.apple.Print-Scan-Settings.extension"),
        Entry(id: "timemachine", title: "Time Machine", words: "backup cadangan", symbol: "clock.arrow.circlepath", pane: "com.apple.Time-Machine-Settings.extension"),
    ]

    /// DyskLink's own pages.
    static let dysklink: [Entry] = [
        Entry(id: "dl-advanced", title: "DyskLink Advanced", words: "tools alat settings pengaturan dysklink", symbol: "slider.horizontal.3", pane: nil),
        Entry(id: "dl-general", title: "DyskLink General settings", words: "open at login menu bar updates pembaruan", symbol: "gearshape.fill", pane: nil),
        Entry(id: "dl-productivity", title: "DyskLink Productivity tools", words: "clipboard history launcher keep awake other macs", symbol: "bolt.fill", pane: nil),
        Entry(id: "dl-windows", title: "DyskLink Window tools", words: "window layout previews jendela snap", symbol: "macwindow", pane: nil),
        Entry(id: "dl-screen", title: "DyskLink Screen tools", words: "brightness volume mouse system monitor kecerahan", symbol: "display", pane: nil),
        Entry(id: "dl-notch", title: "DyskLink Notch settings", words: "notch music lirik lyrics pomodoro prayer weather", symbol: "rectangle.topthird.inset.filled", pane: nil),
        Entry(id: "dl-charge", title: "DyskLink Charge control", words: "battery baterai charge limit top up pengisian daya low power", symbol: "battery.100percent.bolt", pane: nil),
        Entry(id: "dl-care", title: "DyskLink Mac care", words: "cleaner pembersih uninstall startup", symbol: "sparkles", pane: nil),
    ]

    static var all: [Entry] { system + dysklink }

    static func url(_ pane: String) -> URL? { URL(string: "x-apple.systempreferences:\(pane)") }

    @MainActor
    static func open(_ entry: Entry) {
        if let pane = entry.pane {
            if let url = url(pane) { NSWorkspace.shared.open(url) }
            return
        }
        let model = Shared.model
        model.showsHistory = false
        switch entry.id {
        case "dl-charge", "dl-care":
            model.showsTools = false
            model.showsCare = true
            if entry.id == "dl-charge" { Shared.care.tab = .battery }
        default:
            model.showsCare = false
            model.showsTools = true
            let category: AdvancedCategory = switch entry.id {
            case "dl-general": .general
            case "dl-productivity": .productivity
            case "dl-windows": .windows
            case "dl-screen": .screen
            case "dl-notch": .notch
            default: .overview
            }
            AdvancedLayout.shared.category = category
        }
        MainWindow.show()
    }
}
