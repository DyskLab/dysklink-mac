import Foundation

/// Search for phone contacts and SMS. Ignores case and accents, matches the start of each word in a name,
/// and treats 0812…, 62812… and +62 812-… as the same number.
enum PhoneSearch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func digits(_ text: String) -> String { String(text.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init)) }

    /// The number without 0 or 62 in front, so local and international forms compare equal.
    static func national(_ number: String) -> String {
        let all = digits(number)
        if all.hasPrefix("62") { return String(all.dropFirst(2)) }
        if all.hasPrefix("0") { return String(all.dropFirst()) }
        return all
    }

    /// True when the query is only a number, like "0812 34" or "+62-812".
    static func isNumber(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isNumber || " +-()./".contains($0) } && !digits(trimmed).isEmpty
    }

    static func numberMatches(_ query: String, _ number: String) -> Bool {
        let typed = digits(query)
        guard !typed.isEmpty else { return false }
        if digits(number).contains(typed) { return true }
        let short = national(query)
        return !short.isEmpty && national(number).contains(short)
    }

    private static func words(_ text: String) -> [Substring] {
        fold(text).split { !$0.isLetter && !$0.isNumber }
    }

    /// Lower is a better match; nil means no match. 0 for an empty query.
    static func score(name: String, numbers: [String], query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        if isNumber(trimmed) {
            return numbers.contains { numberMatches(trimmed, $0) } ? 3 : nil
        }
        let wanted = words(trimmed)
        guard !wanted.isEmpty else { return nil }
        let folded = fold(name)
        let parts = words(name)
        if folded.hasPrefix(fold(trimmed)) { return 0 }
        if wanted.allSatisfy({ word in parts.contains { $0.hasPrefix(word) } }) { return 1 }
        // One or two letters would match almost everyone in the middle of a word, so only word starts count then.
        if trimmed.count > 2, wanted.allSatisfy({ folded.contains($0) }) { return 2 }
        return nil
    }

    /// Every word of the query appears somewhere in the text.
    static func textMatches(_ text: String, _ query: String) -> Bool {
        let wanted = words(query)
        guard !wanted.isEmpty else { return false }
        let folded = fold(text)
        return wanted.allSatisfy { folded.contains($0) }
    }

    /// Contacts that match, best first, then by name.
    static func contacts(_ contacts: [ContactItem], query: String) -> [ContactItem] {
        var found: [(contact: ContactItem, score: Int)] = []
        for contact in contacts {
            if let value = score(name: contact.name, numbers: contact.phones, query: query) { found.append((contact, value)) }
        }
        found.sort { first, second in
            if first.score != second.score { return first.score < second.score }
            return first.contact.name.localizedStandardCompare(second.contact.name) == .orderedAscending
        }
        return found.map { $0.contact }
    }

    /// Up to two letters for an avatar: "Budi Santoso" → "BS", "+62812" → "#".
    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").compactMap { $0.first(where: \.isLetter) }.prefix(2)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }

    /// The letter a contact is listed under.
    static func section(_ name: String) -> String {
        guard let first = fold(name).first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
        return first.isLetter && first.isASCII ? String(first).uppercased() : "#"
    }
}
