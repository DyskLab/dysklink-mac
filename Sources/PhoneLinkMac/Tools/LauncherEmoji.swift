import Foundation

/// Emoji for the Launcher, found by their Unicode name in English or by common Indonesian words.
/// Besides single emoji: every country flag (by English and Indonesian name), common joined emoji such as families
/// and jobs, and skin tones by adding a tone word (terang, langsat, sawo, cokelat, gelap, or tone1 to tone5).
enum LauncherEmoji {
    struct Entry: Hashable {
        let emoji: String
        /// The Unicode name in lower case, such as "smiling face with sunglasses".
        let name: String
        let words: [String]
    }

    static let all: [Entry] = build()

    /// Common Indonesian (and a few English) words that the Unicode names don't contain.
    static let aliases: [String: [String]] = [
        "senyum": ["😊", "🙂", "😄", "😁"], "tawa": ["😂", "🤣", "😆"], "ketawa": ["😂", "🤣", "😆"], "ngakak": ["🤣", "😂"],
        "lol": ["😂", "🤣"], "wkwk": ["🤣", "😂"], "sedih": ["😢", "😭", "😞", "🥺"], "nangis": ["😭", "😢"], "menangis": ["😭", "😢"],
        "marah": ["😡", "😠", "🤬"], "kesal": ["😤", "😒"], "kaget": ["😮", "😱", "😲"], "takut": ["😨", "😱"], "malu": ["😳", "☺️"],
        "ngantuk": ["😴", "🥱"], "tidur": ["😴", "💤"], "bingung": ["😕", "🤔", "😵‍💫"], "mikir": ["🤔"], "pikir": ["🤔"],
        "keren": ["😎", "🔥"], "cium": ["😘", "😚"], "sayang": ["🥰", "❤️", "😘"], "cinta": ["❤️", "😍", "🥰", "💕"], "love": ["❤️", "😍", "🥰"],
        "hati": ["❤️", "💖", "💕"], "heart": ["❤️"], "merah": ["❤️", "🔴"], "red": ["❤️", "🔴"], "patah": ["💔"], "sakit": ["🤒", "🤕", "😷"], "muntah": ["🤮"], "mual": ["🤢"],
        "setan": ["😈", "👿"], "hantu": ["👻"], "tengkorak": ["💀"], "mati": ["💀"], "badut": ["🤡"], "alien": ["👽"],
        "jempol": ["👍"], "mantap": ["👍", "🔥", "💯"], "oke": ["👌", "👍"], "ok": ["👌", "👍"], "tepuk": ["👏"], "salam": ["🙏", "👋"],
        "doa": ["🙏", "🤲"], "terima": ["🙏"], "makasih": ["🙏"], "thanks": ["🙏"], "lambai": ["👋"], "dadah": ["👋"], "halo": ["👋"],
        "kuat": ["💪"], "otot": ["💪"], "tunjuk": ["👉", "👆", "👇", "👈"], "mata": ["👀"], "lihat": ["👀"], "diam": ["🤫"],
        "api": ["🔥"], "panas": ["🔥", "🥵"], "dingin": ["🥶", "❄️"], "bintang": ["⭐", "🌟"], "bulan": ["🌙"], "matahari": ["☀️"],
        "hujan": ["🌧️", "☔"], "awan": ["☁️"], "petir": ["⚡"], "pelangi": ["🌈"], "salju": ["❄️"], "bunga": ["🌸", "🌹", "🌺", "🌻"],
        "pohon": ["🌳", "🌴"], "daun": ["🍃", "🍂"], "kucing": ["🐱", "🐈"], "anjing": ["🐶", "🐕"], "ikan": ["🐟", "🐠"],
        "burung": ["🐦"], "ayam": ["🐔", "🍗"], "sapi": ["🐄"], "kopi": ["☕"], "teh": ["🍵"], "makan": ["🍽️", "🍚", "🍜"],
        "nasi": ["🍚", "🍛"], "mie": ["🍜"], "roti": ["🍞"], "kue": ["🍰", "🎂"], "ulang": ["🎂", "🎉"], "tahun": ["🎂"],
        "pesta": ["🎉", "🥳"], "selamat": ["🎉", "🥳", "👏"], "kado": ["🎁"], "hadiah": ["🎁"], "balon": ["🎈"], "uang": ["💰", "💵", "💸"],
        "duit": ["💰", "💸"], "rumah": ["🏠"], "kantor": ["🏢"], "sekolah": ["🏫"], "masjid": ["🕌"], "mobil": ["🚗"], "motor": ["🏍️", "🛵"],
        "pesawat": ["✈️"], "kereta": ["🚆"], "kapal": ["🚢"], "roket": ["🚀"], "centang": ["✅", "✔️"], "benar": ["✅"], "silang": ["❌"],
        "salah": ["❌"], "awas": ["⚠️"], "peringatan": ["⚠️"], "jam": ["⏰", "🕐"], "waktu": ["⏰", "⌛"], "telepon": ["📞", "📱"],
        "hp": ["📱"], "laptop": ["💻"], "buku": ["📖", "📚"], "musik": ["🎵", "🎶"], "lagu": ["🎵"], "foto": ["📷"], "kamera": ["📷"],
        "surat": ["✉️", "📧"], "kunci": ["🔑", "🔒"], "lampu": ["💡"], "ide": ["💡"], "seratus": ["💯"], "bola": ["⚽"], "game": ["🎮"],
        "baterai": ["🔋"], "bendera": ["🚩", "🏁"], "indonesia": ["🇮🇩"], "pin": ["📌"], "catatan": ["📝"],
    ]

