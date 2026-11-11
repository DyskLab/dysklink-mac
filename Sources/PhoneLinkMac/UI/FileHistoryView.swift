import AppKit
import SwiftUI

/// Every file sent to or received from any device, kept on this Mac.
struct FileHistoryView: View {
    @Bindable var model: AppModel
    var scrolls = true

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", received = "Received", sent = "Sent"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .all: return "tray.full"
            case .received: return "arrow.down"
            case .sent: return "arrow.up"
            }
        }

        var tint: Color {
            switch self {
            case .all: return Theme.textPrimary
            case .received: return Theme.mint
            case .sent: return Theme.violet
            }
        }

        func includes(_ record: FileRecord) -> Bool {
            switch self {
            case .all: return true
            case .received: return !record.outgoing
            case .sent: return record.outgoing
            }
        }
    }

    var body: some View {
        let records = model.history.filter(model.historyFilter.includes)
        OptionalScroll(enabled: scrolls) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("File history").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        Text("Files sent and received with every device. The list stays on this Mac, and clearing it leaves the files alone.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    if !model.history.isEmpty {
                        Button("Clear history") { model.clearHistory() }.buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                    }
                }
                filterTabs
                if records.isEmpty {
                    Card {
                        Text(model.history.isEmpty ? "No files yet. Files you send or receive appear here." : "Nothing here.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textFaint)
                    }
                } else {
                    Card(padding: 8) {
                        VStack(spacing: 0) {
                            ForEach(records) { record in
                                row(record)
                                if record.id != records.last?.id { Rectangle().fill(Theme.stroke).frame(height: 1) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 28)
        }
    }

    /// All, Received, and Sent, each with how many files it holds.
    private var filterTabs: some View {
        HStack(spacing: 4) {
            ForEach(Filter.allCases) { filter in
                let selected = model.historyFilter == filter
                let count = model.history.filter(filter.includes).count
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.historyFilter = filter }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: filter.symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(selected ? filter.tint : Theme.textFaint)
                        Text(filter.rawValue)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        Text("\(count)")
                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(selected ? Theme.ink : Theme.textFaint)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(selected ? filter.tint.opacity(0.9) : Color.white.opacity(0.06), in: Capsule())
                    }
                    .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule().fill(Theme.panelRaised)
                                .overlay(Capsule().strokeBorder(filter.tint.opacity(0.35)))
                                .shadow(color: filter.tint.opacity(0.18), radius: 8, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Show \(filter == .all ? "all files" : filter.rawValue.lowercased() + " files")")
            }
        }
        .padding(4)
        .background(Theme.panel.opacity(0.82), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .fixedSize()
    }

    private func row(_ record: FileRecord) -> some View {
        let exists = record.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return HStack(spacing: 12) {
            Image(systemName: record.outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(record.ok ? (record.outgoing ? Theme.violet : Theme.mint) : Theme.coral)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle(record)).font(.system(size: 11.5)).foregroundStyle(record.ok ? Theme.textSecondary : Theme.coral)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if record.ok, exists, let url = record.url {
                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            } else if record.ok, record.path != nil {
                Text("Moved or deleted").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
            Button { model.removeFromHistory(record.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
            .help("Remove from the list")
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
    }

    private func subtitle(_ record: FileRecord) -> String {
        let direction = record.outgoing ? "To \(record.device)" : "From \(record.device)"
        let when = record.date.formatted(date: .abbreviated, time: .shortened)
        if !record.ok { return "\(direction) · \(when) · \(record.detail ?? "Failed")" }
        return "\(direction) · \(when) · \(Format.bytes(record.size))"
    }
}
