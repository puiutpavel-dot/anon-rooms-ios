import Foundation
import Supabase

/// Tot ce vorbește cu Supabase stă aici.
enum Backend {
    static let client = SupabaseClient(
        supabaseURL: URL(string: Config.supabaseURL)!,
        supabaseKey: Config.supabaseKey
    )

    // MARK: Sesiune

    /// Refolosește sesiunea salvată sau creează un cont anonim nou.
    static func ensureSession() async throws -> UUID {
        if let session = try? await client.auth.session {
            return session.user.id
        }
        let session = try await client.auth.signInAnonymously()
        return session.user.id
    }

    // MARK: Profil

    static func fetchProfile(_ userID: UUID) async throws -> Profile? {
        let rows: [Profile] = try await client.from("profiles")
            .select()
            .eq("id", value: userID.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    static func saveProfile(userID: UUID, nickname: String) async throws {
        try await client.from("profiles")
            .upsert(Profile(id: userID, nickname: nickname))
            .execute()
    }

    static func isAdmin() async throws -> Bool {
        try await client.rpc("is_admin").execute().value
    }

    // MARK: Camere

    static func fetchRooms() async throws -> [Room] {
        try await client.from("rooms")
            .select()
            .order("sort", ascending: true)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    private struct NameParams: Encodable { let p_name: String }
    private struct CodeParams: Encodable { let p_code: String }

    static func createPrivateRoom(name: String) async throws -> Room {
        try await client.rpc("create_private_room", params: NameParams(p_name: name)).execute().value
    }

    static func joinPrivateRoom(code: String) async throws -> Room {
        try await client.rpc("join_private_room", params: CodeParams(p_code: code)).execute().value
    }

    static func leaveRoom(_ roomID: UUID) async throws {
        try await client.from("room_members")
            .delete()
            .eq("room_id", value: roomID.uuidString.lowercased())
            .execute()
    }

    // MARK: Mesaje

    static func fetchMessages(roomID: UUID) async throws -> [Message] {
        let rows: [Message] = try await client.from("messages")
            .select()
            .eq("room_id", value: roomID.uuidString.lowercased())
            .order("created_at", ascending: false)
            .limit(100)
            .execute()
            .value
        return rows.reversed()
    }

    private struct NewMessage: Encodable {
        let room_id: String
        let body: String
    }

    static func send(roomID: UUID, body: String) async throws {
        try await client.from("messages")
            .insert(NewMessage(room_id: roomID.uuidString.lowercased(), body: body))
            .execute()
    }

    static func deleteMessage(_ id: Int) async throws {
        try await client.from("messages").delete().eq("id", value: id).execute()
    }

    // MARK: Moderare

    private struct ReportParams: Encodable {
        let p_message_id: Int
        let p_reason: String
    }

    static func report(messageID: Int, reason: String) async throws {
        try await client.rpc("report_message", params: ReportParams(p_message_id: messageID, p_reason: reason)).execute()
    }

    private struct NewBlock: Encodable {
        let blocked_id: String
        let blocked_nickname: String
    }

    static func fetchBlocked() async throws -> [BlockedUser] {
        try await client.from("blocks").select().execute().value
    }

    static func block(userID: UUID, nickname: String) async throws {
        try await client.from("blocks")
            .upsert(NewBlock(blocked_id: userID.uuidString.lowercased(), blocked_nickname: nickname))
            .execute()
    }

    static func unblock(userID: UUID) async throws {
        try await client.from("blocks")
            .delete()
            .eq("blocked_id", value: userID.uuidString.lowercased())
            .execute()
    }

    private struct BanParams: Encodable {
        let p_user_id: String
        let p_hours: Int
        let p_reason: String
    }

    static func adminBan(userID: UUID, hours: Int, reason: String) async throws {
        try await client.rpc(
            "admin_ban",
            params: BanParams(p_user_id: userID.uuidString.lowercased(), p_hours: hours, p_reason: reason)
        ).execute()
    }

    // MARK: Ștergere date

    static func deleteMyData() async throws {
        try await client.rpc("delete_my_data").execute()
        try? await client.auth.signOut()
    }

    // MARK: Erori

    /// Transformă erorile din baza de date în text pentru utilizator.
    static func friendlyMessage(_ error: Error) -> String {
        let raw = String(describing: error) + " " + error.localizedDescription
        if raw.contains("BANNED") { return L("error.banned") }
        if raw.contains("RATE_LIMIT") { return L("error.rate") }
        if raw.contains("BAD_NICKNAME") { return L("error.nickname") }
        if raw.contains("ROOM_NOT_FOUND") { return L("error.roomNotFound") }
        if raw.contains("ROOM_LIMIT") { return L("error.roomLimit") }
        if raw.contains("NO_PROFILE") { return L("error.noProfile") }
        return L("error.generic")
    }
}
