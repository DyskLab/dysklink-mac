import Foundation
import Observation
import SwiftUI

struct LyricLine: Equatable {
    var time: TimeInterval
    var text: String
}

/// Lyrics from LRCLIB (lrclib.net), an open lyrics database with timed lines and no API key.
/// Spotify and YouTube have no public lyrics API, so the song's title and artist are looked up there instead.
enum LyricsParser {
    /// Reads `[mm:ss.xx] text` lines. A line can carry several times.
    static func parse(_ lrc: String) -> [LyricLine] {
        var result: [LyricLine] = []
        let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = tag.matches(in: raw, range: range)
            guard let last = matches.last, let end = Range(last.range, in: raw) else { continue }
            let text = raw[end.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                func group(_ index: Int) -> String? {
                    Range(match.range(at: index), in: raw).map { String(raw[$0]) }
                }
                guard let minutes = group(1).flatMap(Double.init), let seconds = group(2).flatMap(Double.init) else { continue }
                var fraction = 0.0
                if let digits = group(3), let value = Double(digits) { fraction = value / pow(10, Double(digits.count)) }
                result.append(LyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// The line being sung at `elapsed`, or nil before the first one.
    static func index(in lines: [LyricLine], at elapsed: TimeInterval) -> Int? {
        lines.lastIndex { $0.time <= elapsed + 0.25 }
    }

    /// The artist and title to look up. YouTube's artist line is "Channel · YouTube in Firefox", so the place is
    /// dropped, the channel loses "VEVO" and " - Topic", and a video titled "Artist - Song" is split instead.
    static func song(for playing: NowPlaying) -> (artist: String, title: String) {
        var parts = playing.artist.components(separatedBy: " · ")
        guard let place = parts.last, place.hasPrefix("YouTube") else { return split(title: playing.title, artist: playing.artist) }
        parts.removeLast()
        let channel = cleanChannel(parts.joined(separator: " · "))
        if place.hasPrefix("YouTube Music") { return split(title: playing.title, artist: channel) }
        let fromTitle = split(title: playing.title, artist: "")
        if !fromTitle.artist.isEmpty { return fromTitle }
        return (channel, fromTitle.title)
    }

    static func cleanChannel(_ name: String) -> String {
        name.replacingOccurrences(of: #"\s*-\s*Topic$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*VEVO$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(Official|Music|Official Music)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Artist - Song (Official Video) [HD]" becomes ("Artist", "Song"), for YouTube titles with no artist.
    static func split(title: String, artist: String) -> (artist: String, title: String) {
        let cleaned = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\|.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(Official\s+)?(Music\s+|Lyric\s+)?(Video|Audio|MV|Lyrics?)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+(ft\.?|feat\.?)\s.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        if !artist.isEmpty { return (artist, cleaned) }
        for separator in [" - ", " – ", " — "] {
            let parts = cleaned.components(separatedBy: separator)
            if parts.count >= 2 {
                return (parts[0].trimmingCharacters(in: .whitespaces), parts.dropFirst().joined(separator: separator).trimmingCharacters(in: .whitespaces))
            }
        }
        return ("", cleaned)
    }
}

@MainActor
@Observable
final class LyricsModel {
    enum State: Equatable {
        case idle, loading, notFound, failed
        case timed([LyricLine])
        case plain([String])
    }

    /// Off by default, because it sends the song's title and artist to lrclib.net.
    var isOn: Bool {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "notch.lyrics")
            if !isOn { state = .idle; key = nil }
        }
    }
    private(set) var state = State.idle {
        didSet {
            romanState = Self.romanized(state)
            lastLine = nil
            lastElapsed = nil
        }
    }
    @ObservationIgnored private var lastLine: Int?
    @ObservationIgnored private var lastElapsed: TimeInterval?

    /// The line to highlight. Small steps back from a corrected position, or a moment without one, keep the line
    /// where it is, so the lyrics don't hop up and down; a real seek back of more than two seconds still moves it.
    func line(in lines: [LyricLine], at elapsed: TimeInterval?) -> Int? {
        guard let elapsed else { return lastLine }
        let found = LyricsParser.index(in: lines, at: elapsed)
        if let found, let lastLine, let lastElapsed, found < lastLine, lastElapsed - elapsed < 2 {
            return lastLine
        }
        lastLine = found
        lastElapsed = elapsed
        return found
    }
    /// The same lyrics in Latin letters, or nil when they already are.
    @ObservationIgnored private var romanState: State?
    /// Shows Japanese, Korean, or Chinese lyrics in Latin letters (romaji), made on this Mac.
    var romanizes: Bool {
        didSet { UserDefaults.standard.set(romanizes, forKey: "notch.lyricsRomaji") }
    }
    var canRomanize: Bool { romanState != nil }
    /// What the lyrics column shows.
    var shown: State { romanizes ? romanState ?? state : state }

    nonisolated static func romanized(_ state: State) -> State? {
        switch state {
        case .timed(let lines):
            guard lines.contains(where: { Romanizer.needs($0.text) }) else { return nil }
            let japanese = Romanizer.isJapanese(lines.map(\.text))
            return .timed(lines.map { LyricLine(time: $0.time, text: Romanizer.romanize($0.text, japanese: japanese)) })
        case .plain(let lines):
            guard lines.contains(where: Romanizer.needs) else { return nil }
            let japanese = Romanizer.isJapanese(lines)
            return .plain(lines.map { Romanizer.romanize($0, japanese: japanese) })
        default:
            return nil
        }
    }
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var cache: [String: State] = [:]
    @ObservationIgnored private let isInert: Bool

    init(isInert: Bool = false) {
        self.isInert = isInert
        isOn = isInert ? false : UserDefaults.standard.bool(forKey: "notch.lyrics")
        romanizes = isInert ? false : UserDefaults.standard.bool(forKey: "notch.lyricsRomaji")
    }

    /// Looks up the song once. Later calls for the same song reuse the answer.
    func load(for playing: NowPlaying?) async {
        guard isOn, !isInert, let playing, !playing.title.isEmpty else { return }
        let song = LyricsParser.song(for: playing)
        let key = "\(song.artist.lowercased())|\(song.title.lowercased())"
        guard key != self.key else { return }
        self.key = key
        if let cached = cache[key] { state = cached; return }
        state = .loading
        let result = await Self.fetch(artist: song.artist, title: song.title, duration: playing.duration)
        guard self.key == key else { return }
        if result != .failed { cache[key] = result }
        state = result
    }

    #if DEBUG
    func loadForSnapshot(_ state: State) {
        self.state = state
    }
    #endif

    nonisolated private static func fetch(artist: String, title: String, duration: TimeInterval?) async -> State {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let duration { exact.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        // With the artist first, then the title alone, since a YouTube channel isn't always the artist.
        let queries = Array(NSOrderedSet(array: [[artist, title].filter { !$0.isEmpty }.joined(separator: " "), title])) as? [String] ?? [title]

        struct Item: Decodable {
            let syncedLyrics: String?
            let plainLyrics: String?
            let instrumental: Bool?
            let duration: Double?
        }
        /// A result about as long as the song comes first; a video can run a little longer with its intro.
        func ranked(_ items: [Item]) -> [Item] {
            guard let duration else { return items }
            let close = items.filter { $0.duration.map { abs($0 - duration) <= 8 } ?? false }
            return close + items.filter { item in !close.contains { $0.duration == item.duration && $0.syncedLyrics == item.syncedLyrics } }
        }
        func state(_ item: Item) -> State? {
            if let synced = item.syncedLyrics, case let lines = LyricsParser.parse(synced), !lines.isEmpty { return .timed(lines) }
            if let plain = item.plainLyrics, !plain.isEmpty {
                return .plain(plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
            }
            return nil
        }
        do {
            if !artist.isEmpty, let url = exact.url {
                let (data, response) = try await URLSession.shared.data(for: request(url))
                if (response as? HTTPURLResponse)?.statusCode == 200, let item = try? JSONDecoder().decode(Item.self, from: data),
                   let found = state(item) { return found }
            }
            for query in queries where !query.isEmpty {
                var search = URLComponents(string: "https://lrclib.net/api/search")!
                search.queryItems = [URLQueryItem(name: "q", value: query)]
                guard let url = search.url else { continue }
                let (data, response) = try await URLSession.shared.data(for: request(url))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
                let items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []
                if let found = ranked(items).lazy.compactMap(state).first { return found }
            }
            return .notFound
        } catch {
            return .failed
        }
    }

    nonisolated private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 12)
        // LRCLIB asks clients to name themselves.
        request.setValue("DyskLink (https://github.com/DyskLab/dysklink-mac)", forHTTPHeaderField: "User-Agent")
        return request
    }
}

/// The lyrics column beside the player. Timed lyrics follow the song when its position is known.
struct LyricsColumn: View {
    let lyrics: LyricsModel
    let elapsed: TimeInterval?

    var body: some View {
        Group {
            switch lyrics.shown {
            case .idle, .loading:
                note("Looking for lyrics…")
            case .notFound:
                note("No lyrics found for this song")
            case .failed:
                note("Couldn't reach lrclib.net")
            case .timed(let lines):
                timed(lines)
            case .plain(let lines):
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if lyrics.canRomanize {
                Button { lyrics.romanizes.toggle() } label: {
                    Text(lyrics.romanizes ? "Original" : "Romaji")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(lyrics.romanizes ? Color.black : Color.white)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(lyrics.romanizes ? Color.white : Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(lyrics.romanizes ? "Show the lyrics as written" : "Show the lyrics in Latin letters")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The current line in white with two before and three after it, so it reads like a karaoke screen.
    private func timed(_ lines: [LyricLine]) -> some View {
        let current = lyrics.line(in: lines, at: elapsed)
        let center = current ?? 0
        // One line before and three after, so the current line has room for two rows.
        let range = max(0, center - 1)...min(lines.count - 1, center + 3)
        return VStack(alignment: .leading, spacing: 5) {
            if elapsed == nil, current == nil {
                Text("The song position isn't known, so the lines don't move. Turn on song position in Advanced › Notch › Music, or use the Firefox extension.")
                    .font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.4))
            }
            ForEach(Array(range), id: \.self) { index in
                Text(lines[index].text.isEmpty ? "♪" : lines[index].text)
                    .font(.system(size: index == current ? 14.5 : 12.5, weight: index == current ? .bold : .regular))
                    .foregroundStyle(Color.white.opacity(index == current ? 1 : 0.45))
                    // Long lines shrink a little and the current one wraps, instead of ending in "…".
                    .lineLimit(index == current ? 2 : 1)
                    .minimumScaleFactor(index == current ? 0.8 : 0.7)
                    // Fixed heights, so a line that wraps doesn't push the others around.
                    .frame(height: index == current ? 38 : 17, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.25), value: current)
    }
}

/// Turns Japanese, Korean, Chinese, and other non-Latin lyrics into Latin letters, on this Mac.
/// Japanese is read word by word with the system's Japanese dictionary, so kanji get their real reading.
enum Romanizer {
    static func isKana(_ scalar: Unicode.Scalar) -> Bool { (0x3040...0x30FF).contains(scalar.value) }

    /// Anything outside Latin letters, punctuation, and symbols.
    static func needs(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic && !$0.isASCII && !(0x00C0...0x024F).contains($0.value) }
    }

    /// Whether a song reads as Japanese: kanji-only lines in it are then read as Japanese, not Chinese.
    static func isJapanese(_ lines: [String]) -> Bool {
        lines.contains { $0.unicodeScalars.contains(where: isKana) }
    }

    static func romanize(_ text: String, japanese: Bool) -> String {
        guard needs(text) else { return text }
        let result = japanese ? romanizeJapanese(text) : transform(text)
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func transform(_ text: String) -> String {
        let value = NSMutableString(string: text)
        CFStringTransform(value, nil, kCFStringTransformToLatin, false)
        return value as String
    }

    private static let punctuation: [String: String] = [
        "、": ",", "，": ",", "。": ".", "！": "!", "？": "?", "「": "\"", "」": "\"", "『": "\"", "』": "\"",
        "（": "(", "）": ")", "・": " ", "〜": "~", "～": "~", "…": "…", "　": " ", "､": ",", "｡": ".",
    ]

    private static func romanizeJapanese(_ text: String) -> String {
        let ns = text as NSString
        guard let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: ns.length),
                                                      kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        else { return transform(text) }
        var words: [String] = []
        var last = 0
        /// The small っ comes back as "~tsu" and doubles the next word's first consonant.
        var doubles = false
        func add(_ word: String, attach: Bool = false) {
            var word = word
            if doubles, let first = word.first, first.isLetter, !"aeiou".contains(first) {
                word = String(first) + word
                if let previous = words.last { words[words.count - 1] = previous; words[words.count - 1] += word; doubles = false; return }
            }
            doubles = false
            if word.hasSuffix("~tsu") {
                word.removeLast(4)
                doubles = true
            }
            word = word.replacingOccurrences(of: "~", with: "")
            if attach, let previous = words.popLast() { words.append(previous + word) } else { words.append(word) }
        }
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > last { words.append(" ") }
            last = range.location + range.length
            let token = ns.substring(with: NSRange(location: range.location, length: range.length))
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if let mark = punctuation[token] { add(mark, attach: mark != "\"" && mark != "("); continue }
            guard needs(token) else { add(token); continue }
            if token == "は" { add("wa"); continue }
            if token == "へ" { add("e"); continue }
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            add(latin ?? transform(token))
        }
        if doubles, let previous = words.popLast() { words.append(previous + "tsu") }
        return words.filter { $0 != " " }.joined(separator: " ")
            .replacingOccurrences(of: #" ([,.!?)\]])"#, with: "$1", options: .regularExpression)
    }
}
