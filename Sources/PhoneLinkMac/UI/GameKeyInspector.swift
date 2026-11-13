import SwiftUI

/// The side panel beside the phone picture while editing game keys: profile, a palette to add controls, the placed
/// controls, and the selected one's settings.
struct GameKeysPanel: View {
    static let width: CGFloat = 260
    let game: GameKeysModel
    /// Snapshots can't draw scroll views or menus, so they get plain stand-ins.
    var scrolls = true

    static let palette: [(GameKey.Kind, String, String)] = [
        (.tap, "Tap key", "hand.tap"), (.joystick, "Joystick", "dpad"), (.skill, "Skill aim", "target"),
        (.swipe, "Swipe", "hand.draw"), (.look, "Look area", "scope"), (.fire, "Click spot", "cursorarrow.click"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill").foregroundStyle(Theme.mint)
                if scrolls {
                    GameProfileMenu(game: game)
                } else {
                    Text(game.profileName + " ▾").font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Button("Done") { game.editing = false; ScreenWindow.focusSurface() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mintText)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider().overlay(Theme.stroke)
            scroller {
                VStack(alignment: .leading, spacing: 12) {
                    section("Add a control") { paletteGrid }
                    section("Placed (\(game.keys.count)) · \(game.freeFingers) free finger\(game.freeFingers == 1 ? "" : "s")") { list }
                    if let key = game.selectedKey {
                        section("Settings") { GameKeyInspector(game: game, key: key) }
                    } else if !game.keys.isEmpty {
                        Text("Select a control in the list or on the picture to change it.")
                            .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                    }
                }
                .padding(12)
            }
            if !game.keys.isEmpty {
                Divider().overlay(Theme.stroke)
                HStack {
                    Spacer()
                    Button("Clear all") { game.clear() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.coralText)
                }
                .padding(.horizontal, 12).frame(height: 30)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textPrimary)
        .controlSize(.small)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    @ViewBuilder
    private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if scrolls { ScrollView { content() } } else { content().frame(maxHeight: .infinity, alignment: .top) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textFaint)
            content()
        }
    }

    private var paletteGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Self.palette, id: \.1) { kind, name, icon in
                    let on = game.placing == kind
                    Button {
                        game.placing = on ? nil : kind
                        ScreenWindow.focusSurface()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: icon).frame(width: 14)
                            Text(name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(on ? Theme.onAccent : Theme.textPrimary)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(on ? Theme.mint : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(game.placing != nil ? "Now click the picture to place it. Esc cancels."
                 : "Pick one, then click the picture. Shortcuts: click + key, drag + key (swipe), ⌥/⇧/⌘-click.")
                .font(.system(size: 10)).foregroundStyle(game.placing != nil ? Theme.amberText : Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var list: some View {
        VStack(spacing: 2) {
            if game.keys.isEmpty {
                Text("Nothing placed yet.").font(.system(size: 10)).foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(game.keys) { key in
                let on = game.selected == key.id
                Button { game.selected = key.id; ScreenWindow.focusSurface() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: GameKeyInspector.icon(key)).frame(width: 14).foregroundStyle(Theme.mint)
                        Text(GameKeyInspector.title(key))
                        Spacer(minLength: 4)
                        Text(GameKeyInspector.keyText(key)).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 6).frame(height: 22)
                    .background(on ? Theme.panelRaised : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Each game keeps its own layout.
struct GameProfileMenu: View {
    let game: GameKeysModel

    var body: some View {
        Menu {
            ForEach(Array(game.profiles.enumerated()), id: \.offset) { index, profile in
                Button { game.selectProfile(index) } label: {
                    if index == game.current { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) }
                }
            }
            Divider()
            Button("New game…") { if let name = GameProfileNames.ask("New game", value: "") { game.addProfile(named: name) } }
            Button("Rename \(game.profileName)…") {
                if let name = GameProfileNames.ask("Rename game", value: game.profileName) { game.renameProfile(name) }
            }
            Button(game.profiles.count > 1 ? "Delete \(game.profileName)" : "Clear keys", role: .destructive) { game.deleteProfile() }
            if game.hasLook {
                Divider()
                Picker("Aim speed", selection: Binding(get: { game.lookSpeed }, set: { game.lookSpeed = $0 })) {
                    Text("Slow").tag(0.6)
                    Text("Normal").tag(1.0)
                    Text("Fast").tag(1.7)
                }
            }
        } label: {
            Text(game.profileName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Game profile: each game keeps its own keys")
    }
}

/// The selected game key's settings while editing: kind, key, mode, and the rest.
struct GameKeyInspector: View {
    let game: GameKeysModel
    let key: GameKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if key.isAction { kindPicker }
            switch key.kind {
            case .joystick: joystickSection
            case .tap: tapSection
            case .skill: skillSection
            case .swipe: swipeSection
            case .look: radiusStepper("Area")
            case .fire: note("The mouse button presses this spot while aiming with `.")
            }
            if game.conflicts(key) { note("⚠︎ Another control uses the same keyboard key. The first one wins.", color: Theme.amber) }
            Button { game.remove(key.id); refocus() } label: {
                Label("Delete this control", systemImage: "trash").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.coralText).padding(.top, 2)
        }
        .padding(10)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    static func keyText(_ key: GameKey) -> String {
        switch key.kind {
        case .joystick: key.directionLabels.joined()
        case .look: "`"
        case .fire: "Mouse"
        default: key.label
        }
    }

    static func title(_ key: GameKey) -> String {
        switch key.kind {
        case .joystick: "Joystick"
        case .look: "Look area"
        case .fire: "Click spot"
        case .skill: "Skill aim"
        case .swipe: "Swipe"
        case .tap: ["Tap", "Hold toggle", "Auto-fire", "Combo"][GameKey.Mode.allCases.firstIndex(of: key.mode) ?? 0]
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: GameKeyInspector.icon(key)).foregroundStyle(Theme.mint)
            Text(Self.title(key)).font(.system(size: 12, weight: .semibold))
            Spacer()
        }
    }

    static func icon(_ key: GameKey) -> String {
        switch key.kind {
        case .joystick: "dpad"
        case .look: "scope"
        case .fire: "cursorarrow.click"
        case .skill: "target"
        case .swipe: "hand.draw"
        case .tap: ["hand.tap", "lock", "bolt.fill", "list.number"][GameKey.Mode.allCases.firstIndex(of: key.mode) ?? 0]
        }
    }

    private var kindPicker: some View {
        Picker("", selection: Binding(get: { key.kind }, set: { game.setKind(key.id, $0) })) {
            Text("Tap").tag(GameKey.Kind.tap)
            Text("Skill").tag(GameKey.Kind.skill)
            Text("Swipe").tag(GameKey.Kind.swipe)
        }
        .pickerStyle(.segmented).labelsHidden()
    }

    private var keyRow: some View {
        HStack {
            Text("Key").foregroundStyle(Theme.textSecondary)
            Spacer()
            let waiting = game.capture == .key(key.id)
            // A field-like button: click it, then press the new key.
            Button { game.capture = waiting ? nil : .key(key.id); refocus() } label: {
                Text(waiting ? "Press a key…" : key.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(waiting ? Theme.amberText : Theme.textPrimary)
                    .frame(width: 110, height: 22)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(waiting ? Theme.amber : Theme.stroke))
            }
            .buttonStyle(.plain)
            .help("Click, then press the key for this control")
        }
    }

    // MARK: Joystick

    private var joystickSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Keys", selection: binding(\.keySet)) {
                Text("WASD").tag(GameKey.KeySet.wasd)
                Text("Arrows").tag(GameKey.KeySet.arrows)
                Text("IJKL").tag(GameKey.KeySet.ijkl)
                Text("Custom").tag(GameKey.KeySet.custom)
            }
            if case .stickKeys(let id, let codes, _) = game.capture, id == key.id {
                Text("Press the key for \(["up", "left", "down", "right"][codes.count])… Esc stops.").foregroundStyle(Theme.amberText)
            } else if key.keySet == .custom {
                HStack {
                    Text(key.directionLabels.joined(separator: " ")).font(.system(size: 11, weight: .bold))
                    Spacer()
                    Button("Pick 4 keys") { game.capture = .stickKeys(key.id, [], []); refocus() }
                }
            }
            Picker("Walk", selection: binding(\.walk)) {
                Text("Off").tag(GameKey.Walk.off)
                Text("Hold for full").tag(GameKey.Walk.fullWithKey)
                Text("Hold for half").tag(GameKey.Walk.halfWithKey)
            }
            if key.walk != .off {
                Picker("Modifier", selection: binding(\.walkKey)) {
                    Text("⇧ Shift").tag(UInt16(56))
                    Text("⌃ Control").tag(UInt16(59))
                    Text("⌥ Option").tag(UInt16(58))
                }
            }
            radiusStepper("Reach")
        }
    }

    // MARK: Tap

    private var tapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            keyRow
            Picker("Mode", selection: binding(\.mode)) {
                Text("Tap").tag(GameKey.Mode.tap)
                Text("Hold toggle").tag(GameKey.Mode.toggle)
                Text("Auto-fire").tag(GameKey.Mode.autoFire)
                Text("Combo").tag(GameKey.Mode.combo)
            }
            switch key.mode {
            case .tap: note("Down while the key is held.")
            case .toggle: note("Press once to hold, again to let go.")
            case .autoFire:
                Stepper(value: binding(\.rate), in: 1...20, step: 1) { Text("\(Int(key.rate)) taps a second") }
            case .combo: comboSection
            }
        }
    }

    private var recording: Bool { game.capture == .combo(key.id) }

    private var comboSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(recording ? "Stop recording" : "Record combo") {
                    if recording { game.capture = nil } else { game.recordCombo(key.id) }
                    refocus()
                }
                Spacer()
                Button("+ Wait") {
                    game.update(key.id) { $0.steps.append(GameKey.Step(kind: .wait, ms: 80)) }
                    refocus()
                }
                .disabled(key.steps.isEmpty)
            }
            if recording { note("Click spots in order; drag for a swipe.", color: Theme.amber) }
            if key.steps.isEmpty && !recording { note("No steps yet: the key taps its own spot.") }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(key.steps.enumerated()), id: \.element.id) { index, step in stepRow(index, step) }
                }
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: key.steps.count < 7)
        }
    }

    private func stepRow(_ index: Int, _ step: GameKey.Step) -> some View {
        HStack(spacing: 4) {
            Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textFaint).frame(width: 16, alignment: .trailing)
            switch step.kind {
            case .tap:
                Text("Tap  \(Int(step.x * 100)), \(Int(step.y * 100))")
            case .swipe:
                Stepper(value: stepMs(step.id), in: 20...2000, step: 20) { Text("Swipe \(Int(step.ms)) ms") }
            case .wait:
                Stepper(value: stepMs(step.id), in: 0...5000, step: 10) { Text("Wait \(Int(step.ms)) ms") }
            }
            Spacer(minLength: 0)
            Button { game.update(key.id) { $0.steps.removeAll { $0.id == step.id } } } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
        }
    }

    private func stepMs(_ id: UUID) -> Binding<Double> {
        Binding(get: { key.steps.first { $0.id == id }?.ms ?? 0 },
                set: { value in game.update(key.id) { k in
                    if let i = k.steps.firstIndex(where: { $0.id == id }) { k.steps[i].ms = value }
                } })
    }

    // MARK: Skill

    private var skillSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            keyRow
            radiusStepper("Aim reach")
            Toggle("Quick cast: a short press taps", isOn: binding(\.quickCast))
            note("Hold the key and point with the mouse, measured from the screen's middle. Let go casts; Esc cancels.")
        }
    }

    // MARK: Swipe

    private var swipeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            keyRow
            HStack(spacing: 4) {
                Text("From the spot").foregroundStyle(Theme.textSecondary)
                Spacer()
                ForEach([("arrow.up", GameKeysModel.Direction.up), ("arrow.down", .down), ("arrow.left", .left), ("arrow.right", .right)], id: \.0) { icon, direction in
                    Button { game.swipePreset(key.id, direction); refocus() } label: { Image(systemName: icon) }
                }
            }
            Stepper(value: binding(\.duration), in: 20...2000, step: 20) { Text("Takes \(Int(key.duration)) ms") }
            note("Drag the arrow's head to change where it ends.")
        }
    }

    // MARK: Parts

    private func radiusStepper(_ name: String) -> some View {
        Stepper(value: binding(\.radius), in: 0.03...0.25, step: 0.01) { Text("\(name) \(Int((key.radius * 100).rounded()))% of width") }
    }

    private func note(_ text: String, color: Color = Theme.textSecondary) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(Theme.text(color)).fixedSize(horizontal: false, vertical: true)
    }

    private func binding<T>(_ path: WritableKeyPath<GameKey, T>) -> Binding<T> {
        let id = key.id
        return Binding(get: { game.keys.first { $0.id == id }?[keyPath: path] ?? key[keyPath: path] },
                       set: { value in game.update(id) { $0[keyPath: path] = value } })
    }

    /// Keys go back to the picture after a button, so the next key press is read.
    private func refocus() {
        DispatchQueue.main.async { ScreenWindow.focusSurface() }
    }
}
