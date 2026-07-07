import Foundation
import Supabase

/// Single shared Supabase client — same project as the web app.
final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey,
            options: .init(db: .init(encoder: Self.encoder, decoder: Self.decoder))
        )
    }

    // snake_case ⇄ camelCase to match the Postgres schema
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            // Supabase timestamps carry fractional seconds; plain .iso8601 chokes on them.
            let s = try decoder.singleValueContainer().decode(String.self)
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fmt.date(from: s) { return date }
            fmt.formatOptions = [.withInternetDateTime]
            if let date = fmt.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(s)"))
        }
        return d
    }()

    // ── Data access (grow these as views land) ──────────────────────────────

    func myEntries() async throws -> [Entry] {
        try await client.from("entries").select().order("date_tried", ascending: false).execute().value
    }

    func addEntry(_ entry: NewEntry) async throws {
        try await client.from("entries").insert(entry).execute()
    }

    func deleteEntry(id: UUID) async throws {
        try await client.from("entries").delete().eq("id", value: id).execute()
    }

    func myGroups() async throws -> [Group] {
        try await client.from("groups").select().execute().value
    }

    func createGroup(name: String) async throws -> Group {
        let session = try await client.auth.session
        let group: Group = try await client.from("groups")
            .insert(["name": name, "created_by": session.user.id.uuidString])
            .select().single().execute().value
        // seed the creator as owner (policy allows inserting yourself)
        try await client.from("group_members")
            .insert(["group_id": group.id.uuidString, "user_id": session.user.id.uuidString, "role": "owner"])
            .execute()
        return group
    }

    func joinGroup(inviteCode: String) async throws -> UUID {
        try await client.rpc("join_group_by_invite", params: ["code": inviteCode]).execute().value
    }
}
