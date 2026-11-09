import SwiftUI

extension NotchView {
    var prayerPage: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            PrayerPanel(prayer: model.prayer, now: context.date)
        }
    }

    var weatherPage: some View {
        WeatherPanel(weather: model.weather, now: Date())
    }

    /// The place next to the page title.
    @ViewBuilder var placeLabel: some View {
        switch model.page {
        case .prayer:
            if let city = model.prayer.location?.label { placeText(city) }
        case .weather:
            if let name = model.weather.place?.shortName { placeText(name) }
        default:
            EmptyView()
        }
    }

    private func placeText(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1).frame(maxWidth: 80, alignment: .leading)
    }
}

private extension Text {
    func notchNote() -> some View {
        font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.6)).multilineTextAlignment(.center)
    }
}

// MARK: Prayer

struct PrayerPanel: View {
    let prayer: PrayerModel
    let now: Date

    var body: some View {
        if let schedule = prayer.schedule, let location = prayer.location {
            if let next = schedule.upcoming(after: now) {
                content(schedule, location, next)
            } else {
                Text(prayer.problem ?? "Loading prayer times…").notchNote().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            Text("Choose your city in Advanced > Notch.").notchNote().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ schedule: PrayerSchedule, _ location: PrayerLocation, _ next: PrayerSchedule.Upcoming) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next").font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.55))
                Text(next.prayer.name).font(.system(size: 34, weight: .bold)).foregroundStyle(Color.white)
                    .minimumScaleFactor(0.7).lineLimit(1)
                HStack(spacing: 8) {
                    Text(PrayerModel.clock(next.time, in: location.timeZone))
                        .font(.system(size: 18, weight: .semibold).monospacedDigit()).foregroundStyle(Color.white)
                    Text("in " + Self.until(next.time.timeIntervalSince(now)))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: 0x6EA8FF))
                }
                Capsule().fill(Color.white.opacity(0.14)).frame(height: 7)
                    .overlay(alignment: .leading) {
                        GeometryReader { box in
                            Capsule().fill(LinearGradient(colors: [Color(hex: 0x4FC3FF), Color(hex: 0x6E5BFF)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: box.size.width * Self.progress(next, now: now))
                        }
                    }
                    .padding(.top, 4)
            }
            .frame(width: 190)
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).padding(.vertical, 6)
            PrayerArc(times: schedule.times(on: now) ?? [], next: next.prayer, now: now, zone: location.timeZone)
        }
    }

    static func progress(_ next: PrayerSchedule.Upcoming, now: Date) -> Double {
        guard let previous = next.previous, next.time > previous else { return 0 }
        return min(max(now.timeIntervalSince(previous) / next.time.timeIntervalSince(previous), 0), 1)
    }

    static func until(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// The day as an arc from Subuh to Isya, with a dot for each of the five times.
struct PrayerArc: View {
    let times: [(prayer: Prayer, time: Date)]
    let next: Prayer
    let now: Date
    let zone: TimeZone

    private var span: (start: Date, end: Date)? {
        guard let first = times.first?.time, let last = times.last?.time, last > first else { return nil }
        return (first, last)
    }

    private func fraction(_ date: Date) -> Double {
        guard let span else { return 0 }
        return min(max(date.timeIntervalSince(span.start) / span.end.timeIntervalSince(span.start), 0), 1)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { box in
                let size = box.size
                ZStack {
                    ArcShape().stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ArcShape(upTo: fraction(now))
                        .stroke(LinearGradient(colors: [Color(hex: 0x4FC3FF), Color(hex: 0x6E5BFF)], startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ForEach(times, id: \.prayer) { item in
                        let x = fraction(item.time)
                        Circle().fill(item.prayer == next ? Color.white : Color.white.opacity(0.45))
                            .frame(width: item.prayer == next ? 9 : 7, height: item.prayer == next ? 9 : 7)
                            .position(x: x * size.width, y: ArcShape.y(x, in: size.height))
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(times, id: \.prayer) { item in
                    VStack(spacing: 2) {
                        Text(item.prayer.name)
                            .font(.system(size: 11, weight: item.prayer == next ? .bold : .regular))
                        Text(PrayerModel.clock(item.time, in: zone))
                            .font(.system(size: 11).monospacedDigit())
                    }
                    .foregroundStyle(Color.white.opacity(item.prayer == next ? 1 : 0.55))
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ArcShape: Shape {
    var upTo = 1.0

    /// The arc starts and ends on the baseline and peaks in the middle.
    static func y(_ x: Double, in height: CGFloat) -> CGFloat {
        height - CGFloat(sin(Double.pi * x)) * (height - 6)
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 60
        for step in 0...steps {
            let x = upTo * Double(step) / Double(steps)
            let point = CGPoint(x: x * rect.width, y: Self.y(x, in: rect.height))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

// MARK: Weather

struct WeatherPanel: View {
    let weather: WeatherModel
    let now: Date

    var body: some View {
        if weather.place == nil {
            Text("Choose your city in Advanced > Notch.").notchNote().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = weather.report {
            content(report)
        } else {
            Text(weather.problem ?? "Loading the weather…").notchNote().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ report: WeatherReport) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: WeatherAPI.symbol(report.code, isDay: report.isDay))
                        .symbolRenderingMode(.multicolor).font(.system(size: 32))
                    Text(weather.degrees(report.temperature))
                        .font(.system(size: 44, weight: .bold)).foregroundStyle(Color.white)
                }
                Text(WeatherAPI.describe(report.code)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white)
                if let today = report.days.first {
                    Text("High \(weather.degrees(today.high)) · Low \(weather.degrees(today.low))")
                        .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .frame(width: 190, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).padding(.vertical, 6)
            HStack(spacing: 8) {
                ForEach(Array(report.days.prefix(3).enumerated()), id: \.offset) { index, day in
                    dayCard(day, isToday: index == 0)
                }
            }
        }
    }

    private func dayCard(_ day: WeatherReport.Day, isToday: Bool) -> some View {
        VStack(spacing: 5) {
            Text(isToday ? "Today" : Self.weekday(day.date)).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
            Image(systemName: WeatherAPI.symbol(day.code)).symbolRenderingMode(.multicolor).font(.system(size: 20))
            Text("\(weather.degrees(day.high)) / \(weather.degrees(day.low))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Color.white)
            HStack(spacing: 3) {
                Image(systemName: "drop.fill").font(.system(size: 9))
                Text("\(day.rainChance)%").font(.system(size: 11).monospacedDigit())
            }
            .foregroundStyle(Color(hex: 0x6EA8FF))
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static func weekday(_ date: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let parsed = parser.date(from: date) else { return date }
        return parsed.formatted(.dateTime.weekday(.abbreviated))
    }
}
