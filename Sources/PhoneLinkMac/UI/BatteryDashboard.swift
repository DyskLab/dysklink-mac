import SwiftUI

/// The top of Mac Care › Battery: the limit and top up, what's happening, where the power goes, and charts.
struct BatteryDashboard: View {
    let battery: BatteryReading
    @Bindable var control: ChargeControl
    let power: PowerMonitor
    /// The smaller version for the menu bar.
    var compact = false
    /// The menu bar shows each part on its own; nil shows them all.
    var only: Part?

    enum Part { case limit, status, flow, apps, level, details, power }

    private static let sky = Color(hex: 0x6EB6FF)
    private var text: CGFloat { compact ? 12 : 13.5 }

    var body: some View {
        if let only {
            switch only {
            case .limit: limitRow
            case .status: whatsGoingOn
            case .flow: flow
            case .apps: appsCard
            case .level: levelChart
            case .details: detailsCard
            case .power: powerChart
            }
        } else {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                limitRow
                whatsGoingOn
                flow
                appsCard
                levelChart
                detailsCard
                powerChart
            }
        }
    }

    @ViewBuilder
    private var flow: some View {
        let list = PowerFlow(sample: power.current, onCharger: !onBattery, compact: compact)
        if compact {
            list.padding(10).background(Theme.panelRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            Card { list }
        }
    }

    // MARK: Limit and top up

    private var limit: Int? { control.settings.limiter ? control.settings.limit : nil }
    private var onBattery: Bool { control.adapterOff || (!battery.isPluggedIn && !battery.isCharging) }

    private var limitRow: some View {
        let font = Font.system(size: compact ? 11.5 : 13, weight: .medium)
        let height: CGFloat = compact ? 22 : 26
        return VStack(spacing: compact ? 8 : 10) {
            HStack(spacing: 8) {
                Text("Limit \(limit.map { "\($0)%" } ?? "off")")
                    .font(font).monospacedDigit().foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, compact ? 8 : 10).frame(height: height)
                    .background(Theme.panelRaised.opacity(0.7), in: Capsule())
                Spacer()
                Button { control.topUp.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(control.topUp ? "Topping up" : "Top up")
                        Image(systemName: control.topUp ? "xmark" : "plus").font(.system(size: compact ? 9.5 : 11, weight: .semibold))
                    }
                    .font(font)
                    .foregroundStyle(control.topUp ? Theme.mint : Theme.textSecondary)
                    .padding(.horizontal, compact ? 9 : 11).frame(height: height)
                    .background(control.topUp ? Theme.mint.opacity(0.14) : Theme.panelRaised.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.textFaint.opacity(0.18)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!control.installed)
                .help("Charge to 100% once, for a long day away from a charger. The limit comes back after.")
            }
            BatteryBar(percent: battery.percent, limit: limit, sailTo: limit.map { $0 - control.settings.gap },
                       charging: battery.isCharging, onBattery: onBattery, live: power.isLive, compact: compact)
        }
    }

    private var whatsGoingOn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("What's going on?").font(.system(size: compact ? 12.5 : 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "moon.fill").foregroundStyle(Theme.textSecondary).help("The Mac can sleep as usual.")
                Image(systemName: "powerplug.portrait.fill").foregroundStyle(!onBattery ? Theme.mint : Theme.textFaint)
                    .help(!onBattery ? "Powered by the charger" : "Not using the charger")
                Image(systemName: "battery.75percent").foregroundStyle(onBattery ? Theme.amber : Theme.textFaint)
                    .help(onBattery ? "Running on battery" : "Not using the battery")
            }
            .font(.system(size: compact ? 11.5 : 13))
            Text(explanation).font(.system(size: compact ? 11.5 : 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Theme.panelRaised.opacity(0.5) : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous).stroke(Theme.textFaint.opacity(0.2)))
    }

    private var explanation: String {
        let target = limit ?? 100
        let sail = limit.map { $0 - control.settings.gap }
        switch control.reason {
        case .limit where battery.percent > (sail ?? 0) && control.adapterOff:
            return "Your MacBook is running solely on battery, with the charger plugged in, and discharging to \(sail ?? target)%. Then it charges back to \(target)%."
        case .limit:
            return "The limit is reached. Charging stays paused until the battery is down to \(sail ?? target)%."
        case .discharge:
            return "Discharge on power is on, so your MacBook runs on battery even with the charger plugged in."
        case .heat:
            return "Charging is paused because the battery is \(LocalFormat.celsius(control.temperature ?? 0)). "
                + "It goes on below \(LocalFormat.decimal(control.settings.heatLimit - ChargePolicy.coolDown, digits: 0)) °C."
        case .topUp:
            return "Topping up to 100% once. Your \(limit.map { "\($0)% " } ?? "")limit comes back after that."
        case .held:
            return "Your MacBook runs on the charger and the battery stays at \(control.nativeLimit ?? target)%, held by macOS's Charge Limit."
        case .lowBattery:
            return "The battery is low, so it charges whatever the settings say."
        case .calibrationDrain, .calibrationCharge, .calibrationHold:
            return control.reason.label + ". Keep the charger plugged in."
        case .normal:
            if battery.isCharging { return "Charging to \(target)%" + (battery.minutesToFull.map { ", full in about \(MacCareView.duration($0))." } ?? ".") }
            if battery.isPluggedIn { return "Plugged in and not charging. macOS may be holding the charge, for example with its own Charge Limit or Optimized Charging." }
            return "Running on battery" + (battery.minutesToEmpty.map { ", about \(MacCareView.duration($0)) left." } ?? ".")
        }
    }

    // MARK: Apps

    private var appsCard: some View {
        Group {
            if power.apps.isEmpty {
                Text("No apps using significant energy")
                    .font(.system(size: compact ? 12 : 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: compact ? 38 : 54)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Using Significant Energy").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    ForEach(power.apps.prefix(compact ? 3 : 5)) { app in
                        HStack {
                            Text(app.name).font(.system(size: compact ? 12 : 13)).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(String(format: "%.0f", app.impact)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(app.impact >= 50 ? Theme.coral : Theme.amber)
                        }
                    }
                }
                .padding(compact ? 10 : 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(compact ? Theme.panelRaised.opacity(0.5) : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous).stroke(Theme.textFaint.opacity(0.2)))
        .help("Energy impact from macOS, as in Activity Monitor. Shown above \(Int(PowerMonitor.significantImpact)).")
    }

    // MARK: Charts

    private var levelChart: some View {
        ChartCard(title: "Battery level", icon: "battery.100percent", value: "\(battery.percent) %",
                  points: control.levels.map { Double($0.percent) }, range: 0...100,
                  guide: limit.map(Double.init), color: Theme.mint, compact: compact)
    }

    private var powerChart: some View {
        let values = power.history.map(\.systemWatts)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return ChartCard(title: "Power consumption", icon: "bolt.fill", value: LocalFormat.watts(power.current.systemWatts),
                         points: values, range: 0...max(5, (values.max() ?? 5) * 1.15), guide: average, color: Theme.violet, compact: compact)
    }

    // MARK: Details

    private var detailsCard: some View {
        let rows = VStack(spacing: compact ? 7 : 10) {
                detail("stethoscope", "Maximum capacity", battery.fullMah.map { "\($0) mAh" }, (battery.appleMaxCapacity ?? battery.health).map { "\($0) %" })
                detail("clock.arrow.circlepath", "Cycle count", nil, "\(battery.cycles)")
                Divider().overlay(Theme.textFaint.opacity(0.3))
                detail("flame", "Temperature", nil, battery.temperatureC.map(LocalFormat.celsius) ?? "—")
                detail("clock", battery.isCharging ? "Time to full" : "Time remaining", nil,
                       (battery.isCharging ? battery.minutesToFull : battery.minutesToEmpty).map(MacCareView.duration) ?? "—")
                Divider().overlay(Theme.textFaint.opacity(0.3))
                detail("battery.100percent", "Battery power", nil, LocalFormat.watts(power.current.batteryWatts))
                detail("laptopcomputer", "System load", nil, LocalFormat.watts(power.current.systemWatts))
                Divider().overlay(Theme.textFaint.opacity(0.3))
                if let watts = battery.adapterWatts, !onBattery {
                    detail("powerplug", "Power Adapter:", nil, "\(watts) W")
                    detail("bolt", "Drawing from Adapter:", nil, LocalFormat.watts(power.current.adapterWatts))
                } else {
                    Text("Power adapter specs are not available when discharging.")
                        .font(.system(size: compact ? 11 : 12)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                }
        }
        return Group {
            if compact {
                rows.padding(10).background(Theme.panelRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Card { rows }
            }
        }
    }

    private func detail(_ icon: String, _ title: String, _ middle: String?, _ value: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: compact ? 12 : 14)).foregroundStyle(Theme.textSecondary).frame(width: compact ? 18 : 22)
            Text(title).font(.system(size: text)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 4)
            if let middle { Text(middle).font(.system(size: text, weight: .semibold)).foregroundStyle(Theme.textPrimary).padding(.trailing, compact ? 8 : 18) }
            Text(value ?? "—").font(.system(size: text, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
    }
}

// MARK: - Parts
/// The battery level drawn as a battery: a body with a nub on the right, one solid fill, a thin line at the limit
/// with a small pointer above it, and a dashed line where sailing goes back to.
private struct BatteryBar: View {
    let percent: Int
    let limit: Int?
    let sailTo: Int?
    let charging: Bool
    let onBattery: Bool
    /// Power is being sampled, so the menu is on screen.
    var live = false
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Amber on battery, mint while charging, quiet gray otherwise.
    static func color(charging: Bool, onBattery: Bool) -> Color {
        onBattery ? Theme.amber : charging ? Theme.mint : Color(hex: 0x8C96A8)
    }

    private var height: CGFloat { compact ? 22 : 26 }
    private static let pointer: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let nub: CGFloat = 3, inset: CGFloat = 2.5
            let bodyW = geo.size.width - nub - 1.5, h = height
            let inner = bodyW - inset * 2
            let color = Self.color(charging: charging, onBattery: onBattery)
            let x = { (value: Int) in inset + inner * CGFloat(min(max(value, 0), 100)) / 100 }
            let fillW = max(h * 0.4, x(percent) - inset)
            let fillShape = RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous)
            let labelW: CGFloat = compact ? 50 : 58
            let inside = fillW >= labelW + 8
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .fill(Theme.panelRaised.opacity(0.8))
                    .overlay(RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .frame(width: bodyW, height: h)
                UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 1.5, topTrailingRadius: 1.5, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: nub, height: h * 0.4)
                    .offset(x: bodyW + 1.5, y: h * 0.3)
                fillShape.fill(color)
                    .overlay {
                        // Only while the charger is actually charging, and only while the menu is on screen.
                        if charging && !onBattery && live && !reduceMotion {
                            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                                fillShape.fill(LinearGradient(gradient: Sweep.gradient(Sweep.phase(timeline.date), color: .white.opacity(0.18)),
                                                              startPoint: .leading, endPoint: .trailing))
                            }
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: fillW, height: h - inset * 2)
                    .offset(x: inset, y: inset)
                if let sailTo, sailTo > 0, sailTo != limit {
                    Path { p in
                        p.move(to: CGPoint(x: x(sailTo), y: inset + 3)); p.addLine(to: CGPoint(x: x(sailTo), y: h - inset - 3))
                    }
                    .stroke(Theme.textPrimary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .help("Charging starts again at \(sailTo)%")
                }
                if let limit {
                    let lx = min(max(x(limit), inset + 1), bodyW - inset - 1)
                    Rectangle().fill(Theme.textPrimary.opacity(0.85))
                        .frame(width: 1.5, height: h - inset * 2)
                        .offset(x: lx - 0.75, y: inset)
                    Triangle().fill(Theme.textPrimary.opacity(0.85))
                        .frame(width: 7, height: 4.5)
                        .offset(x: lx - 3.5, y: -Self.pointer)
                        .help("Charge limit \(limit)%")
                }
                HStack(spacing: 4) {
                    Image(systemName: onBattery ? "battery.75percent" : charging ? "bolt.fill" : "powerplug.portrait.fill")
                        .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
                    Text("\(percent)%").font(.system(size: compact ? 11.5 : 13, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(inside ? Theme.ink.opacity(0.85) : Theme.textPrimary)
                .frame(height: h)
                .offset(x: inside ? inset + 7 : inset + fillW + 6)
            }
        }
        .frame(height: height)
        .padding(.top, limit == nil ? 0 : Self.pointer + 1)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); p.closeSubpath()
        }
    }
}

/// A line chart with a filled area and a dashed guide, such as the limit or the average.
private struct ChartCard: View {
    let title: String
    let icon: String
    let value: String
    let points: [Double]
    let range: ClosedRange<Double>
    let guide: Double?
    let color: Color
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: compact ? 12.5 : 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: icon).font(.system(size: compact ? 11 : 14)).foregroundStyle(Theme.textPrimary)
                Text(value).font(.system(size: compact ? 15 : 20, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, compact ? 10 : 14).padding(.top, compact ? 8 : 12)
            Canvas { context, size in
                let span = max(range.upperBound - range.lowerBound, 0.001)
                func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)) }
                if points.count > 1 {
                    let step = size.width / CGFloat(points.count - 1)
                    var line = Path()
                    for (i, v) in points.enumerated() {
                        let point = CGPoint(x: CGFloat(i) * step, y: y(v))
                        i == 0 ? line.move(to: point) : line.addLine(to: point)
                    }
                    var area = line
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    area.addLine(to: CGPoint(x: 0, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.4), color.opacity(0.05)]),
                                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                } else {
                    context.draw(Text("Collecting…").font(.system(size: 12)).foregroundStyle(Theme.textFaint),
                                 at: CGPoint(x: size.width / 2, y: size.height / 2))
                }
                if let guide {
                    var dash = Path()
                    dash.move(to: CGPoint(x: 0, y: y(guide)))
                    dash.addLine(to: CGPoint(x: size.width, y: y(guide)))
                    context.stroke(dash, with: .color(Theme.amber.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
            .frame(height: compact ? 70 : 150)
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
        .background(compact ? Theme.panelRaised.opacity(0.5) : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous).stroke(Theme.textFaint.opacity(0.2)))
    }
}

