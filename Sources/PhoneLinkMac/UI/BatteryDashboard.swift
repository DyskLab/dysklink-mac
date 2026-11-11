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
                PowerFlow(sample: power.current, compact: true, live: power.isLive).frame(height: 164)
                    .padding(10).background(Theme.panelRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Card { PowerFlow(sample: power.current, live: power.isLive).frame(height: 260) }
            }
    }

    // MARK: Limit and top up

    private var limit: Int? { control.settings.limiter ? control.settings.limit : nil }
    private var onBattery: Bool { control.adapterOff || (!battery.isPluggedIn && !battery.isCharging) }

    /// The battery bar's own fill color, so its shine matches it.
    private var barColor: Color { BatteryBar.colors(charging: battery.isCharging, onBattery: onBattery)[0] }

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
                .sweep(Capsule(), color: .white.opacity(battery.isCharging ? 0.35 : 0.22), live: power.isLive)
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
                  guide: limit.map(Double.init), color: Theme.mint, compact: compact, live: power.isLive)
    }

    private var powerChart: some View {
        let values = power.history.map(\.systemWatts)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return ChartCard(title: "Power Consumption", icon: "bolt.fill", value: LocalFormat.watts(power.current.systemWatts),
                         points: values, range: 0...max(5, (values.max() ?? 5) * 1.15), guide: average, color: Theme.violet, compact: compact, live: power.isLive)
    }

    // MARK: Details

    private var detailsCard: some View {
        let rows = VStack(spacing: compact ? 7 : 10) {
                detail("stethoscope", "Maximum Capacity:", battery.fullMah.map { "\($0) mAh" }, (battery.appleMaxCapacity ?? battery.health).map { "\($0) %" })
                detail("clock.arrow.circlepath", "Cycle Count:", nil, "\(battery.cycles)")
                Divider().overlay(Theme.textFaint.opacity(0.3))
                detail("flame", "Battery Temperature:", nil, battery.temperatureC.map(LocalFormat.celsius) ?? "—")
                detail("clock", battery.isCharging ? "Time to Full:" : "Time Remaining:", nil,
                       (battery.isCharging ? battery.minutesToFull : battery.minutesToEmpty).map(MacCareView.duration) ?? "—")
                Divider().overlay(Theme.textFaint.opacity(0.3))
                detail("battery.100percent", "Power:", nil, LocalFormat.watts(power.current.batteryWatts))
                detail("laptopcomputer", "System Load:", nil, LocalFormat.watts(power.current.systemWatts))
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
/// The battery level drawn as a battery: a body with a terminal on the right, the fill inside, a tick at the limit,
/// and a dashed line where sailing goes back to.
private struct BatteryBar: View {
    let percent: Int
    let limit: Int?
    let sailTo: Int?
    let charging: Bool
    let onBattery: Bool

    /// Left and right of the fill: warm on battery, cool while charging, quiet otherwise.
    static func colors(charging: Bool, onBattery: Bool) -> [Color] {
        if onBattery { return [Theme.amber, Color(hex: 0xFF8A4C)] }
        if charging { return [Theme.mint, Color(hex: 0x4CC3FF)] }
        return [Color(hex: 0x9AA4B6), Color(hex: 0x6B7588)]
    }

    var body: some View {
        GeometryReader { geo in
            let nub: CGFloat = 5, inset: CGFloat = 3
            let bodyW = geo.size.width - nub - 2, h = geo.size.height
            let inner = bodyW - inset * 2
            let colors = Self.colors(charging: charging, onBattery: onBattery)
            let x = { (value: Int) in inset + inner * CGFloat(min(max(value, 0), 100)) / 100 }
            ZStack(alignment: .topLeading) {
                // The body and its terminal.
                RoundedRectangle(cornerRadius: h * 0.32, style: .continuous)
                    .fill(Theme.panelRaised)
                    .overlay(RoundedRectangle(cornerRadius: h * 0.32, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1.5))
                    .frame(width: bodyW, height: h)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: nub, height: h * 0.36)
                    .offset(x: bodyW + 2, y: h * 0.32)
                // The charge.
                RoundedRectangle(cornerRadius: h * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: h * 0.22, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center)))
                    .shadow(color: colors[1].opacity(0.45), radius: 6)
                    .frame(width: max(h, x(percent) - inset), height: h - inset * 2)
                    .offset(x: inset, y: inset)
                HStack(spacing: 6) {
                    Image(systemName: onBattery ? "battery.75percent" : charging ? "bolt.fill" : "powerplug.portrait.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("\(percent)%").font(.system(size: 13.5, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(Theme.ink)
                .frame(height: h).padding(.leading, 12)
                if let sailTo {
                    Path { p in
                        p.move(to: CGPoint(x: x(sailTo), y: inset + 4)); p.addLine(to: CGPoint(x: x(sailTo), y: h - inset - 4))
                    }
                    .stroke(Theme.textPrimary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                }
                if let limit {
                    // A tick across the body with a small pointer above it.
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.textPrimary)
                        .shadow(color: colors[0].opacity(0.9), radius: 4)
                        .frame(width: 3, height: h + 6)
                        .offset(x: x(limit) - 1.5, y: -3)
                    Triangle().fill(Theme.textPrimary)
                        .frame(width: 9, height: 6)
                        .offset(x: x(limit) - 4.5, y: -10)
                }
            }
        }
        .padding(.top, limit == nil ? 0 : 8)
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
    var live = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: compact ? 12.5 : 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: icon).font(.system(size: compact ? 11 : 14)).foregroundStyle(Theme.textPrimary)
                Text(value).font(.system(size: compact ? 15 : 20, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, compact ? 10 : 14).padding(.top, compact ? 8 : 12)
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live || reduceMotion)) { timeline in
            let moving = live && !reduceMotion
            let phase = Sweep.phase(timeline.date)
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
                    if moving {
                        // A band of brighter fill that runs to the right and starts over.
                        context.fill(area, with: .linearGradient(Sweep.gradient(phase, color: color.opacity(0.45)),
                                                                 startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                    }
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    if moving {
                        context.stroke(line, with: .linearGradient(Sweep.gradient(phase, color: .white.opacity(0.7), width: 0.12),
                                                                   startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                                       style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }
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
        }
        .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
        .background(compact ? Theme.panelRaised.opacity(0.5) : Theme.panel, in: RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous).stroke(Theme.textFaint.opacity(0.2)))
    }
}

/// Where the power comes from (charger, battery) and where it goes (battery charging, GPU, the rest of the Mac):
/// chips on each side, the Mac as a glowing node in the middle, and ribbons as wide as each share.
private struct PowerFlow: View {
    let sample: PowerSample
    var compact = false
    var live = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Part {
        let icon: String
        let label: String
        let watts: Double
        let color: Color
        let help: String
        /// A step between `color` and the Mac's violet, so the blend doesn't go muddy in the middle.
        var bridge: Color? = nil
    }

    private static let sky = Color(hex: 0x6EB6FF)
    private static let orchid = Color(hex: 0xE08BFF)
    /// The Mac in the middle, where power arrives and splits.
    private static let mac = Theme.violet

    private var sources: [Part] {
        var list: [Part] = []
        if sample.adapterWatts > 0.3 {
            list.append(Part(icon: "powerplug.portrait.fill", label: "Charger", watts: sample.adapterWatts, color: Theme.mint,
                             help: "From the charger", bridge: Color(hex: 0x4CC3FF)))
        }
        if sample.fromBattery > 0.05 || list.isEmpty {
            list.append(Part(icon: "battery.75percent", label: "Battery", watts: sample.fromBattery, color: Theme.amber,
                             help: "From the battery", bridge: Color(hex: 0xFF8FA3)))
        }
        return list
    }

    private var outputs: [Part] {
        var list: [Part] = []
        if let gpu = sample.gpuWatts, gpu > 0.02 {
            list.append(Part(icon: "cpu", label: "Graphics", watts: gpu, color: Self.orchid, help: "Graphics (GPU)"))
        }
        if sample.intoBattery > 0.05 {
            list.append(Part(icon: "battery.100percent.bolt", label: "Charging", watts: sample.intoBattery, color: Theme.mint,
                             help: "Charging the battery"))
        }
        list.append(Part(icon: "ellipsis.circle", label: "Everything else", watts: sample.restWatts, color: Self.sky,
                         help: "The rest of the Mac: processor, screen, storage, and more"))
        return list
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let chipW = w * 0.3, gap: CGFloat = compact ? 6 : 10
            let radius: CGFloat = compact ? 26 : 36
            let center = CGPoint(x: w / 2, y: h / 2)
            let srcBoxes = stack(sources.map(\.watts), height: h, gap: gap, minimum: compact ? 40 : 56)
            let outBoxes = stack(outputs.map(\.watts), height: h, gap: gap, minimum: compact ? 42 : 54)
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live || reduceMotion)) { timeline in
                    let moving = live && !reduceMotion
                    let phase = Sweep.phase(timeline.date)
                    Canvas { context, _ in
                        let waist = radius * 1.5
                        func ribbons(_ parts: [Part], _ boxes: [CGRect], incoming: Bool) {
                            let total = max(parts.map(\.watts).reduce(0, +), 0.001)
                            var y = center.y - waist / 2
                            for (i, part) in parts.enumerated() {
                                let thick = max(4, waist * CGFloat(part.watts / total))
                                let box = boxes[i].insetBy(dx: 0, dy: min(8, boxes[i].height * 0.2))
                                let atNode = (y, y + thick)
                                let edgeX = incoming ? chipW : w - chipW
                                let nodeX = incoming ? center.x - radius * 0.6 : center.x + radius * 0.6
                                let (x0, x1) = incoming ? (edgeX, nodeX) : (nodeX, edgeX)
                                let (a, b) = incoming ? ((box.minY, box.maxY), atNode) : (atNode, (box.minY, box.maxY))
                                let mid = (x0 + x1) / 2
                                var path = Path()
                                path.move(to: CGPoint(x: x0, y: a.0))
                                path.addCurve(to: CGPoint(x: x1, y: b.0), control1: CGPoint(x: mid, y: a.0), control2: CGPoint(x: mid, y: b.0))
                                path.addLine(to: CGPoint(x: x1, y: b.1))
                                path.addCurve(to: CGPoint(x: x0, y: a.1), control1: CGPoint(x: mid, y: b.1), control2: CGPoint(x: mid, y: a.1))
                                path.closeSubpath()
                                let colors = incoming
                                    ? [part.color.opacity(0.7)] + (part.bridge.map { [$0.opacity(0.55)] } ?? []) + [Self.mac.opacity(0.6)]
                                    : [Self.mac.opacity(0.6), part.color.opacity(0.75)]
                                context.fill(path, with: .linearGradient(Gradient(colors: colors),
                                                                         startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                                if moving {
                                    context.fill(path, with: .linearGradient(Sweep.gradient(phase, color: .white.opacity(0.28)),
                                                                             startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                                }
                                y += thick
                            }
                        }
                        ribbons(sources, srcBoxes, incoming: true)
                        ribbons(outputs, outBoxes, incoming: false)
                    }
                }
                ForEach(Array(sources.enumerated()), id: \.offset) { i, part in
                    chip(part).frame(width: chipW, height: srcBoxes[i].height).offset(y: srcBoxes[i].minY)
                }
                ForEach(Array(outputs.enumerated()), id: \.offset) { i, part in
                    chip(part).frame(width: chipW, height: outBoxes[i].height).offset(x: w - chipW, y: outBoxes[i].minY)
                }
                node(radius: radius).position(center)
            }
        }
    }

    /// The Mac: a violet disc with a soft glow and how much it uses.
    private func node(radius: CGFloat) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Self.mac.opacity(0.95), Color(hex: 0x5A4BD6)], center: .topLeading,
                                         startRadius: 0, endRadius: radius * 2))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .shadow(color: Self.mac.opacity(0.6), radius: 10)
            VStack(spacing: 1) {
                Image(systemName: "laptopcomputer").font(.system(size: compact ? 13 : 17, weight: .semibold))
                Text(LocalFormat.watts(sample.systemWatts, digits: 1)).font(.system(size: compact ? 9.5 : 12, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(.white)
        }
        .frame(width: radius * 2, height: radius * 2)
        .help("Your MacBook uses \(LocalFormat.watts(sample.systemWatts))")
    }

    /// A rounded chip: icon and label on top, watts below, tinted by the part's color.
    private func chip(_ part: Part) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: part.icon).font(.system(size: compact ? 10.5 : 13, weight: .semibold)).foregroundStyle(part.color)
                Text(part.label).font(.system(size: compact ? 10.5 : 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(LocalFormat.watts(part.watts)).font(.system(size: compact ? 13 : 16, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, compact ? 9 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(LinearGradient(colors: [part.color.opacity(0.26), part.color.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .background(shape.fill(Theme.panelRaised))
        .overlay(shape.strokeBorder(part.color.opacity(0.45), lineWidth: 1))
        .sweep(shape, color: part.color.opacity(0.25), live: live)
        .help(part.help)
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


/// A soft band of light that sweeps left to right and starts over, for the live parts of the battery view.
/// It only runs while power is being sampled (the menu is open) and stops for Reduce Motion.
struct Sweep {
    static let period = 2.6

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

/// Lays a sweeping band over its content, clipped to `shape`.
private struct SweepOverlay<S: Shape>: ViewModifier {
    let shape: S
    var color: Color = .white.opacity(0.16)
    let live: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live || reduceMotion)) { timeline in
                let phase = Sweep.phase(timeline.date)
                shape.fill(LinearGradient(gradient: Sweep.gradient(phase, color: color), startPoint: .leading, endPoint: .trailing))
                    .opacity(live && !reduceMotion ? 1 : 0)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    fileprivate func sweep<S: Shape>(_ shape: S, color: Color = .white.opacity(0.16), live: Bool) -> some View {
        modifier(SweepOverlay(shape: shape, color: color, live: live))
    }
}
