import AppKit
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
        // Full labels when they fit; on a narrow window only the open tab keeps its name.
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(PeerTab.allCases) { tab in
                let open = model.peerTab == tab
                Button { model.peerTab = tab } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 11))
                        if !compact || open {
                            Text(tab.title).font(.system(size: 12.5, weight: .semibold)).fixedSize()
                        }
                        if let count = badge(tab), count > 0 {
                            Text("\(count)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.mint, in: Capsule())
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(open ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, compact && !open ? 10 : 9).padding(.vertical, 8)
                    .background(open ? Theme.panelRaised : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(open ? Theme.mint.opacity(0.35) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
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

struct EmptyCard: View {
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
                NotificationIcon(item: item, size: 38)
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
                NotificationPicture(item: item, size: 64)
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
                    threadList(data).frame(width: 260)
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                    conversation(data)
                }
                .frame(height: 540)
            }
        }
    }

    // Threads

    private struct Found: Identifiable {
        let thread: SmsThread
        /// The message that matched the search, shown under the name instead of the latest one.
        let match: SmsItem?
        var id: Int64 { thread.id }
    }

    private func found(_ data: PhoneSnapshot) -> [Found] {
        let query = model.smsQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return data.threads.map { Found(thread: $0, match: nil) } }
        return data.threads.compactMap { thread in
            if PhoneSearch.score(name: thread.name, numbers: [thread.address], query: query) != nil {
                return Found(thread: thread, match: nil)
            }
            // Messages are newest first, so this is the latest matching one.
            let hit = data.messages.first { $0.threadId == thread.id && PhoneSearch.textMatches($0.body, query) }
            return hit.map { Found(thread: thread, match: $0) }
        }
    }

    private func threadList(_ data: PhoneSnapshot) -> some View {
        let shown = found(data)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Messages").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                IconButton(icon: "square.and.pencil", help: "New message", tint: model.smsThread == nil ? Theme.mint : Theme.textSecondary) {
                    model.smsThread = nil
                    model.smsAddress = ""
                }
            }
            DyskField(icon: "magnifyingglass", placeholder: "Search name, number, or text", text: $model.smsQuery)
            OptionalScroll(enabled: scrolls) {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { threadRow($0) }
                }
            }
            if shown.isEmpty {
                Text(data.threads.isEmpty ? "No messages received from the phone yet." : "Nothing matches “\(model.smsQuery)”.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textFaint).padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func threadRow(_ item: Found) -> some View {
        let thread = item.thread
        let selected = model.smsThread == thread.id
        let preview = item.match ?? thread.latest
        return Button { model.smsThread = thread.id } label: {
            HStack(spacing: 10) {
                Avatar(name: thread.name, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(thread.name).font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(shortTime(preview.time)).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                    }
                    Text((preview.outgoing ? "You: " : "") + preview.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(item.match != nil ? Theme.mint.opacity(0.9) : Theme.textSecondary)
                        .lineLimit(item.match != nil ? 2 : 1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.panelRaised : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.mint.opacity(0.3) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Conversation

    private func conversation(_ data: PhoneSnapshot) -> some View {
        let thread = data.threads.first { $0.id == model.smsThread }
        let address = thread?.address ?? model.smsAddress
        let canSend = PhoneSearch.digits(address).count >= 3
        let draft = model.smsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            if let thread {
                header(thread, data)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                OptionalScroll(enabled: scrolls) {
                    LazyVStack(spacing: 6) {
                        let items = Array(data.messages.filter { $0.threadId == thread.id }.reversed())
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || !Calendar.current.isDate(date(items[index - 1].time), inSameDayAs: date(item.time)) {
                                dayLabel(item.time)
                            }
                            bubble(item)
                        }
                    }
                    .padding(14)
                }
                .defaultScrollAnchor(.bottom)
            } else {
                recipient(data)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                statusLine(data)
                HStack(alignment: .bottom, spacing: 8) {
                    DyskField(placeholder: canSend ? "Write an SMS" : "Choose who it's for first", text: $model.smsDraft,
                              multiline: true, clearable: false) {
                        // Return again while sending does nothing, so an SMS isn't sent twice.
                        if canSend, !draft.isEmpty, data.pendingSms == nil { model.sendSms(to: address, on: peer.id) }
                    }
                    Button { model.sendSms(to: address, on: peer.id) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36)
                            .background(Theme.accentGradient, in: Circle())
                            .opacity(canSend && !draft.isEmpty ? 1 : 0.35)
                    }
                    .buttonStyle(.plain)
                    .disabled(!peer.isConnected || data.pendingSms != nil || !canSend || draft.isEmpty)
                    .help("Send (Return). Option-Return adds a new line.")
                }
                HStack {
                    Text(peer.isConnected ? "Sent from \(peer.name)'s SIM. Return sends, Option-Return adds a line." : "\(peer.name) isn't connected.")
                    Spacer()
                    if model.smsDraft.count > 0 {
                        // One SMS holds 160 plain characters, or 70 with emoji and other special letters.
                        let limit = model.smsDraft.unicodeScalars.allSatisfy { $0.isASCII } ? 160 : 70
                        Text("\(model.smsDraft.count) / \(limit)\(model.smsDraft.count > limit ? " · \((model.smsDraft.count + limit - 1) / limit) SMS" : "")")
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ thread: SmsThread, _ data: PhoneSnapshot) -> some View {
        HStack(spacing: 10) {
            Avatar(name: thread.name, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if thread.name != thread.address {
                    Text(thread.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            IconButton(icon: "doc.on.doc", help: "Copy the number") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(thread.address, forType: .string)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// "To" for a new message: type a name or a number, and matching contacts show up to pick.
    private func recipient(_ data: PhoneSnapshot) -> some View {
        let picked = data.name(for: model.smsAddress)
        let isPicked = !model.smsAddress.isEmpty && picked != model.smsAddress
        let suggestions = isPicked || model.smsAddress.trimmingCharacters(in: .whitespaces).isEmpty
            ? [] : Array(PhoneSearch.contacts(data.contacts, query: model.smsAddress).prefix(6))
        return VStack(alignment: .leading, spacing: 10) {
            Text("New message").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            if isPicked {
                HStack(spacing: 10) {
                    Avatar(name: picked, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(picked).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(model.smsAddress).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    IconButton(icon: "xmark", help: "Choose someone else") { model.smsAddress = "" }
                }
                .padding(8)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                DyskField(icon: "person", placeholder: "To: a name or a number", text: $model.smsAddress) {
                    if let first = suggestions.first, !PhoneSearch.isNumber(model.smsAddress), let number = first.phones.first {
                        model.smsAddress = number
                    }
                }
                if !suggestions.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(suggestions) { contact in
                            ForEach(contact.phones, id: \.self) { number in
                                Button { model.smsAddress = number } label: {
                                    HStack(spacing: 10) {
                                        Avatar(name: contact.name, size: 28)
                                        Text(contact.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(number).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textFaint)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(4)
                    .background(Theme.panelRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else if !model.smsAddress.isEmpty, !PhoneSearch.isNumber(model.smsAddress) {
                    Text(data.contacts.isEmpty ? "Contacts aren't shared from the phone, so type a number." : "No contact with that name. Type a number instead.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
                }
            }
        }
        .padding(14)
    }

    private func dayLabel(_ milliseconds: Int64) -> some View {
        let value = date(milliseconds)
        let text = Calendar.current.isDateInToday(value) ? "Today"
            : Calendar.current.isDateInYesterday(value) ? "Yesterday"
            : value.formatted(date: .abbreviated, time: .omitted)
        return Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Theme.panelRaised.opacity(0.6), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func bubble(_ item: SmsItem) -> some View {
        HStack {
            if item.outgoing { Spacer(minLength: 50) }
            VStack(alignment: item.outgoing ? .trailing : .leading, spacing: 3) {
                Text(item.body).font(.system(size: 12.5)).textSelection(.enabled)
                    .foregroundStyle(item.outgoing ? Theme.ink : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(date(item.time).formatted(date: .omitted, time: .shortened)).font(.system(size: 9.5))
                    .foregroundStyle(item.outgoing ? Theme.ink.opacity(0.6) : Theme.textFaint)
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(item.outgoing ? Theme.mint : Theme.panelRaised,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !item.outgoing { Spacer(minLength: 50) }
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
            let query = model.contactQuery.trimmingCharacters(in: .whitespaces)
            // The full list is sorted once when it arrives; only a search sorts here.
            let shown = query.isEmpty ? data.sortedContacts : PhoneSearch.contacts(data.contacts, query: query)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    DyskField(icon: "magnifyingglass", placeholder: "Search a name or a number, like 0812 or +62 812", text: $model.contactQuery)
                    Button("Export vCard") { model.exportContacts(of: peer.id) }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Save as a .vcf file that opens in the Contacts app")
                        .disabled(data.contacts.isEmpty)
                }
                Text(query.isEmpty ? "\(data.contacts.count) contacts" : "\(shown.count) of \(data.contacts.count) contacts match")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textFaint).padding(.leading, 2)
                if shown.isEmpty {
                    EmptyCard(text: data.contacts.isEmpty ? "No contacts received from the phone yet." : "No contact matches “\(query)”.")
                } else if query.isEmpty {
                    // Alphabetical, under a letter, when not searching.
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(data.contactSections) { section in
                            SectionLabel(section.letter)
                            list(section.contacts)
                        }
                    }
                } else {
                    list(shown)
                }
            }
        }
    }

    private func list(_ contacts: [ContactItem]) -> some View {
        Card(padding: 4) {
            LazyVStack(spacing: 0) {
                ForEach(Array(contacts.enumerated()), id: \.element.id) { index, contact in
                    if index > 0 { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 56) }
                    row(contact)
                }
            }
        }
    }

    private func row(_ contact: ContactItem) -> some View {
        let sms = model.phone(peer.id).features.contains("sms")
        return HStack(alignment: .top, spacing: 12) {
            Avatar(name: contact.name, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                ForEach(contact.phones, id: \.self) { number in
                    HStack(spacing: 6) {
                        Text(number).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        Spacer(minLength: 8)
                        IconButton(icon: "doc.on.doc", help: "Copy \(number)") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(number, forType: .string)
                        }
                        if sms {
                            IconButton(icon: "message.fill", help: "Send an SMS to \(number)", tint: Theme.mint) { model.composeSms(to: number) }
                        }
                    }
                }
                if contact.phones.isEmpty {
                    Text("No number").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
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
            .toggleStyle(DyskSwitchStyle(fills: false)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
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
            cameraCard
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

    private var cameraCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Phone camera").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(cameraStatus).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.camera?.peerId == peer.id {
                        Button("Stop") { model.stopCamera() }.buttonStyle(SecondaryButtonStyle(tint: Theme.coral))
                    } else if model.cameraRequests.contains(peer.id) {
                        Button("Cancel") { model.cancelCameraRequest(for: peer.id) }.buttonStyle(SecondaryButtonStyle())
                    } else if peer.isConnected {
                        Button("Use camera") { model.requestCamera(from: peer.id) }.buttonStyle(PrimaryButtonStyle())
                            // One phone camera is shown at a time.
                            .disabled(model.camera != nil)
                            .help(model.camera.map { "\($0.peerName)'s camera is open. Close it first." } ?? "")
                    }
                }
                if let error = model.cameraError[peer.id] {
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral)
                }
            }
        }
    }

    private var cameraStatus: String {
        if model.camera?.peerId == peer.id {
            return "Showing in a separate window. For Zoom or Meet, capture that window in OBS and start OBS Virtual Camera."
        }
        if model.cameraRequests.contains(peer.id) { return "Tap the notification on the phone to start the camera." }
        return "Use the phone as a camera on this Mac. It starts only after you tap the notification on the phone, and can also be started from the phone."
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
                // One phone screen is shown at a time.
                .disabled(model.screen != nil)
                .help(model.screen.map { "\($0.peerName)'s screen is open. Close it first." } ?? "")
        }
    }
}
