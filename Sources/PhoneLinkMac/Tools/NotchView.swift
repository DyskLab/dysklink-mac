import AppKit
import SwiftUI

struct NotchView: View {
    let model: NotchModel
    let tools: ToolsModel
    var phoneProvider: () -> [Peer] = { Shared.model.peers.filter { $0.isPaired && $0.isConnected && !$0.isComputer } }
    var transfersProvider: () -> [Transfer] = { Shared.model.transfers }
    var sendFile: (URL, String) -> Void = { Shared.model.sendFile($0, to: $1) }
    var alertsProvider: () -> [PhoneAlert] = { Shared.model.phoneAlerts }
    var dismissAlert: (PhoneAlert) -> Void = { Shared.model.dismissNotification($0.item.key, on: $0.peerId) }
    /// Snapshots turn scrolling off, because they can't draw a scroll view.
    var scrolls = true

    /// Status sits under the notch, so it never covers the menu bar on either side.
    private static let statusHeight: CGFloat = 24
    /// Room on each side for the page arrows.
    private static let sideRoom: CGFloat = 44

    private var hasStatus: Bool { model.peek != nil || model.isFocusing || model.isWatched }
    static let noticeWidth: CGFloat = 400

    private var shape: NotchShape {
        if model.isOpen {
            return NotchShape(width: model.openSize.width - 16, height: model.openSize.height,
                              bottomRadius: 30, topRadius: 8)
        }
        let base = model.closedSize
        if model.hasBanner {
            return NotchShape(width: max(base.width, Self.noticeWidth), height: model.closedHeight(statusHeight: Self.statusHeight),
                              bottomRadius: 22, topRadius: 0)
        }
        return NotchShape(width: base.width, height: model.closedHeight(statusHeight: Self.statusHeight),
                          bottomRadius: hasStatus ? 12 : (model.hasNotch ? 9 : 3), topRadius: 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            statusRow
                .opacity(!model.isOpen && hasStatus && !model.hasBanner ? 1 : 0)
                .padding(.top, model.closedSize.height)
            if let code = model.code, !model.isOpen {
                CodeBanner(notice: code) { model.copyCode() } close: { model.hideCode() }
                    .frame(width: max(model.closedSize.width, Self.noticeWidth) - 28, height: NotchModel.noticeHeight)
                    .padding(.top, model.closedSize.height)
                    .transition(.opacity)
            } else if let notice = model.notice, !model.isOpen {
                NoticeBanner(alert: notice)
                    .frame(width: max(model.closedSize.width, Self.noticeWidth) - 28, height: NotchModel.noticeHeight)
                    .padding(.top, model.closedSize.height)
                    .transition(.opacity)
            }
            // The open content is always laid out, so opening only has to reveal it.
            openContent
                .frame(width: model.openSize.width - 28, height: model.openSize.height, alignment: .top)
                .opacity(model.isOpen ? 1 : 0)
                .allowsHitTesting(model.isOpen)
                .mask(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if let peek = model.peek {
                Text(peek).lineLimit(1)
            } else if model.isWatched {
                Image(systemName: model.screenWatchers.isEmpty ? "headphones" : "eye.fill").foregroundStyle(Theme.coral)
                Text(model.watchText).lineLimit(1).minimumScaleFactor(0.8)
                if model.isFocusing {
                    FocusClock(model: model).foregroundStyle(Theme.violet)
                }
            } else if model.isFocusing {
                Image(systemName: model.pomodoro.phase == .focus ? "timer" : "cup.and.saucer.fill")
                    .foregroundStyle(model.pomodoro.phase == .focus ? Theme.violet : Theme.mint)
                FocusClock(model: model)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.white)
        .frame(width: model.closedSize.width, height: Self.statusHeight)
    }

    // MARK: Frame

    private var openContent: some View {
        VStack(spacing: 8) {
            header.frame(height: 26)
            ZStack {
                page
                    .padding(.horizontal, Self.sideRoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.pages.count > 1 {
                    HStack {
                        arrow("chevron.left", label: "Previous page", step: -1)
                        Spacer()
                        arrow("chevron.right", label: "Next page", step: 1)
                    }
                }
            }
            dots.opacity(model.pages.count > 1 ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, NotchModel.contentTop(hasNotch: model.hasNotch, notchHeight: model.closedSize.height))
        .padding(.bottom, 12)
    }

    @ViewBuilder private var page: some View {
        switch model.page {
        case .music: music
        case .focus: focus
        case .shelf: shelf
        case .prayer: prayerPage
        case .weather: weatherPage
        case .todo: todoPage
        case .water: waterPage
        case .note: notePage
        case .alerts: alertsPage
        }
    }

    private var header: some View {
        // The two sides share what the centred date leaves, so a long title truncates instead of running under it.
        HStack(spacing: 10) {
            title.frame(maxWidth: .infinity, alignment: .leading)
            dateAndTime.fixedSize()
            accessory.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Self.sideRoom - 12)
    }

    @ViewBuilder private var title: some View {
        let name = model.page == .shelf && !model.isShown(.files) ? "Clipboard" : model.page.rawValue
        if !name.isEmpty {
            HStack(spacing: 10) {
                Group {
                    if model.page == .todo {
                        Text("Todo ").foregroundColor(.white) + Text("list").foregroundColor(Color(hex: 0x62D17A))
                    } else if model.page == .water {
                        Text("Water").foregroundColor(Color(hex: 0x6EB6FF))
                    } else {
                        Text(name).foregroundColor(.white)
                    }
                }
                .font(.system(size: 16, weight: .bold)).lineLimit(1)
                // The page name keeps its room; the place beside it truncates first.
                .layoutPriority(1)
                placeLabel
            }
        }
    }

    @ViewBuilder private var accessory: some View {
        if model.page == .shelf {
            if model.hasShelfSwitch { shelfSwitch }
        } else if model.isShown(.music) {
            Button { model.page = .music } label: { AudioBars(isPlaying: model.nowPlaying?.isPlaying == true, isShown: model.isOpen) }
                .buttonStyle(.plain)
                .help("Music")
        }
    }

    private var shelfSwitch: some View {
            HStack(spacing: 2) {
                modeButton("folder", label: "Files", mode: .files)
                modeButton("doc.on.clipboard", label: "Clipboard", mode: .clipboard)
            }
            .padding(2)
            .background(Color.white.opacity(0.1), in: Capsule())
    }

    private func modeButton(_ icon: String, label: String, mode: NotchModel.ShelfMode) -> some View {
        Button { model.shelfMode = mode } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 20)
                .background(model.shelfMode == mode ? Theme.violet : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var dateAndTime: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(spacing: 8) {
                if let percent = model.power.percent {
                    NotchBatteryRing(percent: percent, isCharging: model.power.isCharging)
                        .help("This Mac \(percent)%")
                }
                Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.white)
                if let peer = phoneProvider().first, let percent = peer.info?.batteryPercent {
                    HStack(spacing: 2) {
                        Image(systemName: peer.info?.isCharging == true ? "bolt.fill" : "iphone.gen3").font(.system(size: 9))
                        Text("\(percent)%").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(Color.white.opacity(0.7))
                    .help("\(peer.name) \(percent)%")
                }
            }
        }
    }

    private func arrow(_ icon: String, label: String, step: Int) -> some View {
        Button { turnPage(step) } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func turnPage(_ step: Int) {
        let pages = model.pages
        guard !pages.isEmpty else { return }
        let index = pages.firstIndex(of: model.page) ?? 0
        withAnimation(.easeOut(duration: 0.18)) {
            model.page = pages[(index + step + pages.count) % pages.count]
        }
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(model.pages, id: \.self) { item in
                let isCurrent = item == model.page
                Capsule()
                    .fill(Color.white.opacity(isCurrent ? 1 : 0.35))
                    .frame(width: isCurrent ? 16 : 5, height: 5)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { model.page = item } }
            }
        }
        .frame(height: 13)
    }

    // MARK: Music

    private var music: some View {
        // The song position only moves while the panel is open and something plays.
        TimelineView(.animation(minimumInterval: 1, paused: !model.isOpen || model.nowPlaying?.isPlaying != true)) { context in
            let playing = model.nowPlaying
            HStack(spacing: 14) {
                player(playing, at: context.date)
                    .frame(width: model.lyrics.isOn ? 230 : nil)
                if model.lyrics.isOn {
                    Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).padding(.vertical, 4)
                    LyricsColumn(lyrics: model.lyrics, elapsed: playing?.elapsed(at: context.date))
                }
            }
            .task(id: "\(model.lyrics.isOn)|\(playing?.title ?? "")|\(playing?.artist ?? "")") {
                await model.lyrics.load(for: playing)
            }
        }
    }

    private func player(_ playing: NowPlaying?, at date: Date) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Artwork(image: model.currentArtwork)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(playing?.title ?? "Nothing playing")
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(Color.white).lineLimit(1)
                        Text(playing.map { $0.artist.isEmpty ? " " : $0.artist } ?? "Play something in Music, Spotify, or YouTube")
                            .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let playing, let duration = playing.duration, let elapsed = playing.elapsed(at: date) {
                    HStack(spacing: 10) {
                        Text(NotchModel.clock(elapsed)).monospacedDigit()
                        ProgressBar(value: duration > 0 ? elapsed / duration : 0, color: Color.white)
                        Text("-" + NotchModel.clock(duration - elapsed)).monospacedDigit()
                    }
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.white)
                }
                Spacer(minLength: 0)
                HStack(spacing: 26) {
                    mediaButton("backward.fill", label: "Previous", action: "previous", size: 15)
                    mediaButton(playing?.isPlaying == true ? "pause.fill" : "play.fill", label: "Play or pause",
                                action: "play_pause", size: 19)
                    mediaButton("forward.fill", label: "Next", action: "next", size: 15)
                    Button { model.lyrics.isOn.toggle() } label: {
                        Image(systemName: "quote.bubble\(model.lyrics.isOn ? ".fill" : "")").font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(model.lyrics.isOn ? 1 : 0.6)).frame(width: 32, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(model.lyrics.isOn ? "Hide lyrics" : "Show lyrics from lrclib.net")
                }
                .frame(maxWidth: .infinity)
            }
    }

    private func mediaButton(_ icon: String, label: String, action: String, size: CGFloat) -> some View {
        Button { action == "play_pause" ? model.playPause() : DeviceInput.media(action) } label: {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(Color.white).frame(width: 32, height: 28)
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: Pomodoro

    private var focus: some View {
        let timer = model.pomodoro
        // Redrawn every second only while it's on screen and running.
        return TimelineView(.animation(minimumInterval: 1, paused: !model.isOpen || !timer.isRunning)) { context in
            focusBody(timer, now: model.clockDate(timer.isRunning ? context.date : model.now))
        }
    }

    private func focusBody(_ timer: Pomodoro, now: Date) -> some View {
        HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(phaseText(timer)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.6))
                    Text(NotchModel.clock(timer.remaining(at: now)))
                        .font(.system(size: 38, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.white)
                    HStack(spacing: 6) {
                        Text(Self.duration(timer.remainingInCycle(at: now))).foregroundStyle(Color.white)
                        Text("until done").foregroundStyle(Theme.violet)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    ProgressBar(value: timer.progress(at: now), color: Theme.violet).padding(.top, 6)
                }
                .frame(width: 180, alignment: .leading)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("This round").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.6))
                        Spacer()
                        Button(timer.isRunning ? "Pause" : (timer.isStarted ? "Resume" : "Start")) { model.togglePomodoro() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Color.white.opacity(0.14), in: Capsule())
                        Button { model.resetPomodoro() } label: {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.white).frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!timer.isStarted)
                        .help("Reset")
                    }
                    PomodoroSteps(timer: timer, now: now)
                    Text("\(Self.duration(timer.settings.cycleLength)) · \(timer.sessions) sessions")
                        .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
                }
            }
    }

    private func phaseText(_ timer: Pomodoro) -> String {
        switch timer.phase {
        case .focus: return "Focus · \(timer.session) of \(timer.sessions)"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: Shelf

    @ViewBuilder private var shelf: some View {
        switch model.shelfMode {
        case .files: files
        case .clipboard: clipboard
        }
    }

    private var files: some View {
        HStack(spacing: 8) {
            shelfZone
            if let phone = phoneProvider().first {
                phoneZone(phone).frame(width: 150)
            }
        }
    }

    private var shelfZone: some View {
        VStack(spacing: 6) {
            if model.shelf.isEmpty {
                Spacer(minLength: 0)
                Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 22)).foregroundStyle(Color.white.opacity(0.85))
                Text("Drop files here").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.white)
                Text("Drag out anytime · click to open").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
                Spacer(minLength: 0)
            } else {
                row {
                    HStack(spacing: 6) {
                        ForEach(model.shelf) { item in shelfCard(item) }
                    }
                    .padding(.horizontal, 8)
                }
                Text("\(model.shelf.count) \(model.shelf.count == 1 ? "file" : "files") · drag out anytime · click to open")
                    .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 6)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        }
    }

    private func shelfCard(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 42, height: 42)
            Text(item.name).font(.system(size: 10.5)).foregroundStyle(Color.white)
                .lineLimit(2).multilineTextAlignment(.center).frame(width: 84)
            HStack(spacing: 8) {
                if let phone = phoneProvider().first {
                    Button("Send") { send([item.url], to: phone) }.buttonStyle(.plain)
                        .foregroundStyle(Theme.mint)
                        .help("Send to \(phone.name)")
                }
                Button("Remove") { model.remove(item) }.buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .font(.system(size: 10, weight: .semibold))
        }
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
    }

    /// Files dropped here go straight to the phone. The last one sent shows its progress.
    private func phoneZone(_ phone: Peer) -> some View {
        let latest = transfersProvider().first { $0.peerId == phone.id && $0.outgoing }
        return VStack(spacing: 5) {
            Spacer(minLength: 0)
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 20)).foregroundStyle(model.isPhoneTargeted ? Theme.mint : Color.white.opacity(0.85))
            Text("Send to phone").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white)
            Text(phone.name).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1)
            Spacer(minLength: 0)
            if let latest {
                transferLine(latest)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.isPhoneTargeted ? Theme.mint.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(model.isPhoneTargeted ? Theme.mint : Color.white.opacity(0.28),
                              style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        )
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            send(urls, to: phone)
        } isTargeted: { model.isPhoneTargeted = $0 }
    }

    private func transferLine(_ transfer: Transfer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(transfer.name).lineLimit(1).truncationMode(.middle)
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.8))
            switch transfer.status {
            case .active:
                ProgressBar(value: transfer.size > 0 ? Double(transfer.transferred) / Double(transfer.size) : 0, color: Theme.mint)
            case .done:
                Label("Sent", systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.mint)
            case .failed:
                Text(transfer.detail ?? "Not sent").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.amber).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @discardableResult
    private func send(_ urls: [URL], to phone: Peer) -> Bool {
        let files = Self.sendable(urls)
        guard !files.isEmpty else {
            model.showPeek("Only files can be sent, not folders")
            return false
        }
        files.forEach { sendFile($0, phone.id) }
        model.showPeek(files.count == 1 ? "Sending to \(phone.name)" : "Sending \(files.count) files to \(phone.name)")
        return true
    }

    /// Folders and missing files are left out, because only single files can be sent.
    static func sendable(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            var isFolder: ObjCBool = false
            return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && !isFolder.boolValue
        }
    }

    private var clipboard: some View {
        Group {
            if !tools.isClipboardOn {
                Text("Turn on Clipboard History in Advanced to see it here.")
                    .font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let items = Array(tools.clipboard.matches("").prefix(20))
                VStack(alignment: .leading, spacing: 6) {
                    if items.isEmpty {
                        Text("Nothing copied yet").font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        row {
                            HStack(spacing: 8) {
                                ForEach(items) { entry in clipCard(entry, isNewest: entry.id == tools.clipboard.entries.first?.id) }
                            }
                        }
                        Text("\(tools.clipboard.entries.count) items · click to copy")
                            .font(.system(size: 11.5)).foregroundStyle(Color.white.opacity(0.5))
                    }
                }
            }
        }
    }

    private func clipCard(_ entry: ClipEntry, isNewest: Bool) -> some View {
        Button { tools.clipboard.copy(entry); model.showPeek("Copied") } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let text = entry.text {
                    Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.white)
                        .lineLimit(3).multilineTextAlignment(.leading)
                } else if let name = entry.imageFile, let image = tools.clipboard.thumbnail(name) {
                    Image(nsImage: image).resizable().scaledToFill().frame(height: 46).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if entry.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                    Text(Self.ago(entry.date))
                }
                .font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.45))
            }
            .padding(10)
            .frame(width: 104, height: 96, alignment: .topLeading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isNewest ? Theme.violet : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) { content() }
        } else {
            content().frame(maxWidth: .infinity, alignment: .leading).clipped()
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// A thin bar with a rounded fill.
private struct ProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(color).frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 5)
    }
}

