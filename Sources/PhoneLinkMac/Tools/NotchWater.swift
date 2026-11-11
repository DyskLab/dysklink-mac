import SwiftUI

extension NotchView {
    var waterPage: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            WaterPanel(water: model.water, now: context.date)
        }
    }
}

struct WaterPanel: View {
    let water: WaterModel
    let now: Date

    private static let blue = Color(hex: 0x4FA3FF)

    var body: some View {
        HStack(spacing: 14) {
            summary.frame(width: 262, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).padding(.vertical, 4)
            if water.showsSettings { settings } else { chart }
        }
    }

    // MARK: Left side

    private var summary: some View {
        let total = water.total(now)
        let goal = water.settings.goalMl
        let reached = total >= goal
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(WaterModel.litres(total)).font(.system(size: 38, weight: .bold).monospacedDigit()).foregroundStyle(Color.white)
                Text("/ \(WaterModel.litres(goal)) L").font(.system(size: 15, weight: .medium)).foregroundStyle(Color.white.opacity(0.5))
                Spacer(minLength: 0)
                Button { water.settings.reminds.toggle() } label: {
                    Image(systemName: water.settings.reminds ? "bell.fill" : "bell.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(water.settings.reminds ? Color.white : Color.white.opacity(0.6))
                        .frame(width: 30, height: 26)
                        .background(water.settings.reminds ? Self.blue : Color.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(water.settings.reminds ? "Reminders on" : "Reminders off")
            }
            HStack(spacing: 4) {
                Text("Today ·").foregroundStyle(Color.white.opacity(0.55))
                Text("\(Int((water.fraction(now) * 100).rounded()))%").foregroundStyle(Self.blue).fontWeight(.bold)
                if reached { Text("· Goal reached").foregroundStyle(Color.white.opacity(0.55)) }
            }
            .font(.system(size: 12.5))
            Capsule().fill(Color.white.opacity(0.14)).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { box in
                        Capsule().fill(LinearGradient(colors: [Color(hex: 0x6FD0FF), Color(hex: 0x4A63F5)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: box.size.width * water.fraction(now))
                    }
                }
            HStack(spacing: 8) {
                pill("drop.fill", "Drink", fill: Color(hex: 0x214F8F)) { water.drink() }
                pill("slider.horizontal.3", water.showsSettings ? "Chart" : "Settings", fill: Color.white.opacity(0.14)) {
                    water.showsSettings.toggle()
                }
                if water.total(now) > 0 {
                    Button { water.undo() } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.white).frame(width: 26, height: 26)
                            .background(Color.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Undo the last drink")
                }
            }
            .padding(.top, 3)
        }
    }

    private func pill(_ icon: String, _ text: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Chart

    private var chart: some View {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let first = max(0, hour - 7)
        let hours = Array(first...max(first, first + 7))
        let drunk = water.log.byHour(on: now)
        let top = max(400, ((drunk.values.max() ?? 0) + 99) / 100 * 100)
        return HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(hours, id: \.self) { slot in
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            Capsule().fill(Color.white.opacity(0.08)).frame(width: 12, height: 64)
                            if let ml = drunk[slot], ml > 0 {
                                Capsule().fill(LinearGradient(colors: [Color(hex: 0x6FB6FF), Color(hex: 0x2E5FC8)], startPoint: .top, endPoint: .bottom))
                                    .frame(width: 12, height: max(6, 64 * Double(ml) / Double(top)))
                            }
                        }
                        Text(slot % 3 == 0 ? LocalFormat.hour(slot) : " ")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.white.opacity(0.5))
                            .lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            VStack(alignment: .trailing) {
                Text("\(top)").frame(height: 14, alignment: .top)
                Spacer(minLength: 0)
                Text("0 ml").frame(height: 14, alignment: .bottom)
                Spacer().frame(height: 18)
            }
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.white.opacity(0.5))
            .frame(width: 38, height: 96)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(spacing: 6) {
            stepper("Goal", "\(WaterModel.litres(water.settings.goalMl)) L", WaterSettings.goalChoices, \.goalMl)
            stepper("Glass", "\(water.settings.glassMl) ml", WaterSettings.glassChoices, \.glassMl)
            stepper("Every", "\(water.settings.remindEveryMinutes) min", WaterSettings.intervalChoices, \.remindEveryMinutes)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepper(_ title: String, _ value: String, _ choices: [Int], _ key: WritableKeyPath<WaterSettings, Int>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7)).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            stepButton("minus") { move(choices, key, -1) }
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Color.white)
                .frame(width: 62)
            stepButton("plus") { move(choices, key, 1) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white)
                .frame(width: 24, height: 24).background(Color.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func move(_ choices: [Int], _ key: WritableKeyPath<WaterSettings, Int>, _ step: Int) {
        guard let index = choices.firstIndex(of: water.settings[keyPath: key]) else { return }
        water.settings[keyPath: key] = choices[min(max(index + step, 0), choices.count - 1)]
    }
}
