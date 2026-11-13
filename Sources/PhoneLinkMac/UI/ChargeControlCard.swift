import SwiftUI

/// Charge limit, sailing, discharge on power, heat protection, and calibration, in Mac Care › Battery.
struct ChargeControlCard: View {
    @Bindable var control: ChargeControl

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                status
                if !control.available {
                    note("This Mac has no charger switch DyskLink can use, so charging can't be controlled from here.")
                } else {
                    if !control.installed { installBanner }
                    controls
                        .disabled(!control.installed || control.busy)
                        .opacity(control.installed ? 1 : 0.45)
                }
                if let error = control.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coralText).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Parts

    private var status: some View {
        HStack(spacing: 10) {
            Text("Charging control").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if control.busy { ProgressView().controlSize(.small) }
            if control.installed && control.available {
                StatusPill(text: control.reason.label, color: control.reason.adapterOn ? Theme.mint : Theme.amber)
            }
        }
    }

    private var installBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            note("""
            macOS 27 no longer lets apps pause charging, so DyskLink switches the charger input off instead and the Mac \
            runs on battery while plugged in. That needs a small helper with admin rights. It can only turn the charger \
            input on or off, and every minute it turns it back on if DyskLink isn't running or the battery is below 10%. \
            Restarting the Mac turns it back on too.
            """)
            HStack(spacing: 10) {
                Button("Install helper…") { control.install() }.buttonStyle(PrimaryButtonStyle()).disabled(control.busy)
                Text("Asks for your admin password once.").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var controls: some View {
        let settings = $control.settings
        VStack(alignment: .leading, spacing: 11) {
            row("battery.25percent", "Charge limit",
                help: "Charging stops here and the Mac runs on battery. Set 100% to turn it off. To hold the battery exactly at 80–100%, the Charge Limit in System Settings › Battery works too.") {
                NumberBox(value: Binding(get: { control.settings.limiter ? control.settings.limit : 100 },
                                         set: { control.settings.limit = min(max($0, 20), 100); control.settings.limiter = $0 < 100 }),
                          range: ChargeSettings.limitRange)
                Text("%").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            row("bolt.badge.automatic", "Discharge on power",
                help: "Runs the Mac on battery with the charger plugged in until the battery is down to the charge limit, then the limit takes over. With no limit, it runs on battery until the battery is low.") {
                Switch(isOn: settings.discharge)
            }
            row("paperplane", "Sailing mode",
                help: "After the limit is reached, the Mac stays on battery until it falls by the difference, so the battery isn't topped up a little all the time.") {
                Switch(isOn: settings.sailing)
            }
            if let hint = control.holdHint {
                VStack(alignment: .leading, spacing: 8) {
                    Text(hint).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Open Battery Settings") { NSWorkspace.shared.open(PowerSettings.batterySettings) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mintText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if control.reason == .held || (control.nativeLimit ?? 100) <= control.settings.limit && control.settings.limiter {
                Text("macOS's Charge Limit holds the battery at \(control.nativeLimit ?? control.settings.limit)% while the charger runs the Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.mintText).fixedSize(horizontal: false, vertical: true)
            }
            if control.settings.sailing {
                panel {
                    HStack(spacing: 10) {
                        Text("Difference:")
                        NumberBox(value: settings.sail, range: ChargeSettings.sailRange)
                        Text("%")
                        Image(systemName: "arrow.right").foregroundStyle(Theme.textSecondary)
                        Text(control.settings.limiter ? "Will sail to \(control.settings.limit - control.settings.sail)%." : "Set a charge limit to sail.")
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 11) {
            row("flame", "Heat protection", help: "Pauses charging while the battery is warmer than the limit, and goes on once it's two degrees cooler.") {
                Switch(isOn: settings.heat)
            }
            panel {
                HStack(spacing: 10) {
                    if control.settings.heat {
                        Text("Pause above")
                        NumberBox(value: Binding(get: { Int(control.settings.heatLimit) }, set: { control.settings.heatLimit = Double($0) }), range: 35...50)
                        Text("°C.")
                    } else {
                        Text("Heat protection deactivated.")
                    }
                    Text("Current: \(control.temperature.map(LocalFormat.celsius) ?? "—")")
                        .foregroundStyle((control.temperature ?? 0) >= control.settings.heatLimit ? Theme.coralText : Theme.textPrimary)
                }
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                label("slider.vertical.3", "Calibration mode",
                      help: "Runs the battery down on the charger, fills it, and rests at full, so the percentage shown is accurate again. Keep the charger plugged in the whole time. Needs the Charge Limit in System Settings at 100%.")
                Spacer(minLength: 8)
                Button { control.calibration == .off ? control.startCalibration() : control.cancelCalibration() } label: {
                    Label(control.calibration == .off ? "Start calibration" : "Stop calibration",
                          systemImage: control.calibration == .off ? "play" : "stop")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(Theme.panelRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            panel { CalibrationSteps(phase: control.calibration, limit: control.settings.limiter ? control.settings.limit : nil) }
            HStack(spacing: 6) {
                if let warning = control.nativeLimitNote {
                    Text(warning).font(.system(size: 12)).foregroundStyle(Theme.amberText).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("Last calibration: \(control.lastCalibration.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "never")")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                Image(systemName: "checkmark.seal").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        if control.installed {
            HStack {
                Spacer()
                Button("Remove helper") { control.remove() }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func row<Trailing: View>(_ icon: String, _ title: String, help: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            label(icon, title, help: help)
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func label(_ icon: String, _ title: String, help: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).frame(width: 20)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            HelpMark(text: help)
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
            .padding(.vertical, 11).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A question mark that explains a setting on hover.
private struct HelpMark: View {
    let text: String

    var body: some View {
        Image(systemName: "questionmark.circle").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).help(text)
    }
}

/// A themed on/off switch. Drawn here, so it matches the app and shows in snapshots.
private struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.mint : Theme.panelRaised)
                Circle().fill(isOn ? Theme.onAccent : Theme.textSecondary).padding(3)
            }
            .frame(width: 40, height: 23)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A small number box. Typed numbers are kept within the range when editing ends.
private struct NumberBox: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 46, height: 26)
            .background(Theme.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.textFaint.opacity(0.35)))
    }
}

/// The calibration steps, with the current one lit.
private struct CalibrationSteps: View {
    let phase: CalibrationPhase
    let limit: Int?

    private struct Step: Identifiable {
        let id: Int
        let kind: BatteryGlyph.Kind
        let text: String
    }

    private var steps: [Step] {
        var list = [
            Step(id: 0, kind: .drain, text: "Discharge\nto \(CalibrationPhase.drainTo)%"),
            Step(id: 1, kind: .charge, text: "Charge to\n100%"),
            Step(id: 2, kind: .hold, text: "Hold for\n1h"),
        ]
        if let limit { list.append(Step(id: 3, kind: .drainTop, text: "Discharge\nto \(limit)%")) }
        return list
    }

    private var current: Int? {
        switch phase {
        case .off: nil
        case .draining: 0
        case .charging: 1
        case .holding: 2
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(steps) { step in
                if step.id > 0 {
                    Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(maxWidth: 30)
                }
                VStack(spacing: 6) {
                    BatteryGlyph(kind: step.kind).opacity(current == nil || current == step.id ? 1 : 0.4)
                    Text(step.text).font(.system(size: 11)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(current == step.id ? Theme.mintText : Theme.textPrimary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// An upright battery with a sign: plus to charge, minus to discharge, pause to hold.
private struct BatteryGlyph: View {
    enum Kind { case charge, drain, drainTop, hold }
    let kind: Kind

    var body: some View {
        let (fill, level, symbol): (Color, CGFloat, String) = switch kind {
        case .charge: (Theme.mint, 1, "plus")
        case .drain: (Theme.amber, 0.45, "minus")
        case .drainTop: (Theme.amber, 0.7, "minus")
        case .hold: (Theme.sky, 1, "pause.fill")
        }
        VStack(spacing: 1.5) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.textSecondary).frame(width: 7, height: 2.5)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.textPrimary.opacity(0.9))
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill.opacity(0.75))
                    .frame(height: 25 * level).padding(2)
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onAccent)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 17, height: 29)
        }
    }
}