/// The Mac's battery as a small ring, green while charging or above a fifth.
private struct NotchBatteryRing: View {
    let percent: Int
    let isCharging: Bool

    var body: some View {
        let color = isCharging || percent > 20 ? Color(hex: 0x34C759) : Theme.amber
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
            Circle().trim(from: 0, to: Double(percent) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
    }
}

/// The Pomodoro countdown under the closed notch. It ticks on its own, so the rest of the notch isn't redrawn each second.
private struct FocusClock: View {
    let model: NotchModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !model.pomodoro.isRunning)) { context in
            Text(model.focusText(at: context.date)).monospacedDigit()
        }
    }
}

/// Bars that move while music plays and rest otherwise. They hold still while the panel is closed.
private struct AudioBars: View {
    let isPlaying: Bool
    var isShown = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isPlaying || !isShown)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    let resting: [CGFloat] = [5, 9, 13, 9, 5]
                    let height = isPlaying ? 4 + 10 * abs(sin(time * 5 + Double(index) * 1.3)) : resting[index]
                    Capsule().fill(Color.white).frame(width: 2.5, height: height)
                }
            }
            .frame(width: 26, height: 16)
        }
    }
}

/// Album art or a video thumbnail when it could be read, otherwise a stand-in.
private struct Artwork: View {
    var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Theme.violet, Theme.mint.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.white))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Every step of the cycle: long bars for focus, dots for short breaks, and a bar for the long break.
private struct PomodoroSteps: View {
    let timer: Pomodoro
    let now: Date

    var body: some View {
        let current = timer.isStarted ? timer.stepIndex : -1
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ForEach(Array(timer.steps.enumerated()), id: \.offset) { index, step in
                    let fill: Double = index < current ? 1 : (index == current ? timer.progress(at: now) : 0)
                    if step.phase == .shortBreak {
                        Circle().fill(fill > 0 ? Theme.mint : Color.white.opacity(0.2)).frame(width: 6, height: 6)
                    } else {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                Capsule().fill(step.phase == .longBreak ? Theme.mint : Theme.violet)
                                    .frame(width: proxy.size.width * fill)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
            HStack(spacing: 5) {
                ForEach(Array(timer.steps.enumerated()), id: \.offset) { _, step in
                    if step.phase == .shortBreak {
                        Color.clear.frame(width: 6, height: 1)
                    } else {
                        Text(step.phase == .longBreak ? "Long" : "\(step.session)")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
