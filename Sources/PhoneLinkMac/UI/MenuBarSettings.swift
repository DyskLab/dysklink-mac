import SwiftUI

/// Advanced › Menu bar: turn each part of the menu on or off and change the order.
struct MenuBarSettings: View {
    let layout: MenuBarLayout
    /// Off in snapshots, which show the list open.
    var expanded: Bool? = nil

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Menu bar").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Choose what the DyskLink menu shows. Drag a row to change the order. \(layout.visible.count) of \(layout.order.count) parts are on.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Reset") { layout.reset() }.buttonStyle(SecondaryButtonStyle())
                }
                VStack(spacing: 2) {
                    ForEach(Array(layout.order.enumerated()), id: \.element) { index, section in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                                .help("Drag to change the order")
                            Image(systemName: section.icon).font(.system(size: 13)).foregroundStyle(layout.isShown(section) ? Theme.mint : Theme.textFaint)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.label).font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(layout.isShown(section) ? Theme.textPrimary : Theme.textSecondary)
                                if let needs = section.needs, layout.isShown(section) {
                                    Text(needs).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                                }
                            }
                            Spacer()
                            IconButton(icon: "chevron.up", help: "Move up") { layout.move(section, by: -1) }
                                .opacity(index == 0 ? 0.3 : 1).disabled(index == 0)
                            IconButton(icon: "chevron.down", help: "Move down") { layout.move(section, by: 1) }
                                .opacity(index == layout.order.count - 1 ? 0.3 : 1).disabled(index == layout.order.count - 1)
                            Toggle("", isOn: Binding(get: { layout.isShown(section) }, set: { layout.setShown(section, $0) }))
                                .labelsHidden().toggleStyle(.dyskSwitch).fixedSize()
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8)
                        .background(layout.dropTarget == section ? Theme.mint.opacity(0.14) : index.isMultiple(of: 2) ? Theme.contrast.opacity(0.025) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                        .draggable(section.rawValue) {
                            Label(section.label, systemImage: section.icon).font(.system(size: 13, weight: .medium))
                                .padding(8).background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first.flatMap(MenuBarLayout.Section.init(rawValue:)) else { return false }
                            withAnimation(.easeOut(duration: 0.15)) { layout.place(dragged, at: section) }
                            return true
                        } isTargeted: { over in
                            if over { layout.dropTarget = section } else if layout.dropTarget == section { layout.dropTarget = nil }
                        }
                    }
                }
            }
        }
    }
}
