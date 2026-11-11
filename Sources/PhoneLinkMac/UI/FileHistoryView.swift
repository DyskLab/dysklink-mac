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
        let counts = Self.counts(model.history)
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
                filterTabs(counts)
                if records.isEmpty {
                    Card {
                        Text(model.history.isEmpty ? "No files yet. Files you send or receive appear here." : "Nothing here.")
                            .font(.system(size: 13)).foregroundStyle(Theme.textFaint)
                    }
                } else {
                    Card(padding: 8) {
                        LazyVStack(spacing: 0) {
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
        // Whether each file is still there is checked off the main thread when the page opens or the list changes,
        // not on every redraw.
        .task(id: model.history.map(\.id)) { await model.checkHistoryFiles() }
    }

    /// How many files each tab holds, counted in one pass.
    private static func counts(_ history: [FileRecord]) -> [Filter: Int] {
        let sent = history.reduce(0) { $0 + ($1.outgoing ? 1 : 0) }
        return [.all: history.count, .sent: sent, .received: history.count - sent]
    }

    /// All, Received, and Sent, each with how many files it holds.
    private func filterTabs(_ counts: [Filter: Int]) -> some View {
        HStack(spacing: 6) {
            ForEach(Filter.allCases) { filter in
                TabPill(icon: filter.symbol, title: filter.rawValue, isSelected: model.historyFilter == filter,
                        count: counts[filter] ?? 0,
                        help: "Show \(filter == .all ? "all files" : filter.rawValue.lowercased() + " files")") {
                    withAnimation(.easeOut(duration: 0.18)) { model.historyFilter = filter }
                }
            }
        }
        .fixedSize()
    }

    private func row(_ record: FileRecord) -> some View {
        let exists = record.path != nil && !model.missingHistoryFiles.contains(record.id)
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