/// Where the power goes, as a list: where it comes from and the total on top, then one row per use with a small bar
/// as long as its share.
private struct PowerFlow: View {
    let sample: PowerSample
    /// The charger can power the Mac, so charging the battery is a use worth listing.
    var onCharger = false
    var compact = false

    private static let orchid = Color(hex: 0xD58BF0)
    private static let sky = Color(hex: 0x6EB6FF)

    private struct Row: Identifiable {
        let icon: String
        let name: String
        let watts: Double?
        let color: Color
        let help: String
        var id: String { name }
    }

    private var split: PowerSplit { PowerSplit(sample) }

    private var rows: [Row] {
        let split = split
        var list: [Row] = []
        if let gpu = split.gpu {
            list.append(Row(icon: "cpu", name: "Graphics", watts: gpu > 0.02 ? gpu : nil, color: Self.orchid, help: "Graphics (GPU)"))
        }
        list.append(Row(icon: "ellipsis.circle", name: "Everything else", watts: split.rest, color: Self.sky,
                        help: "The rest of the Mac: processor, screen, storage, and more"))
        if onCharger || split.charging > 0 {
            list.append(Row(icon: "battery.100percent.bolt", name: "Charging", watts: split.charging > 0 ? split.charging : nil,
                            color: Theme.mint, help: "Charging the battery"))
        }
        return list
    }

