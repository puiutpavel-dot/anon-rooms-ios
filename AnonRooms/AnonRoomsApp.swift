import SwiftUI

@main
struct AnonRoomsApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .task { await app.start() }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
        case failed(String)
    }

    @Published var phase: Phase = .loading
    @Published var nickname = ""
    @Published var isAdmin = false
    @Published var blocked: [BlockedUser] = []
    private(set) var userID: UUID?

    var blockedIDs: Set<UUID> { Set(blocked.map(\.blockedID)) }

    func start() async {
        phase = .loading
        do {
            let uid = try await Backend.ensureSession()
            userID = uid
            if let profile = try await Backend.fetchProfile(uid) {
                nickname = profile.nickname
                isAdmin = (try? await Backend.isAdmin()) ?? false
                blocked = (try? await Backend.fetchBlocked()) ?? []
                phase = .ready
            } else {
                phase = .onboarding
            }
        } catch {
            phase = .failed(Backend.friendlyMessage(error))
        }
    }

    func saveNickname(_ newName: String) async throws {
        guard let uid = userID else { return }
        try await Backend.saveProfile(userID: uid, nickname: newName)
        nickname = newName
        if phase == .onboarding { phase = .ready }
    }

    func block(userID: UUID, nickname: String) async {
        do {
            try await Backend.block(userID: userID, nickname: nickname)
            if !blockedIDs.contains(userID) {
                blocked.append(BlockedUser(blockedID: userID, blockedNickname: nickname))
            }
        } catch {}
    }

    func unblock(_ user: BlockedUser) async {
        do {
            try await Backend.unblock(userID: user.blockedID)
            blocked.removeAll { $0.blockedID == user.blockedID }
        } catch {}
    }

    func deleteMyData() async throws {
        try await Backend.deleteMyData()
        nickname = ""
        isAdmin = false
        blocked = []
        userID = nil
        await start()
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        switch app.phase {
        case .loading:
            ProgressView(L("root.connecting"))
        case .onboarding:
            OnboardingView()
        case .ready:
            RoomsView()
        case .failed(let text):
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(text)
                    .multilineTextAlignment(.center)
                Button(L("common.retry")) {
                    Task { await app.start() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

struct RulesList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Config.rules, id: \.self) { rule in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L(rule))
                }
                .font(.subheadline)
            }
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var app: AppState
    @State private var nickname = NicknameGenerator.make()
    @State private var accepted = false
    @State private var busy = false
    @State private var errorText: String?

    private var trimmed: String { nickname.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canContinue: Bool { accepted && (3...24).contains(trimmed.count) && !busy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: "Anon Rooms")
                    .font(.largeTitle.bold())
                Text(L("onb.tagline"))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("onb.nickname.title")).font(.headline)
                    HStack {
                        TextField(L("common.nickname"), text: $nickname)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                        Button {
                            nickname = NicknameGenerator.make()
                        } label: {
                            Image(systemName: "dice")
                        }
                        .accessibilityLabel(L("onb.nickname.another"))
                    }
                    Text(L("onb.nickname.hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("common.rules")).font(.headline)
                    RulesList()
                }

                Toggle(L("onb.accept"), isOn: $accepted)

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task { await enter() }
                } label: {
                    Text(busy ? L("common.loading") : L("onb.enter"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canContinue)
            }
            .padding()
        }
    }

    private func enter() async {
        busy = true
        errorText = nil
        do {
            try await app.saveNickname(trimmed)
        } catch {
            errorText = Backend.friendlyMessage(error)
        }
        busy = false
    }
}
