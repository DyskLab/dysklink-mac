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
            if compact {
                PowerFlow(sample: power.current, compact: true).frame(height: 150)
                    .padding(10).background(Theme.panelRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Card { PowerFlow(sample: power.current).frame(height: 260) }
            }
    }

    // MARK: Limit and top up

    private var limit: Int? { control.settings.limiter ? control.settings.limit : nil }
    private var onBattery: Bool { control.adapterOff || (!battery.isPluggedIn && !battery.isCharging) }

    private var limitRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                (Text("Limit: ").bold() + Text(limit.map { "\($0)%" } ?? "off"))
                    .font(.system(size: compact ? 12.5 : 14)).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, compact ? 11 : 14).frame(height: compact ? 28 : 34).background(Theme.panelRaised, in: Capsule())
                Spacer()
                Button { control.topUp.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(control.topUp ? "Topping Up" : "Top Up")
                        Image(systemName: control.topUp ? "xmark.circle" : "plus.circle")
                    }
                    .font(.system(size: compact ? 12.5 : 14, weight: .medium))
                    .foregroundStyle(control.topUp ? Theme.ink : Theme.textPrimary)
                    .padding(.horizontal, compact ? 11 : 14).frame(height: compact ? 28 : 34)
                    .background(control.topUp ? Theme.mint : Theme.panelRaised, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!control.installed)
                .help("Charge to 100% once, for a long day away from a charger. The limit comes back after.")
            }
            BatteryBar(percent: battery.percent, limit: limit, sailTo: limit.map { $0 - control.settings.gap },
                       charging: battery.isCharging, onBattery: onBattery)
                .frame(height: compact ? 30 : 38)
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
            return "Discharge on Power is on, so your MacBook runs on battery even with the charger plugged in."
        case .heat:
            return String(format: "Charging is paused because the battery is %.1f °C. It goes on below %.0f °C.",
                          control.temperature ?? 0, control.settings.heatLimit - ChargePolicy.coolDown)
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
                Text("No Apps Using Significant Energy")
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
        ChartCard(title: "Battery Level", icon: "battery.100percent", value: "\(battery.percent) %",
                  points: control.levels.map { Double($0.percent) }, range: 0...100,
                  guide: limit.map(Double.init), color: Theme.mint, compact: compact)
    }

    private var powerChart: some View {
        let values = power.history.map(\.systemWatts)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return ChartCard(title: "Power Consumption", icon: "bolt.fill", value: String(format: "%.2f W", power.current.systemWatts),
                         points: values, range: 0...max(5, (values.max() ?? 5) * 1.15), guide: average, color: Theme.violet, compact: compact)
    }

    // MARK: Details

    private var detailsCard: some View {
        let rows = VStack(spacing: compact ? 7 : 10) {
                detail("stethoscope", "Maximum Capacity:", battery.fullMah.map { "\($0) mAh" }, (battery.appleMaxCapacity ?? battery.health).map { "\($0) %" })
                detail("clock.arrow.circlepath", "Cycle Count:", nil, "\(battery.cycles)")
                Divider().overlay(Theme.textFaint.opacity(0.3))
                detail("flame", "Battery Temperature:", nil, battery.temperatureC.map { String(format: "%.1f °C", $0) } ?? "—")
                detail("clock", battery.isCharging ? "Time to Full:" : "Time Remaining:", nil,
                       (battery.isCharging ? battery.minutesToFull : battery.minutesToEmpty).map(MacCareView.duration) ?? "—")
                Divider().overlay(Theme.textFaint.opacity(0.3))
                detail("battery.100percent", "Power:", nil, String(format: "%.2f W", power.current.batteryWatts))
                detail("laptopcomputer", "System Load:", nil, String(format: "%.2f W", power.current.systemWatts))
                Divider().overlay(Theme.textFaint.opacity(0.3))
                if let watts = battery.adapterWatts, !onBattery {
                    detail("powerplug", "Power Adapter:", nil, "\(watts) W")
                    detail("bolt", "Drawing from Adapter:", nil, String(format: "%.2f W", power.current.adapterWatts))
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

/// The battery level as a wide bar, with the limit and where sailing goes back to.
private struct BatteryBar: View {
    let percent: Int
    let limit: Int?
    let sailTo: Int?
    let charging: Bool
    let onBattery: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fill = onBattery ? Theme.amber : charging ? Theme.mint : Theme.textSecondary
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panelRaised)
                Capsule().fill(fill.opacity(0.85)).frame(width: max(44, width * CGFloat(percent) / 100))
                HStack {
                    Text("\(percent)%").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                .padding(.leading, 16)
                Image(systemName: onBattery ? "powerplug.portrait" : charging ? "bolt.fill" : "powerplug.portrait.fill")
                    .overlay(alignment: .trailing) { if onBattery { Image(systemName: "minus").offset(x: 12) } }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.85))
                    .position(x: max(70, width * CGFloat(percent) / 200), y: geo.size.height / 2)
                if let sailTo {
                    Path { p in
                        let x = width * CGFloat(sailTo) / 100
                        p.move(to: CGPoint(x: x, y: 8)); p.addLine(to: CGPoint(x: x, y: geo.size.height - 8))
                    }
                    .stroke(Theme.textPrimary.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [3, 4]))
                }
                if let limit {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.textPrimary.opacity(0.85))
                        .frame(width: 4, height: geo.size.height + 8)
                        .position(x: width * CGFloat(limit) / 100, y: geo.size.height / 2)
                }
            }
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