    private var title: String {
        let split = split
        if split.isMixed { return "From charger and battery" }
        return split.charger > 0 ? "From charger" : "From battery"
    }

    private var size: CGFloat { compact ? 12 : 13.5 }

    var body: some View {
        let split = split
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: size + 0.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Text(LocalFormat.watts(split.total)).font(.system(size: size + 0.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            if split.isMixed {
                Text("Charger \(LocalFormat.watts(split.charger)) · Battery \(LocalFormat.watts(split.battery))")
                    .font(.system(size: size - 1).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }
            Rectangle().fill(Theme.textFaint.opacity(0.25)).frame(height: 1).padding(.vertical, compact ? 7 : 9)
            VStack(spacing: 8) {
                ForEach(rows) { row in line(row, total: split.total) }
            }
        }
        .help("Your MacBook uses \(LocalFormat.watts(split.system))")
    }

    private func line(_ row: Row, total: Double) -> some View {
        let share = row.watts.map { total > 0 ? min(1, $0 / total) : 0 } ?? 0
        return HStack(spacing: 8) {
            Image(systemName: row.icon).font(.system(size: 14)).foregroundStyle(row.color).frame(width: 18)
            Text(row.name).font(.system(size: size)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                .frame(width: compact ? 98 : 120, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panelRaised)
                    Capsule().fill(row.color).frame(width: share > 0 ? max(6, geo.size.width * share) : 0)
                }
            }
            .frame(height: 6)
            Text(row.watts.map { LocalFormat.watts($0) } ?? "—").font(.system(size: size, weight: .medium).monospacedDigit())
                .foregroundStyle(row.watts == nil ? Theme.textFaint : Theme.textPrimary)
                .lineLimit(1).frame(width: compact ? 56 : 66, alignment: .trailing)
        }
        .frame(height: 22)
        .help(row.help)
    }
}

/// A soft band of light that sweeps left to right and starts over, for the battery fill while it charges.
enum Sweep {
    static let period = 3.5

    /// Where the band is, from just before the left edge to just past the right, for a time.
    static func phase(_ date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return -0.25 + t * 1.5
    }

    /// Clear, then `color` at `phase`, then clear again, across 0...1.
    static func gradient(_ phase: Double, color: Color, width: Double = 0.22) -> Gradient {
        let a = min(max(phase - width, 0), 1), m = min(max(phase, 0), 1), b = min(max(phase + width, 0), 1)
        return Gradient(stops: [
            .init(color: .clear, location: 0), .init(color: .clear, location: a),
            .init(color: color, location: m),
            .init(color: .clear, location: b), .init(color: .clear, location: 1),
        ])
    }
}