    private static func build() -> [Entry] {
        let ranges: [ClosedRange<UInt32>] = [0x2190...0x21FF, 0x2300...0x23FF, 0x2460...0x27BF, 0x2900...0x297F, 0x2B00...0x2BFF,
                                            0x3030...0x303D, 0x3297...0x3299, 0x1F000...0x1F2FF, 0x1F300...0x1FAFF]
        var result: [Entry] = []
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value) else { continue }
                let p = scalar.properties
                guard p.isEmoji, !p.isEmojiModifier, !(0x1F1E6...0x1F1FF).contains(value), let name = p.name?.lowercased() else { continue }
                // Ones drawn as text by default need the emoji variation selector to show in color.
                let emoji = p.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                result.append(Entry(emoji: emoji, name: name, words: name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)))
            }
        }
        result += flags()
        result += joined.map { emoji, name, extra in
            Entry(emoji: emoji, name: name, words: (name + " " + extra).split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init))
        }
        return result
    }

    /// A flag is two regional letters. Each one is found by its code, its English name, and its Indonesian name.
    static func flags() -> [Entry] {
        let english = Locale(identifier: "en"), indonesian = Locale(identifier: "id")
        return Locale.Region.isoRegions.compactMap { region in
            let code = region.identifier
            guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }),
                  let name = english.localizedString(forRegionCode: code) else { return nil }
            let flag = String(String.UnicodeScalarView(code.uppercased().unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
            let local = indonesian.localizedString(forRegionCode: code) ?? ""
            let words = ("flag bendera " + name + " " + local + " " + code).lowercased()
                .split(whereSeparator: { " -,.()’'".contains($0) }).map(String.init)
            return Entry(emoji: flag, name: "flag \(name.lowercased())", words: words)
        }
    }

    /// Emoji made of several joined together, which the single-emoji list can't find. Name, then extra search words.
    static let joined: [(String, String, String)] = [
        ("👨‍👩‍👧", "family man woman girl", "keluarga anak"), ("👨‍👩‍👦", "family man woman boy", "keluarga anak"),
        ("👨‍👩‍👧‍👦", "family man woman girl boy", "keluarga anak"), ("👨‍👩‍👦‍👦", "family man woman boy boy", "keluarga anak"),
        ("👨‍👩‍👧‍👧", "family man woman girl girl", "keluarga anak"), ("👩‍👧", "family woman girl", "keluarga ibu anak"),
        ("👨‍👧", "family man girl", "keluarga ayah anak"), ("👩‍👦", "family woman boy", "keluarga ibu anak"),
        ("👨‍👦", "family man boy", "keluarga ayah anak"), ("🧑‍🧑‍🧒", "family adult adult child", "keluarga anak"),
        ("👩‍❤️‍👨", "couple with heart woman man", "pasangan cinta"), ("👩‍❤️‍💋‍👨", "kiss woman man", "pasangan cium"),
        ("🧑‍💻", "technologist", "programmer coding komputer developer"), ("👨‍💻", "man technologist", "programmer coding komputer developer"),
        ("👩‍💻", "woman technologist", "programmer coding komputer developer"), ("🧑‍🍳", "cook", "koki masak chef"),
        ("🧑‍⚕️", "health worker", "dokter perawat"), ("👨‍⚕️", "man health worker", "dokter"), ("👩‍⚕️", "woman health worker", "dokter perawat"),
        ("🧑‍🏫", "teacher", "guru dosen"), ("🧑‍🎓", "student", "siswa mahasiswa wisuda"), ("🧑‍🔧", "mechanic", "montir bengkel"),
        ("🧑‍🌾", "farmer", "petani"), ("🧑‍🎨", "artist", "seniman pelukis"), ("🧑‍🚀", "astronaut", "astronot"),
        ("🧑‍🚒", "firefighter", "pemadam kebakaran"), ("🧑‍✈️", "pilot", "pilot"), ("🧑‍💼", "office worker", "karyawan kantor"),
        ("🧑‍🔬", "scientist", "ilmuwan"), ("🧑‍🎤", "singer", "penyanyi"), ("👮‍♂️", "man police officer", "polisi"),
        ("👮‍♀️", "woman police officer", "polisi polwan"), ("🧕", "woman with headscarf", "hijab jilbab kerudung"),
        ("🏳️‍🌈", "rainbow flag", "bendera pelangi pride"), ("🏴‍☠️", "pirate flag", "bendera bajak laut"),
        ("❤️‍🔥", "heart on fire", "hati api cinta"), ("❤️‍🩹", "mending heart", "hati sembuh"),
        ("😮‍💨", "face exhaling", "lega hela napas"), ("😶‍🌫️", "face in clouds", "bingung awan"), ("😵‍💫", "face with spiral eyes", "pusing bingung"),
        ("🐈‍⬛", "black cat", "kucing hitam"), ("🐕‍🦺", "service dog", "anjing"), ("🐻‍❄️", "polar bear", "beruang kutub"),
        ("🧑‍🤝‍🧑", "people holding hands", "teman bergandengan"), ("🙋‍♂️", "man raising hand", "angkat tangan"),
        ("🙋‍♀️", "woman raising hand", "angkat tangan"), ("🤷‍♂️", "man shrugging", "entah bodo"), ("🤷‍♀️", "woman shrugging", "entah bodo"),
        ("🤦‍♂️", "man facepalming", "tepok jidat"), ("🤦‍♀️", "woman facepalming", "tepok jidat"), ("🏃‍♂️", "man running", "lari"),
        ("🚶‍♂️", "man walking", "jalan"), ("🧘‍♀️", "woman in lotus position", "yoga meditasi"),
    ]

    // MARK: Skin tones

    /// Tone words, lightest first. The tone goes on emoji of people and hands.
    static let toneWords: [String: Int] = [
        "tone1": 1, "terang": 1, "tone2": 2, "langsat": 2, "tone3": 3, "sawo": 3, "tone4": 4, "cokelat": 4, "coklat": 4, "tone5": 5, "gelap": 5,
        "tone0": 0, "kuning": 0,
    ]
    private static let toneKey = "launcher.emojiTone"

    /// The last tone typed, used until another one is typed. 0 is the plain yellow.
    static var tone: Int {
        get { min(max(UserDefaults.standard.integer(forKey: toneKey), 0), 5) }
        set { UserDefaults.standard.set(newValue, forKey: toneKey) }
    }

    /// Takes a tone word out of the query. Returns the query left and the tone, if one was typed.
    static func splitTone(_ query: String) -> (String, Int?) {
        var tone: Int?
        let rest = query.split(separator: " ").filter { word in
            if let found = toneWords[word.lowercased()] { tone = found; return false }
            return true
        }
        return (rest.joined(separator: " "), tone)
    }

    /// The emoji with a skin tone. Only one person can take it; families and couples stay as they are.
    static func toned(_ emoji: String, _ tone: Int) -> String {
        guard (1...5).contains(tone), let modifier = Unicode.Scalar(0x1F3FA + UInt32(tone)) else { return emoji }
        let scalars = Array(emoji.unicodeScalars)
        guard scalars.filter({ $0.properties.isEmojiModifierBase }).count == 1,
              !scalars.contains(where: { $0.properties.isEmojiModifier }) else { return emoji }
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            out.append(scalar)
            if scalar.properties.isEmojiModifierBase {
                out.append(modifier)
                // The tone replaces the variation selector.
                if index + 1 < scalars.count, scalars[index + 1].value == 0xFE0F { index += 1 }
            }
            index += 1
        }
        return String(out)
    }

    /// Emoji matching every word typed, best first. Aliases come before name matches.
    static func search(_ query: String, limit: Int = 40) -> [Entry] {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        var scores: [String: Int] = [:]
        var aliasOrder: [String] = []
        if terms.count == 1 {
            for (word, list) in aliases where word.hasPrefix(terms[0]) {
                for (index, emoji) in list.enumerated() {
                    let score = (word == terms[0] ? 300 : 200) - index
                    if score > scores[normalized(emoji), default: 0] { scores[normalized(emoji)] = score }
                    aliasOrder.append(normalized(emoji))
                }
            }
        }
        for entry in all {
            guard terms.allSatisfy({ term in entry.words.contains { $0.hasPrefix(term) } }) else { continue }
            var score = 100
            if entry.name == terms.joined(separator: " ") { score += 60 }
            if entry.words.first?.hasPrefix(terms[0]) == true { score += 20 }
            if terms.allSatisfy({ entry.words.contains($0) }) { score += 15 }
            score -= entry.words.count
            // Ones that are always colorful are the ones people usually mean.
            if !entry.emoji.hasSuffix("\u{FE0F}") { score += 5 }
            let key = normalized(entry.emoji)
            scores[key] = max(scores[key] ?? 0, score)
        }
        let byKey = Dictionary(all.map { (normalized($0.emoji), $0) }, uniquingKeysWith: { a, _ in a })
        return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { key, _ in byKey[key] ?? Entry(emoji: key, name: aliasName(key), words: []) }
    }

    static func entry(for emoji: String) -> Entry {
        let key = normalized(emoji)
        return all.first { normalized($0.emoji) == key } ?? Entry(emoji: emoji, name: aliasName(emoji), words: [])
    }

    /// The same emoji with or without the variation selector counts as one.
    private static func normalized(_ emoji: String) -> String {
        let scalars = emoji.unicodeScalars.filter { $0.value != 0xFE0F }
        let base = String(String.UnicodeScalarView(scalars))
        return scalars.count == 1 && !(scalars.first!.properties.isEmojiPresentation) ? base + "\u{FE0F}" : base
    }

    private static func aliasName(_ emoji: String) -> String {
        aliases.filter { $0.value.contains(emoji) }.keys.sorted().prefix(3).joined(separator: ", ")
    }

    // MARK: Recent

    private static let recentKey = "launcher.emojiRecent"

    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    static func used(_ emoji: String) {
        var list = recent.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(24)), forKey: recentKey)
    }

    /// Shown before anything is typed: recent ones, then favourites.
    static let starters = ["😂", "❤️", "👍", "🙏", "😊", "🔥", "😭", "🥰", "😎", "🎉", "✅", "👀", "🤔", "😅", "👏", "💯"]
}
