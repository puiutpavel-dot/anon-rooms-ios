import Foundation
import SwiftUI

struct Profile: Codable {
    let id: UUID
    let nickname: String
}

struct Room: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let emoji: String
    let description: String?
    let isPrivate: Bool
    let inviteCode: String?
    /// Limba camerei publice (ex. „en”); nil = vizibilă în toate limbile.
    let lang: String?
    let colorA: String?
    let colorB: String?

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, description, lang
        case isPrivate = "is_private"
        case inviteCode = "invite_code"
        case colorA = "color_a"
        case colorB = "color_b"
    }

    var theme: RoomTheme {
        RoomTheme(
            primary: Color(hex: colorA) ?? Color(red: 0.36, green: 0.42, blue: 1.0),
            secondary: Color(hex: colorB) ?? Color(red: 0.56, green: 0.33, blue: 0.91)
        )
    }
}

/// Tema grafică a unei camere: două culori din baza de date.
struct RoomTheme {
    let primary: Color
    let secondary: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    /// Culoare din cod hex, ex. „#FF6B6B”. Întoarce nil dacă textul nu e valid.
    init?(hex: String?) {
        guard let hex else { return nil }
        let cleaned = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Fundalul unei camere: o tentă din culorile ei și emoji-ul repetat, foarte discret.
struct RoomBackdrop: View {
    let room: Room

    var body: some View {
        ZStack {
            Color(.systemBackground)
            room.theme.gradient.opacity(0.16)
            Canvas { context, size in
                context.opacity = 0.10
                let symbol = context.resolve(Text(room.emoji).font(.system(size: 30)))
                let step: CGFloat = 84
                var row = 0
                var y: CGFloat = 30
                while y < size.height + step {
                    var x: CGFloat = row % 2 == 0 ? 30 : 30 + step / 2
                    while x < size.width + step {
                        context.draw(symbol, at: CGPoint(x: x, y: y))
                        x += step
                    }
                    y += step * 0.8
                    row += 1
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct Message: Codable, Identifiable, Equatable {
    let id: Int
    let roomID: UUID
    let userID: UUID
    let nickname: String
    let body: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, nickname, body
        case roomID = "room_id"
        case userID = "user_id"
        case createdAt = "created_at"
    }

    /// Ora locală a mesajului, ex. „21:47”.
    var timeText: String {
        guard let date = Message.parseDate(createdAt) else { return "" }
        return Message.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: String) -> Date? {
        var s = raw.replacingOccurrences(of: " ", with: "T")
        // scoate fracțiunile de secundă: 12:00:00.123456+00:00 → 12:00:00+00:00
        s = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        // +00 → +00:00
        if s.range(of: "[+-]\\d{2}$", options: .regularExpression) != nil { s += ":00" }
        return isoFormatter.date(from: s)
    }
}

struct BlockedUser: Codable, Identifiable, Equatable {
    let blockedID: UUID
    let blockedNickname: String
    var id: UUID { blockedID }

    enum CodingKeys: String, CodingKey {
        case blockedID = "blocked_id"
        case blockedNickname = "blocked_nickname"
    }
}

enum NicknameGenerator {
    private static let adjectives = ["Happy", "Calm", "Curious", "Swift", "Clever", "Quiet", "Funny", "Dreamy", "Brave", "Lucky"]
    private static let animals = ["Fox", "Bear", "Wolf", "Hedgehog", "Badger", "Falcon", "Deer", "Lynx", "Beaver", "Penguin"]

    static func make() -> String {
        "\(adjectives.randomElement()!)\(animals.randomElement()!)\(Int.random(in: 10...999))"
    }
}

extension UUID {
    /// Culoare stabilă pentru poreclă, derivată din ID.
    var nameColor: Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red, .mint, .brown]
        let sum = uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
