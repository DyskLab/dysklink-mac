import SwiftUI

enum CallText {
    static func label(_ state: String) -> String {
        switch state {
        case "ringing": return "Incoming"
        case "answered": return "Answered"
        case "missed": return "Missed"
        case "outgoing": return "Outgoing"
        default: return "Ended"
        }
    }
}

private func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

private func shortTime(_ milliseconds: Int64) -> String {
    let value = date(milliseconds)
    return Calendar.current.isDateInToday(value)
        ? value.formatted(date: .omitted, time: .shortened)
        : value.formatted(date: .abbreviated, time: .omitted)
}

struct PeerTabBar: View {
    let model: AppModel
    let peer: Peer

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PeerTab.allCases) { tab in
                Button { model.peerTab = tab } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 11))
                        Text(tab.title).font(.system(size: 12.5, weight: .semibold)).fixedSize()
                        if let count = badge(tab), count > 0 {
                            Text("\(count)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.mint, in: Capsule())
                        }
                    }
                    .foregroundStyle(model.peerTab == tab ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 8)
                    .background(model.peerTab == tab ? Theme.panelRaised : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(model.peerTab == tab ? Theme.mint.opacity(0.35) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func badge(_ tab: PeerTab) -> Int? {
        tab == .notifications ? model.phone(peer.id).notifications.count : nil
    }
}

/// Shown when the feature is off on the phone. The Mac can't turn it on by itself.
struct FeatureOffCard: View {
    let title: String

    var body: some View {
        Card(padding: 26) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.amber)
                    Text("\(title): turned off on the phone").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text("Open DyskLink on the phone, choose this Mac, then tap Phone data for Mac. It can only be turned on from the phone.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct EmptyCard: View {
    let text: String

    var body: some View {
        Card(padding: 26) {
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textFaint)
        }
    }
}

// MARK: - Notifications

struct NotificationsTab: View {
    let model: AppModel
    let peer: Peer

    var body: some View {
        let data = model.phone(peer.id)
        if !data.features.contains("notifications") {
            FeatureOffCard(title: "Notifications")
        } else if data.notifications.isEmpty {
            EmptyCard(text: "No notifications on the phone.")
        } else {
            VStack(spacing: 10) {
                ForEach(data.notifications) { item in row(item) }
            }
        }
    }

    private func row(_ item: NotificationItem) -> some View {
        Card {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.app).font(.system(size: 11.5, weight: .bold)).foregroundStyle(Theme.mint)
                        Text(shortTime(item.time)).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                    if let title = item.title {
                        Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    }
                    if let text = item.text {
                        Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
                if peer.isConnected {
                    Button { model.dismissNotification(item.key, on: peer.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26)
                            .background(Theme.panelRaised, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss the notification on the phone")
                }
            }
        }
    }
}

// MARK: - Messages

struct MessagesTab: View {
    @Bindable var model: AppModel
    let peer: Peer
    let scrolls: Bool

    var body: some View {
        let data = model.phone(peer.id)
        if !data.features.contains("sms") {
            FeatureOffCard(title: "SMS")
        } else {
            Card(padding: 0) {
                HStack(spacing: 0) {
                    threadList(data).frame(width: 210)
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                    conversation(data)
                }
                .frame(height: 470)
            }
        }
    }

    private func threadList(_ data: PhoneSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("New message") {
                model.smsThread = nil
                model.smsAddress = ""
            }
            .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.mint)
            .padding(.horizontal, 6)
            OptionalScroll(enabled: scrolls) {
                VStack(spacing: 4) {
                    ForEach(data.threads) { thread in threadRow(thread) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private func threadRow(_ thread: SmsThread) -> some View {
        Button { model.smsThread = thread.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.name).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(shortTime(thread.latest.time)).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                }
                Text(thread.latest.body).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.smsThread == thread.id ? Theme.panelRaised : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func conversation(_ data: PhoneSnapshot) -> some View {
        let thread = data.threads.first { $0.id == model.smsThread }
        return VStack(alignment: .leading, spacing: 10) {
            if let thread {
                Text(thread.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                OptionalScroll(enabled: scrolls) {
                    VStack(spacing: 6) {
                        ForEach(data.messages.filter { $0.threadId == thread.id }.reversed()) { bubble($0) }
                    }
                }
                .defaultScrollAnchor(.bottom)
            } else {
                TextField("Recipient number", text: $model.smsAddress).textFieldStyle(.roundedBorder)
            }
            Spacer(minLength: 0)
            statusLine(data)
            HStack(spacing: 8) {
                TextField("Write an SMS", text: $model.smsDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Send") { model.sendSms(to: thread?.address ?? model.smsAddress, on: peer.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!peer.isConnected || data.pendingSms != nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bubble(_ item: SmsItem) -> some View {
        HStack {
            if item.outgoing { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.body).font(.system(size: 12.5)).textSelection(.enabled)
                    .foregroundStyle(item.outgoing ? Theme.ink : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(shortTime(item.time)).font(.system(size: 9.5))
                    .foregroundStyle(item.outgoing ? Theme.ink.opacity(0.6) : Theme.textFaint)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(item.outgoing ? Theme.mint : Theme.panelRaised,
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            if !item.outgoing { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private func statusLine(_ data: PhoneSnapshot) -> some View {
        switch data.smsStatus {
        case .sending: Text("Sending through the phone…").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        case .sent: Text("Delivered to the carrier").font(.system(size: 11.5)).foregroundStyle(Theme.mint)
        case .failed(let message): Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.coral)
        case nil: EmptyView()
        }
    }
}

// MARK: - Contacts

struct ContactsTab: View {
    @Bindable var model: AppModel
    let peer: Peer

    var body: some View {
        let data = model.phone(peer.id)
        if !data.features.contains("contacts") {
            FeatureOffCard(title: "Contacts")
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    TextField("Search name or number", text: $model.contactQuery).textFieldStyle(.roundedBorder)
                    Button("Export vCard") { model.exportContacts(of: peer.id) }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Save as a .vcf file that opens in the Contacts app")
                }
                let shown = filtered(data.contacts)
                if shown.isEmpty {
                    EmptyCard(text: data.contacts.isEmpty ? "No contacts received from the phone yet." : "No matching contacts.")
                } else {
                    // LazyVStack keeps the view light with thousands of contacts.
                    LazyVStack(spacing: 8) {
                        ForEach(shown) { row($0) }
                    }
                }
            }
        }
    }

    private func filtered(_ contacts: [ContactItem]) -> [ContactItem] {
        let query = model.contactQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return contacts }
        return contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(query) || contact.phones.contains { $0.contains(query) }
        }
    }

    private func row(_ contact: ContactItem) -> some View {
        Card(padding: 13) {
            VStack(alignment: .leading, spacing: 5) {
                Text(contact.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                ForEach(contact.phones, id: \.self) { number in
                    HStack {
                        Text(number).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        Spacer()
                        if model.phone(peer.id).features.contains("sms") {
                            Button("SMS") { model.composeSms(to: number) }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Files

struct FilesTab: View {
    let model: AppModel
    let peer: Peer

    var body: some View {
        let data = model.phone(peer.id)
        if !data.features.contains("files") {
            FeatureOffCard(title: "File access")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                pathBar(data)
                selectionBar(data)
                if let error = data.filesError {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral)
                }
                ForEach(model.transfers.filter { $0.peerId == peer.id && !$0.outgoing }) { TransferRow(transfer: $0) }
                if data.filesLoading && data.entries.isEmpty {
                    EmptyCard(text: "Opening folder…")
                } else if data.entries.isEmpty {
                    EmptyCard(text: "This folder is empty.")
                } else {
                    Card(padding: 8) {
                        LazyVStack(spacing: 2) {
                            ForEach(data.entries) { row($0, in: data.folder) }
                        }
                    }
                }
                Text("Read-only. Downloaded files go to Downloads/DyskLink.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func pathBar(_ data: PhoneSnapshot) -> some View {
        HStack(spacing: 8) {
            Button {
                let parent = (data.folder as NSString).deletingLastPathComponent
                model.openPhoneFolder(parent, on: peer.id)
            } label: {
                Image(systemName: "chevron.up").frame(width: 14, height: 14)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(data.folder.isEmpty || !peer.isConnected)
            Text(data.folder.isEmpty ? "Internal storage" : data.folder)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.head)
            Spacer()
            Button("Reload") { model.openPhoneFolder(data.folder, on: peer.id) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                .disabled(!peer.isConnected)
        }
    }

    private func selectionBar(_ data: PhoneSnapshot) -> some View {
        let files = data.entries.filter { !$0.isDirectory }
        return HStack(spacing: 12) {
            Toggle("Show hidden", isOn: Binding(
                get: { model.phone(peer.id).showHidden },
                set: { model.setShowHidden($0, on: peer.id) }
            ))
            .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            .disabled(!peer.isConnected)
            Spacer()
            if !files.isEmpty {
                Button(data.selectedFiles.count == files.count ? "Clear selection" : "Select all") {
                    model.toggleSelectAllFiles(on: peer.id)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
            }
            if !data.selectedFiles.isEmpty && peer.isConnected {
                Button("Download \(data.selectedFiles.count)") { model.downloadSelectedFiles(on: peer.id) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func row(_ entry: FsEntry, in folder: String) -> some View {
        let path = folder.isEmpty ? entry.name : "\(folder)/\(entry.name)"
        let isSelected = model.phone(peer.id).selectedFiles.contains(entry.name)
        return HStack(spacing: 10) {
            if !entry.isDirectory {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Theme.mint : Theme.textFaint).frame(width: 16)
            }
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(entry.isDirectory ? Theme.mint : Theme.textSecondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 13))
                    .foregroundStyle(entry.name.hasPrefix(".") ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail(entry)).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            if !entry.isDirectory && peer.isConnected {
                Button("Download") { model.downloadPhoneFile(path, on: peer.id) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
            }
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !entry.isDirectory {
                model.toggleFileSelection(entry.name, on: peer.id)
            } else if peer.isConnected {
                model.openPhoneFolder(path, on: peer.id)
            }
        }
    }

    private func detail(_ entry: FsEntry) -> String {
        let time = shortTime(entry.modified)
        return entry.isDirectory ? time : "\(Format.bytes(entry.size)), \(time)"
    }
}

// MARK: - Screen

struct ScreenTab: View {
    let model: AppModel
    let peer: Peer

    var body: some View {
        let data = model.phone(peer.id)
        VStack(alignment: .leading, spacing: 14) {
            screenCard(data)
            if !data.features.contains("control") {
                FeatureOffCard(title: "Control from Mac")
            }
        }
    }

    @ViewBuilder
    private func screenCard(_ data: PhoneSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Phone screen").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(screenStatus(data)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    screenButton(data)
                }
                if let error = model.screenError[peer.id] {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral)
                }
            }
        }
    }

    private func screenStatus(_ data: PhoneSnapshot) -> String {
        if model.screen?.peerId == peer.id { return "Showing in a separate window. Click and drag there to control the phone." }
        if model.screenRequests.contains(peer.id) { return "Tap the notification on the phone, then approve the Android dialog." }
        if data.features.contains("screen") { return "The phone asks for your approval every time the screen is shared." }
        return "Start from the phone with the Share the screen button, or turn on Screen requests on the phone to start from here."
    }

    @ViewBuilder
    private func screenButton(_ data: PhoneSnapshot) -> some View {
        if model.screen?.peerId == peer.id {
            Button("Stop") { model.stopScreen() }.buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
        } else if model.screenRequests.contains(peer.id) {
            Button("Cancel") { model.cancelScreenRequest(for: peer.id) }.buttonStyle(SecondaryButtonStyle())
        } else if data.features.contains("screen") && peer.isConnected {
            Button("Request screen") { model.requestScreen(from: peer.id) }.buttonStyle(PrimaryButtonStyle())
        }
    }
}