/// Where the power comes from (charger, battery) and where it goes (battery charging, GPU, the rest of the Mac).
private struct PowerFlow: View {
    let sample: PowerSample
    var compact = false

    private struct Part {
        let icon: String
        let watts: Double
        let color: Color
        let help: String
    }

    private static let sky = Color(hex: 0x6EB6FF)

    private var sources: [Part] {
        var list: [Part] = []
        if sample.adapterWatts > 0.3 { list.append(Part(icon: "powerplug.portrait.fill", watts: sample.adapterWatts, color: Theme.mint, help: "From the charger")) }
        if sample.fromBattery > 0.05 || list.isEmpty { list.append(Part(icon: "battery.100percent", watts: sample.fromBattery, color: Theme.amber, help: "From the battery")) }
        return list
    }

    private var outputs: [Part] {
        var list: [Part] = []
        if let gpu = sample.gpuWatts, gpu > 0.02 { list.append(Part(icon: "cpu", watts: gpu, color: Self.sky, help: "Graphics (GPU)")) }
        if sample.intoBattery > 0.05 { list.append(Part(icon: "battery.100percent.bolt", watts: sample.intoBattery, color: Theme.mint, help: "Charging the battery")) }
        list.append(Part(icon: "ellipsis", watts: sample.restWatts, color: Self.sky, help: "The rest of the Mac: processor, screen, storage, and more"))
        return list
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let iconW: CGFloat = compact ? 34 : 52, gap: CGFloat = compact ? 5 : 8
            let barW = w * 0.26
            let macX = iconW + gap + barW + gap
            let ribbonX = macX + iconW + gap
            let outX = w - iconW
            let srcBoxes = stack(sources.map(\.watts), height: h, gap: compact ? 6 : 10, minimum: compact ? 36 : 50)
            let outBoxes = stack(outputs.map(\.watts), height: h, gap: compact ? 8 : 12, minimum: compact ? 30 : 44)
            let total = max(outputs.map(\.watts).reduce(0, +), 0.001)
            ZStack(alignment: .topLeading) {
                // Ribbons first, so the boxes sit on top.
                Canvas { context, _ in
                    var y = h * 0.12
                    let band = h * 0.76
                    for (i, part) in outputs.enumerated() {
                        let thick = max(10, band * CGFloat(part.watts / total))
                        let start = (y, y + thick)
                        let end = (outBoxes[i].minY + 4, outBoxes[i].maxY - 4)
                        var path = Path()
                        let x0 = ribbonX, x1 = outX - gap, mid = (x0 + x1) / 2
                        path.move(to: CGPoint(x: x0, y: start.0))
                        path.addCurve(to: CGPoint(x: x1, y: end.0), control1: CGPoint(x: mid, y: start.0), control2: CGPoint(x: mid, y: end.0))
                        path.addLine(to: CGPoint(x: x1, y: end.1))
                        path.addCurve(to: CGPoint(x: x0, y: start.1), control1: CGPoint(x: mid, y: end.1), control2: CGPoint(x: mid, y: start.1))
                        path.closeSubpath()
                        context.fill(path, with: .linearGradient(Gradient(colors: [part.color.opacity(0.75), Theme.panelRaised]),
                                                                 startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                        context.draw(Text(String(format: "%.2f W", part.watts)).font(.system(size: compact ? 11 : 13, weight: .semibold)).foregroundStyle(Theme.textPrimary),
                                     at: CGPoint(x: mid + 8, y: (start.0 + start.1 + end.0 + end.1) / 4))
                        y += thick
                    }
                }
                ForEach(Array(sources.enumerated()), id: \.offset) { i, part in
                    box(icon: part.icon, color: part.color).frame(width: iconW, height: srcBoxes[i].height)
                        .offset(x: 0, y: srcBoxes[i].minY).help(part.help)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [part.color.opacity(0.45), Self.sky.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                        .overlay(Text(String(format: "%.2f W", part.watts)).font(.system(size: compact ? 11.5 : 14, weight: .semibold)).foregroundStyle(Theme.textPrimary))
                        .frame(width: barW, height: srcBoxes[i].height)
                        .offset(x: iconW + gap, y: srcBoxes[i].minY)
                }
                box(icon: "laptopcomputer", color: Self.sky).frame(width: iconW, height: h * 0.76).offset(x: macX, y: h * 0.12)
                    .help(String(format: "Your MacBook uses %.2f W", sample.systemWatts))
                ForEach(Array(outputs.enumerated()), id: \.offset) { i, part in
                    box(icon: part.icon, color: part.color).frame(width: iconW, height: outBoxes[i].height)
                        .offset(x: outX, y: outBoxes[i].minY).help(part.help)
                }
            }
        }
    }

    private func box(icon: String, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Theme.panelRaised)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.textFaint.opacity(0.25)))
            .overlay(Image(systemName: icon).font(.system(size: compact ? 12 : 16)).foregroundStyle(color))
    }

    /// Splits the height between parts by their share, each at least `minimum` tall.
    private func stack(_ values: [Double], height: CGFloat, gap: CGFloat, minimum: CGFloat) -> [CGRect] {
        guard !values.isEmpty else { return [] }
        let free = height - gap * CGFloat(values.count - 1)
        let total = max(values.reduce(0, +), 0.001)
        var heights = values.map { max(minimum, free * CGFloat($0 / total)) }
        let scale = free / heights.reduce(0, +)
        heights = heights.map { $0 * scale }
        var y: CGFloat = 0
        return heights.map { item in
            defer { y += item + gap }
            return CGRect(x: 0, y: y, width: 0, height: item)
        }
    }
}
