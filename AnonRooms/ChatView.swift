import SwiftUI
import Supabase

@MainActor
final class ChatModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var loading = true
    @Published var noticeText: String?

    let room: Room
    private var listenTask: Task<Void, Never>?

    init(room: Room) {
        self.room = room
    }

    func start() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            await self?.listen()
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
    }

    private func listen() async {
        let roomID = room.id.uuidString.lowercased()
        let channel = await Backend.client.channel("room-\(roomID)")
        let inserts = await channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages",
            filter: "room_id=eq.\(roomID)"
        )
        await channel.subscribe()

        // Istoricul se încarcă după abonare, ca să nu se piardă mesaje între cele două.
        await reload()

        let decoder = JSONDecoder()
        for await insert in inserts {
            if Task.isCancelled { break }
            if let message = try? insert.decodeRecord(as: Message.self, decoder: decoder) {
                append(message)
            }
        }
        await channel.unsubscribe()
    }

    func reload() async {
        do {
            let history = try await Backend.fetchMessages(roomID: room.id)
            let known = Set(history.map(\.id))
            messages = history + messages.filter { !known.contains($0.id) }
        } catch {
            noticeText = Backend.friendlyMessage(error)
        }
        loading = false
    }

    private func append(_ message: Message) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        if messages.count > 300 { messages.removeFirst(messages.count - 300) }
    }

    func send(_ text: String) async -> Bool {
        do {
            try await Backend.send(roomID: room.id, body: text)
            return true
        } catch {
            noticeText = Backend.friendlyMessage(error)
            return false
        }
    }

    func remove(_ message: Message) {
        messages.removeAll { $0.id == message.id }
    }

    func removeAll(from userID: UUID) {
        messages.removeAll { $0.userID == userID }
    }
}

struct ChatView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var model: ChatModel
    @State private var draft = ""
    @State private var sending = false
    @State private var reportTarget: Message?
    @FocusState private var inputFocused: Bool

    init(room: Room) {
        _model = StateObject(wrappedValue: ChatModel(room: room))
    }

    private var visibleMessages: [Message] {
        let blocked = app.blockedIDs
        return model.messages.filter { !blocked.contains($0.userID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.loading {
                            ProgressView().frame(maxWidth: .infinity)
                        } else if visibleMessages.isEmpty {
                            Text(L("chat.empty"))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        ForEach(visibleMessages) { message in
                            MessageRow(message: message, isMine: message.userID == app.userID, theme: model.room.theme)
                                .id(message.id)
                                .contextMenu { menu(for: message) }
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: visibleMessages.last?.id) { lastID in
                    guard let lastID else { return }
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }

            if let notice = model.noticeText {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("chat.placeholder"), text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(trimmedDraft.isEmpty || sending)
                .accessibilityLabel(L("chat.send"))
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .background(RoomBackdrop(room: model.room))
        .tint(model.room.theme.primary)
        .navigationTitle(Text(verbatim: "\(model.room.emoji) \(model.room.name)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(model.room.theme.gradient, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if model.room.isPrivate, let code = model.room.inviteCode {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: L("chat.share", model.room.name, code)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(L("chat.shareCode"))
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog(
            L("chat.report.title"),
            isPresented: Binding(
                get: { reportTarget != nil },
                set: { if !$0 { reportTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(["report.harassment", "report.sexual", "report.spam", "report.other"], id: \.self) { reason in
                Button(L(reason)) {
                    if let target = reportTarget { report(target, reason: reason) }
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder
    private func menu(for message: Message) -> some View {
        Button {
            UIPasteboard.general.string = message.body
        } label: {
            Label(L("chat.copy"), systemImage: "doc.on.doc")
        }
        if message.userID == app.userID {
            Button(role: .destructive) {
                delete(message)
            } label: {
                Label(L("chat.delete"), systemImage: "trash")
            }
        } else {
            Button {
                reportTarget = message
            } label: {
                Label(L("chat.report"), systemImage: "flag")
            }
            Button(role: .destructive) {
                Task {
                    await app.block(userID: message.userID, nickname: message.nickname)
                }
            } label: {
                Label(L("chat.block"), systemImage: "hand.raised")
            }
            if app.isAdmin {
                Button(role: .destructive) {
                    delete(message)
                } label: {
                    Label(L("chat.admin.delete"), systemImage: "trash")
                }
                Button(role: .destructive) {
                    ban(message)
                } label: {
                    Label(L("chat.admin.ban"), systemImage: "nosign")
                }
            }
        }
    }

    private func send() async {
        let text = String(trimmedDraft.prefix(500))
        guard !text.isEmpty else { return }
        sending = true
        model.noticeText = nil
        if await model.send(text) { draft = "" }
        sending = false
    }

    private func report(_ message: Message, reason: String) {
        model.remove(message)
        Task {
            do {
                try await Backend.report(messageID: message.id, reason: reason)
                model.noticeText = L("chat.reported")
            } catch {
                model.noticeText = Backend.friendlyMessage(error)
            }
        }
    }

    private func delete(_ message: Message) {
        Task {
            do {
                try await Backend.deleteMessage(message.id)
                model.remove(message)
            } catch {
                model.noticeText = Backend.friendlyMessage(error)
            }
        }
    }

    private func ban(_ message: Message) {
        Task {
            do {
                try await Backend.adminBan(userID: message.userID, hours: 24, reason: "Banned from the app")
                model.removeAll(from: message.userID)
            } catch {
                model.noticeText = Backend.friendlyMessage(error)
            }
        }
    }
}

struct MessageRow: View {
    let message: Message
    let isMine: Bool
    let theme: RoomTheme

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(isMine ? L("chat.you") : message.nickname)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isMine ? theme.primary : message.userID.nameColor)
                Text(message.timeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            bubble
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .padding(isMine ? .leading : .trailing, 40)
    }

    @ViewBuilder
    private var bubble: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if isMine {
            Text(message.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.gradient, in: shape)
        } else {
            Text(message.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay(shape.stroke(theme.primary.opacity(0.25), lineWidth: 1))
        }
    }
}
