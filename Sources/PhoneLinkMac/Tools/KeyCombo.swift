import AppKit
import Carbon.HIToolbox

/// A shortcut the user chose. Modifiers use Carbon's values, which is what global shortcuts need.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let historyDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | cmdKey))
    static let captureDefault = KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | cmdKey))

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G",
        kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N",
        kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U",
        kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6",
        kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "Del",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
    ]

    var isFunctionKey: Bool { Self.functionKeys[Int(keyCode)] != nil }

    /// Without Command, Control, or Option, a shortcut would take over normal typing.
    var isUsable: Bool {
        isFunctionKey || modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        let code = Int(keyCode)
        return text + (Self.functionKeys[code] ?? Self.names[code] ?? "Key \(code)")
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbon(event.modifierFlags)
    }

    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value = 0
        if flags.contains(.command) { value |= cmdKey }
        if flags.contains(.control) { value |= controlKey }
        if flags.contains(.option) { value |= optionKey }
        if flags.contains(.shift) { value |= shiftKey }
        return UInt32(value)
    }
}

/// Decides which copies never enter the history.
enum PasswordFilter {
    static let passwordApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.Passwords",
        "com.apple.keychainaccess", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc", "me.proton.pass.electron", "com.nordpass.macos.NordPass",
    ]

    /// One unbroken word of 8 or more characters that mixes at least three of lowercase, uppercase, numbers,
    /// and symbols. Links, email addresses, file paths, and UUIDs don't count.
    static func looksLikePassword(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...128).contains(value.count), !value.contains(where: \.isWhitespace) else { return false }
        if value.contains("://") || value.hasPrefix("/") || value.hasPrefix("~/") || value.hasPrefix("www.") { return false }
        if value.range(of: #"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil { return false }
        if value.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) != nil { return false }
        let classes = [
            value.contains(where: \.isLowercase),
            value.contains(where: \.isUppercase),
            value.contains(where: \.isNumber),
            value.contains { !$0.isLetter && !$0.isNumber },
        ].filter { $0 }.count
        return classes >= 3
    }
}
