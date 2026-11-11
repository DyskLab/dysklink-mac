import AppKit

/// Finds a one-time code (OTP) in an SMS or notification, such as "Kode OTP Anda 482915".
enum OneTimeCode {
    /// Words that come with a code, in English and Indonesian.
    static let keywords = ["otp", "kode", "code", "verif", "sandi", "password", "passcode", "pin", "token", "one-time",
                           "sekali pakai", "2fa", "authenticat", "autentikasi", "masuk", "login", "sign in", "konfirmasi", "confirm"]

    static func find(in text: String) -> String? {
        let lower = text.lowercased()
        guard keywords.contains(where: lower.contains) else { return nil }
        // 4–8 digits, or two groups of three like 123-456. Not part of a longer number, amount, date, or time.
        let pattern = #"(?<![\d+])(?<!\d[.,:/\-])(\d{3}[- ]\d{3}|\d{4,8})(?!\d|[.,:/\-]\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = lower as NSString
        var best: (code: String, score: Int)?
        for match in regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range(at: 1)
            let before = ns.substring(to: range.location)
            let near = String(before.suffix(5)).replacingOccurrences(of: " ", with: "")
            // Money and phone numbers.
            if ["rp", "idr", "$", "usd", "+"].contains(where: near.hasSuffix) { continue }
            let code = ns.substring(with: range).filter(\.isNumber)
            var score = code.count == 6 ? 3 : 1
            if keywords.contains(where: String(before.suffix(40)).contains) { score += 2 }
            // A year like 2026 on its own is rarely the code.
            if code.count == 4, code.hasPrefix("19") || code.hasPrefix("20") { score -= 2 }
            if score > (best?.score ?? 0) { best = (code, score) }
        }
        return best?.code
    }

    /// Copies the code without it going to the clipboard history or to the phones.
    static func copy(_ code: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(code, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}

/// A code shown under the notch with a Copy button.
struct CodeNotice: Equatable {
    let code: String
    /// The app or sender, such as "BCA" or "Messages".
    let source: String
    let phone: String
    var copied = false
}
