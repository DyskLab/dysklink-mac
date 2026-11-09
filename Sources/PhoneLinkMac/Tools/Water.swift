import Foundation
import Observation

struct WaterEntry: Codable, Equatable {
    var date: Date
    var ml: Int
}

struct WaterSettings: Codable, Equatable {
    var goalMl = 2000
    var glassMl = 250
    var remindEveryMinutes = 60
    var reminds = false
    /// Reminders only come between these hours, so none arrive at night.
    var fromHour = 8
    var toHour = 21

    static let goalChoices = [1000, 1500, 2000, 2500, 3000, 3500, 4000]
    static let glassChoices = [100, 150, 200, 250, 300, 400, 500]
    static let intervalChoices = [30, 45, 60, 90, 120, 180]
    static let hourChoices = Array(0...23)

    /// Values outside the lists, from an edited preferences file, fall back to the defaults.
    var checked: WaterSettings {
        let standard = WaterSettings()
        var result = self
        if !Self.goalChoices.contains(goalMl) { result.goalMl = standard.goalMl }
        if !Self.glassChoices.contains(glassMl) { result.glassMl = standard.glassMl }
        if !Self.intervalChoices.contains(remindEveryMinutes) { result.remindEveryMinutes = standard.remindEveryMinutes }
        if !Self.hourChoices.contains(fromHour) || !Self.hourChoices.contains(toHour) || fromHour >= toHour {
            result.fromHour = standard.fromHour
            result.toHour = standard.toHour
        }
        return result
    }
}

/// What was drunk, and when a reminder is due, without saving or screens, so it can be tested on its own.
struct WaterLog: Equatable {
    static let keptDays = 7
    var entries: [WaterEntry] = []

    mutating func add(_ ml: Int, at date: Date) {
        guard ml > 0 else { return }
        entries.append(WaterEntry(date: date, ml: ml))
    }

    /// Takes back the most recent drink of today.
    mutating func undo(now: Date, calendar: Calendar = .current) {
        guard let index = entries.lastIndex(where: { calendar.isDate($0.date, inSameDayAs: now) }) else { return }
        entries.remove(at: index)
    }

    mutating func dropOld(now: Date, calendar: Calendar = .current) {
        guard let limit = calendar.date(byAdding: .day, value: -Self.keptDays, to: calendar.startOfDay(for: now)) else { return }
        entries.removeAll { $0.date < limit }
    }

    func total(on now: Date, calendar: Calendar = .current) -> Int {
        entries.filter { calendar.isDate($0.date, inSameDayAs: now) }.reduce(0) { $0 + $1.ml }
    }

    /// Millilitres per hour of the day, for today.
    func byHour(on now: Date, calendar: Calendar = .current) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for entry in entries where calendar.isDate(entry.date, inSameDayAs: now) {
            result[calendar.component(.hour, from: entry.date), default: 0] += entry.ml
        }
        return result
    }

    func lastDrink(calendar: Calendar = .current) -> Date? { entries.map(\.date).max() }

    /// A reminder is due once the interval has passed since the last drink or the last reminder, inside the hours
    /// the user chose, and only while today's goal isn't reached.
    static func isReminderDue(now: Date, lastDrink: Date?, lastReminder: Date?, total: Int, settings: WaterSettings,
                              calendar: Calendar = .current) -> Bool {
        guard settings.reminds, total < settings.goalMl else { return false }
        let hour = calendar.component(.hour, from: now)
        guard hour >= settings.fromHour, hour < settings.toHour else { return false }
        let interval = TimeInterval(settings.remindEveryMinutes * 60)
        let since = [lastDrink, lastReminder].compactMap { $0 }.max()
        // With nothing yet today, the first reminder waits for the interval after the hours begin.
        let start = calendar.date(bySettingHour: settings.fromHour, minute: 0, second: 0, of: now) ?? now
        return now.timeIntervalSince(max(since ?? start, start)) >= interval
    }
}

@MainActor
@Observable
final class WaterModel {
    private(set) var log = WaterLog()
    /// Shows the settings controls in place of the chart.
    var showsSettings = false
    var settings: WaterSettings {
        didSet {
            guard persists else { return }
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "water.settings") }
        }
    }
    /// Called with the short text for the notch when a reminder is due.
    @ObservationIgnored var onRemind: ((String) -> Void)?

    @ObservationIgnored private let file: URL
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let notifier = MacNotifier()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastReminder: Date?

    init(directory: URL, persists: Bool = true) {
        file = directory.appendingPathComponent("notch-water.json")
        self.persists = persists
        settings = persists
            ? (defaults.data(forKey: "water.settings").flatMap { try? JSONDecoder().decode(WaterSettings.self, from: $0) }?.checked ?? WaterSettings())
            : WaterSettings()
        if persists, let data = try? Data(contentsOf: file),
           let entries = try? JSONDecoder().decode([WaterEntry].self, from: data) {
            log.entries = entries
        }
        log.dropOld(now: Date())
    }

    func total(_ now: Date) -> Int { log.total(on: now) }

    func fraction(_ now: Date) -> Double {
        min(Double(total(now)) / Double(max(settings.goalMl, 1)), 1)
    }

    func drink() {
        log.add(settings.glassMl, at: Date())
        save()
    }

    func undo() {
        log.undo(now: Date())
        save()
    }

    private func save() {
        guard persists else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(log.entries), (try? data.write(to: file, options: .atomic)) != nil
        else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: Reminders

    func start() {
        guard persists, timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Date()
        guard WaterLog.isReminderDue(now: now, lastDrink: log.lastDrink(), lastReminder: lastReminder,
                                     total: total(now), settings: settings) else { return }
        lastReminder = now
        onRemind?("Time to drink water")
        notifier.show(id: "water", title: "Time to drink water",
                      subtitle: nil, body: "\(total(now)) of \(settings.goalMl) ml today.")
    }

    /// "1.5" for 1500 and "0.25" for 250, the way the page shows litres.
    static func litres(_ ml: Int) -> String {
        let value = Double(ml) / 1000
        return value == value.rounded() ? String(format: "%.0f", value) : (String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression))
    }

    #if DEBUG
    func loadForSnapshot(_ entries: [WaterEntry]) {
        log.entries = entries
    }
    #endif
}
