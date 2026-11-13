import SwiftUI

struct RoomsView: View {
    @EnvironmentObject private var app: AppState
    @State private var rooms: [Room] = []
    @State private var path: [Room] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showSettings = false
    @State private var inputText = ""

    private var publicRooms: [Room] { rooms.filter { !$0.isPrivate && ($0.lang == nil || $0.lang == appLanguage) } }
    private var privateRooms: [Room] { rooms.filter { $0.isPrivate } }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }

                    Text(L("rooms.public")).font(.title3.bold())
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(publicRooms) { room in
                            NavigationLink(value: room) { RoomCard(room: room) }
                                .buttonStyle(.plain)
                        }
                    }

                    Text(L("rooms.private"))
                        .font(.title3.bold())
                        .padding(.top, 10)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(privateRooms) { room in
                            NavigationLink(value: room) { RoomCard(room: room) }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(L("rooms.leave"), role: .destructive) {
                                        Task { await leave(room) }
                                    }
                                }
                        }
                    }
                    HStack(spacing: 12) {
                        Button {
                            inputText = ""
                            showCreate = true
                        } label: {
                            Label(L("rooms.new"), systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            inputText = ""
                            showJoin = true
                        } label: {
                            Label(L("rooms.haveCode"), systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Text(L("rooms.private.footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .overlay {
                if loading && rooms.isEmpty { ProgressView() }
            }
            .navigationTitle(L("rooms.title"))
            .navigationDestination(for: Room.self) { room in
                ChatView(room: room)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(L("settings.title"))
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert(L("rooms.create.title"), isPresented: $showCreate) {
                TextField(L("rooms.create.placeholder"), text: $inputText)
                Button(L("rooms.create.action")) { Task { await create() } }
                Button(L("common.cancel"), role: .cancel) {}
            }
            .alert(L("rooms.join.title"), isPresented: $showJoin) {
                TextField(L("rooms.join.placeholder"), text: $inputText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button(L("onb.enter")) { Task { await join() } }
                Button(L("common.cancel"), role: .cancel) {}
            }
        }
    }

    private func load() async {
        loading = true
        do {
            rooms = try await Backend.fetchRooms()
            errorText = nil
        } catch {
            errorText = Backend.friendlyMessage(error)
        }
        loading = false
    }

    private func create() async {
        let name = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(name.count) else {
            errorText = L("rooms.nameLength")
            return
        }
        do {
            let room = try await Backend.createPrivateRoom(name: name)
            await load()
            path = [room]
        } catch {
            errorText = Backend.friendlyMessage(error)
        }
    }

    private func join() async {
        let code = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        do {
            let room = try await Backend.joinPrivateRoom(code: code)
            await load()
            path = [room]
        } catch {
            errorText = Backend.friendlyMessage(error)
        }
    }

    private func leave(_ room: Room) async {
        do {
            try await Backend.leaveRoom(room.id)
            rooms.removeAll { $0.id == room.id }
        } catch {
            errorText = Backend.friendlyMessage(error)
        }
    }
}

/// Cardul colorat al unei camere, în culorile temei ei.
struct RoomCard: View {
    let room: Room

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            room.theme.gradient
            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: 130, height: 130)
                .offset(x: 40, y: 45)
            Text(room.emoji)
                .font(.system(size: 62))
                .rotationEffect(.degrees(-12))
                .offset(x: -6, y: 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(room.name)
                    .font(.headline)
                    .lineLimit(2)
                if room.isPrivate, let code = room.inviteCode {
                    Text(L("rooms.code", code))
                        .font(.subheadline.monospaced())
                        .opacity(0.9)
                } else if let description = room.description {
                    Text(description)
                        .font(.caption)
                        .opacity(0.9)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: room.theme.primary.opacity(0.35), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var statusText: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L("common.nickname")) {
                    TextField(L("common.nickname"), text: $nickname)
                        .autocorrectionDisabled()
                    Button(L("common.save")) { Task { await save() } }
                        .disabled(!(3...24).contains(trimmed.count) || trimmed == app.nickname)
                    if let statusText {
                        Text(statusText).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section(L("settings.blocked")) {
                    if app.blocked.isEmpty {
                        Text(L("settings.blocked.empty")).foregroundStyle(.secondary)
                    }
                    ForEach(app.blocked) { user in
                        HStack {
                            Text(user.blockedNickname.isEmpty ? L("settings.user") : user.blockedNickname)
                            Spacer()
                            Button(L("settings.unblock")) { Task { await app.unblock(user) } }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                Section(L("common.rules")) {
                    RulesList()
                }

                Section {
                    if let url = URL(string: "mailto:\(Config.contactEmail)") {
                        Link(L("settings.contact.write", Config.contactEmail), destination: url)
                    }
                } header: {
                    Text(L("settings.contact"))
                } footer: {
                    Text(L("settings.contact.footer"))
                }

                Section {
                    Button(L("settings.delete"), role: .destructive) {
                        confirmDelete = true
                    }
                } footer: {
                    Text(L("settings.delete.footer"))
                }
            }
            .navigationTitle(L("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .onAppear { nickname = app.nickname }
            .confirmationDialog(L("settings.delete.confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(L("settings.delete.action"), role: .destructive) {
                    Task {
                        do {
                            try await app.deleteMyData()
                            dismiss()
                        } catch {
                            statusText = Backend.friendlyMessage(error)
                        }
                    }
                }
                Button(L("common.cancel"), role: .cancel) {}
            }
        }
    }

    private var trimmed: String { nickname.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() async {
        do {
            try await app.saveNickname(trimmed)
            statusText = L("settings.saved")
        } catch {
            statusText = Backend.friendlyMessage(error)
        }
    }
}
