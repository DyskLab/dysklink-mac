import Foundation
import Observation

enum Prayer: String, CaseIterable, Codable, Identifiable {
    case subuh, dzuhur, ashar, maghrib, isya
    var id: String { rawValue }
    var name: String {
        switch self {
        case .subuh: return "Subuh"
        case .dzuhur: return "Dzuhur"
        case .ashar: return "Ashar"
        case .maghrib: return "Maghrib"
        case .isya: return "Isya"
        }
    }
}

struct PrayerLocation: Codable, Equatable {
    var province: String
    var city: String

    var label: String { city.replacingOccurrences(of: "Kota ", with: "").replacingOccurrences(of: "Kab. ", with: "") }

    /// The schedule is in the local time of the place, whatever time zone this Mac is set to.
    var timeZone: TimeZone {
        let wita = ["Bali", "Nusa Tenggara Barat", "Nusa Tenggara Timur", "Kalimantan Selatan", "Kalimantan Tengah",
                    "Kalimantan Timur", "Kalimantan Utara", "Sulawesi Barat", "Sulawesi Selatan", "Sulawesi Tengah",
                    "Sulawesi Tenggara", "Sulawesi Utara", "Gorontalo"]
        let wit = ["Maluku", "Maluku Utara", "Papua", "Papua Barat"]
        let id = wit.contains(province) ? "Asia/Jayapura" : wita.contains(province) ? "Asia/Makassar" : "Asia/Jakarta"
        return TimeZone(identifier: id) ?? .current
    }
}

/// One day of times as "HH:mm" text, the way equran.id sends them.
struct PrayerDay: Codable, Equatable {
    var date: String
    var subuh: String
    var dzuhur: String
    var ashar: String
    var maghrib: String
    var isya: String

    func text(_ prayer: Prayer) -> String {
        switch prayer {
        case .subuh: return subuh
        case .dzuhur: return dzuhur
        case .ashar: return ashar
        case .maghrib: return maghrib
        case .isya: return isya
        }
    }
}

struct PrayerMonth: Codable, Equatable {
    var location: PrayerLocation
    var year: Int
    var month: Int
    var days: [PrayerDay]
}

/// The times of one day as real dates, with the one that comes next.
struct PrayerSchedule {
    let location: PrayerLocation
    let days: [String: PrayerDay]

    init(location: PrayerLocation, months: [PrayerMonth]) {
        self.location = location
        var all: [String: PrayerDay] = [:]
        for month in months where month.location == location {
            for day in month.days { all[day.date] = day }
        }
        days = all
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = location.timeZone
        return calendar
    }

    static func key(_ date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The five times of the day that `date` falls on, or nothing if that day isn't loaded.
    func times(on date: Date) -> [(prayer: Prayer, time: Date)]? {
        let calendar = calendar
        guard let day = days[Self.key(date, in: calendar)] else { return nil }
        let start = calendar.startOfDay(for: date)
        let times = Prayer.allCases.compactMap { prayer -> (Prayer, Date)? in
            let parts = day.text(prayer).split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2,
                  let time = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: start)
            else { return nil }
            return (prayer, time)
        }
        return times.count == Prayer.allCases.count ? times : nil
    }

    struct Upcoming {
        let prayer: Prayer
        let time: Date
        /// The time of the one before it, for the progress bar. Nil if that day isn't loaded.
        let previous: Date?
    }

    /// The next time after `now`, looking into tomorrow when today's are over.
    func upcoming(after now: Date) -> Upcoming? {
        let calendar = calendar
        guard let today = times(on: now) else { return nil }
        if let index = today.firstIndex(where: { $0.time > now }) {
            let previous = index > 0 ? today[index - 1].time
                : calendar.date(byAdding: .day, value: -1, to: now).flatMap { times(on: $0) }?.last?.time
            return Upcoming(prayer: today[index].prayer, time: today[index].time, previous: previous)
        }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).flatMap({ times(on: $0) })
        else { return nil }
        return Upcoming(prayer: tomorrow[0].prayer, time: tomorrow[0].time, previous: today.last?.time)
    }

    /// The alert due at `now`, if any: with `early`, the prayer ten minutes away; otherwise the one whose time has
    /// just come. Only within `window` seconds after the alert's moment, so a Mac that slept doesn't announce old times.
    func due(at now: Date, early: Bool, window: TimeInterval = 90) -> (prayer: Prayer, time: Date)? {
        func fresh(_ fireAt: Date) -> Bool { now >= fireAt && now.timeIntervalSince(fireAt) < window }
        if early {
            guard let next = upcoming(after: now), fresh(next.time.addingTimeInterval(-600)) else { return nil }
            return (next.prayer, next.time)
        }
        guard let passed = times(on: now)?.last(where: { $0.time <= now }), fresh(passed.time) else { return nil }
        return passed
    }
}

enum PrayerAPI {
    static let base = "https://equran.id/api/v2/shalat"

    private struct Reply<T: Decodable>: Decodable { let data: T }

    static func provinces(from data: Data) throws -> [String] {
        try JSONDecoder().decode(Reply<[String]>.self, from: data).data
    }

    static func cities(from data: Data) throws -> [String] {
        try JSONDecoder().decode(Reply<[String]>.self, from: data).data
    }

