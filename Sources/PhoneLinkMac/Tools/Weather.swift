import Foundation
import Observation

struct WeatherPlace: Codable, Equatable, Identifiable {
    var name: String
    var region: String?
    var latitude: Double
    var longitude: Double

    var id: String { "\(latitude),\(longitude)" }
    /// Without "Kota" or "Kabupaten" in front, so it fits next to the page title.
    var shortName: String {
        for prefix in ["Kota ", "Kabupaten ", "Kab. "] where name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
        return name
    }
    var label: String { [name, region].compactMap { $0 }.joined(separator: ", ") }
}

struct WeatherReport: Codable, Equatable {
    struct Day: Codable, Equatable {
        var date: String
        var code: Int
        var high: Double
        var low: Double
        var rainChance: Int
    }

    var temperature: Double
    var code: Int
    var isDay: Bool
    var days: [Day]
    var fetchedAt: Date
}

enum WeatherAPI {
    static func places(from data: Data) throws -> [WeatherPlace] {
        struct Reply: Decodable {
            struct Result: Decodable {
                let name: String
                let admin1: String?
                let latitude: Double
                let longitude: Double
            }
            let results: [Result]?
        }
        return try JSONDecoder().decode(Reply.self, from: data).results.map {
            $0.map { WeatherPlace(name: $0.name, region: $0.admin1, latitude: $0.latitude, longitude: $0.longitude) }
        } ?? []
    }

    static func report(from data: Data, at now: Date = Date()) throws -> WeatherReport {
        struct Reply: Decodable {
            struct Current: Decodable {
                let temperature_2m: Double
                let weather_code: Int
                let is_day: Int
            }
            struct Daily: Decodable {
                let time: [String]
                let weather_code: [Int]
                let temperature_2m_max: [Double]
                let temperature_2m_min: [Double]
                let precipitation_probability_max: [Int?]
            }
            let current: Current
            let daily: Daily
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let daily = reply.daily
        let count = min(daily.time.count, daily.weather_code.count, daily.temperature_2m_max.count,
                        daily.temperature_2m_min.count, daily.precipitation_probability_max.count)
        let days = (0..<count).map {
            WeatherReport.Day(date: daily.time[$0], code: daily.weather_code[$0], high: daily.temperature_2m_max[$0],
                              low: daily.temperature_2m_min[$0], rainChance: daily.precipitation_probability_max[$0] ?? 0)
        }
        return WeatherReport(temperature: reply.current.temperature_2m, code: reply.current.weather_code,
                             isDay: reply.current.is_day == 1, days: days, fetchedAt: now)
    }

    /// WMO weather codes, as Open-Meteo sends them.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67: return "Rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 80, 81, 82: return "Showers"
        case 95, 96, 99: return "Thunderstorm"
        default: return "Unknown"
        }
    }

    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }
}

@MainActor
@Observable
final class WeatherModel {
    static let refreshInterval: TimeInterval = 30 * 60

    var place: WeatherPlace? {
        didSet {
            guard !isInert else { return }
            if let place, let data = try? JSONEncoder().encode(place) {
                defaults.set(data, forKey: "weather.place")
            } else {
                defaults.removeObject(forKey: "weather.place")
            }
            if place != oldValue { report = nil; refresh(force: true) }
        }
    }
    var usesFahrenheit: Bool {
        didSet { defaults.set(usesFahrenheit, forKey: "weather.fahrenheit") }
    }
    /// The text typed into the city search in Advanced.
    var query = ""
    private(set) var report: WeatherReport?
    private(set) var results: [WeatherPlace] = []
    private(set) var isLoading = false
    private(set) var problem: String?
    private(set) var searchNote: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var isInert = false

    init(isInert: Bool = false) {
        self.isInert = isInert
        place = defaults.data(forKey: "weather.place").flatMap { try? JSONDecoder().decode(WeatherPlace.self, from: $0) }
        usesFahrenheit = defaults.bool(forKey: "weather.fahrenheit")
    }

    /// Reloads when the last answer is older than half an hour, or when forced.
    func refresh(force: Bool = false) {
        guard let place, !isLoading, !isInert else { return }
        if !force, let report, Date().timeIntervalSince(report.fetchedAt) < Self.refreshInterval { return }
        isLoading = true
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            .init(name: "latitude", value: String(place.latitude)),
            .init(name: "longitude", value: String(place.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "3"),
        ]
        let request = URLRequest(url: parts.url!, timeoutInterval: 20)
        Task {
            defer { isLoading = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let loaded = try WeatherAPI.report(from: data)
                // The place may have been changed while this was loading.
                guard self.place == place else { return }
                report = loaded
                problem = nil
            } catch {
                problem = "Couldn't load the weather."
            }
        }
    }

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { results = []; searchNote = nil; return }
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        parts.queryItems = [
            .init(name: "name", value: query), .init(name: "count", value: "6"),
            .init(name: "language", value: "id"), .init(name: "countryCode", value: "ID"),
        ]
        let request = URLRequest(url: parts.url!, timeoutInterval: 20)
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                results = try WeatherAPI.places(from: data)
                searchNote = results.isEmpty ? "No city found with that name." : nil
            } catch {
                searchNote = "Couldn't search. Check the connection."
            }
        }
    }

    func choose(_ place: WeatherPlace) {
        self.place = place
        results = []
        searchNote = nil
    }

    /// Temperatures come in Celsius.
    func degrees(_ celsius: Double) -> String {
        let value = usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    #if DEBUG
    func loadForSnapshot(place: WeatherPlace, report: WeatherReport) {
        self.place = place
        self.report = report
    }
    #endif
}