    static func month(from data: Data, location: PrayerLocation) throws -> PrayerMonth {
        struct Payload: Decodable {
            struct Day: Decodable {
                let tanggal_lengkap: String
                let subuh, dzuhur, ashar, maghrib, isya: String
            }
            let bulan: Int
            let tahun: Int
            let jadwal: [Day]
        }
        let payload = try JSONDecoder().decode(Reply<Payload>.self, from: data).data
        let days = payload.jadwal.map {
            PrayerDay(date: $0.tanggal_lengkap, subuh: $0.subuh, dzuhur: $0.dzuhur, ashar: $0.ashar,
                      maghrib: $0.maghrib, isya: $0.isya)
        }
        guard !days.isEmpty else { throw URLError(.cannotParseResponse) }
        return PrayerMonth(location: location, year: payload.tahun, month: payload.bulan, days: days)
    }
}

/// Keeps a month or two of times on this Mac, so the notch works without internet.
@MainActor
@Observable
final class PrayerModel {
    var location: PrayerLocation? {
        didSet {
            guard !isInert else { return }
            if let location, let data = try? JSONEncoder().encode(location) {
                defaults.set(data, forKey: "prayer.location")
            } else {
                defaults.removeObject(forKey: "prayer.location")
            }
            if location != oldValue { months = []; save(); refresh() }
        }
    }
    var notifies: Bool {
        didSet { defaults.set(notifies, forKey: "prayer.notifies") }
    }
    var notifiesEarly: Bool {
        didSet { defaults.set(notifiesEarly, forKey: "prayer.early") }
    }
    /// The province being picked in Advanced, before a city is chosen.
    var draftProvince: String? {
        didSet {
            guard let draftProvince, draftProvince != oldValue else { return }
            loadCities(in: draftProvince)
        }
    }
    private(set) var months: [PrayerMonth] = []
    private(set) var provinces: [String] = []
    private(set) var cities: [String] = []
    private(set) var problem: String?
    private(set) var isLoading = false

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let notifier = MacNotifier()
    @ObservationIgnored private var timer: Timer?
    /// Snapshots and tests set values without saving them or reaching the network.
    @ObservationIgnored private var isInert = false

    init(directory: URL, isInert: Bool = false) {
        self.isInert = isInert
        file = directory.appendingPathComponent("prayer-times.json")
        location = defaults.data(forKey: "prayer.location").flatMap { try? JSONDecoder().decode(PrayerLocation.self, from: $0) }
        notifies = defaults.bool(forKey: "prayer.notifies")
        notifiesEarly = defaults.bool(forKey: "prayer.early")
        draftProvince = location?.province
        months = isInert ? [] : (try? JSONDecoder().decode([PrayerMonth].self, from: Data(contentsOf: file))) ?? []
    }

    var schedule: PrayerSchedule? {
        location.map { PrayerSchedule(location: $0, months: months) }
    }

    func start() {
        guard !isInert else { return }
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func save() {
        try? JSONEncoder().encode(months).write(to: file, options: .atomic)
    }

    // MARK: Loading

    private func get(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: PrayerAPI.base + path)!, timeoutInterval: 20)
        request.setValue("DyskLink-Mac", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    func loadProvinces() {
        guard provinces.isEmpty else { return }
        Task {
            do { provinces = try PrayerAPI.provinces(from: try await get("/provinsi")) }
            catch { problem = "Couldn't load the list of provinces." }
        }
    }

    func loadCities(in province: String) {
        cities = []
        Task {
            do { cities = try PrayerAPI.cities(from: try await get("/kabkota", body: ["provinsi": province])) }
            catch { problem = "Couldn't load the list of cities." }
        }
    }

    /// Fetches this month, and next month once the end of this one is near.
    func refresh() {
        guard let location, !isLoading, !isInert else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = location.timeZone
        let now = Date()
        var wanted = [calendar.dateComponents([.year, .month], from: now)]
        if let days = calendar.range(of: .day, in: .month, for: now)?.count,
           calendar.component(.day, from: now) > days - 7,
           let next = calendar.date(byAdding: .month, value: 1, to: now) {
            wanted.append(calendar.dateComponents([.year, .month], from: next))
        }
        let missing = wanted.filter { parts in
            !months.contains { $0.location == location && $0.year == parts.year && $0.month == parts.month }
        }
        guard !missing.isEmpty else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            for parts in missing {
                guard let year = parts.year, let month = parts.month else { continue }
                do {
                    let data = try await get("", body: ["provinsi": location.province, "kabkota": location.city,
                                                        "bulan": month, "tahun": year])
                    let loaded = try PrayerAPI.month(from: data, location: location)
                    // The place may have been changed while this was loading.
                    guard self.location == location else { return }
                    months.removeAll { $0.location == location && $0.year == year && $0.month == month }
                    months.append(loaded)
                    // Months that ended long ago aren't needed.
                    months = months.filter { $0.location == location }.suffix(3).map { $0 }
                    problem = nil
                    save()
                } catch {
                    problem = "Couldn't load prayer times. They load again later."
                }
            }
        }
    }

    // MARK: Notifications

    private func tick() {
        refresh()
        guard notifies, let schedule, let upcoming = schedule.due(at: Date(), early: notifiesEarly) else { return }
        let id = "\(upcoming.prayer.rawValue)-\(Int(upcoming.time.timeIntervalSince1970))-\(notifiesEarly ? "early" : "now")"
        guard defaults.string(forKey: "prayer.lastAlert") != id else { return }
        defaults.set(id, forKey: "prayer.lastAlert")
        let clock = Self.clock(upcoming.time, in: schedule.location.timeZone)
        notifier.show(id: "prayer", title: notifiesEarly ? "\(upcoming.prayer.name) in 10 minutes" : "Time for \(upcoming.prayer.name)",
                      subtitle: schedule.location.label, body: clock)
    }

    static func clock(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    #if DEBUG
    func loadForSnapshot(location: PrayerLocation, months: [PrayerMonth]) {
        self.location = location
        self.months = months
    }
    #endif
}
