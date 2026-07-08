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

    // ── Group feed (v1.2) ────────────────────────────────────────────────────

    func feedPosts(groupId: UUID) async throws -> [GroupPost] {
        try await client.from("group_posts").select()
            .eq("group_id", value: groupId)
            .order("created_at", ascending: false)
            .limit(50)
            .execute().value
    }

    func createPost(groupId: UUID, text: String, entryId: UUID? = nil) async throws {
        let session = try await client.auth.session
        try await client.from("group_posts")
            .insert(NewGroupPost(groupId: groupId, authorId: session.user.id, entryId: entryId, text: text))
            .execute()
    }

    func reactions(postIds: [UUID]) async throws -> [PostReaction] {
        guard !postIds.isEmpty else { return [] }
        return try await client.from("post_reactions").select()
            .in("post_id", values: postIds)
            .execute().value
    }

    func toggleReaction(postId: UUID, emoji: String, on: Bool) async throws {
        let session = try await client.auth.session
        if on {
            try await client.from("post_reactions")
                .insert(["post_id": postId.uuidString, "user_id": session.user.id.uuidString, "emoji": emoji])
                .execute()
        } else {
            try await client.from("post_reactions").delete()
                .eq("post_id", value: postId)
                .eq("user_id", value: session.user.id)
                .eq("emoji", value: emoji)
                .execute()
        }
    }

    func comments(postId: UUID) async throws -> [PostComment] {
        try await client.from("post_comments").select()
            .eq("post_id", value: postId)
            .order("created_at", ascending: true)
            .execute().value
    }

    func addComment(postId: UUID, text: String, parentId: UUID? = nil) async throws {
        let session = try await client.auth.session
        try await client.from("post_comments")
            .insert(NewComment(postId: postId, authorId: session.user.id, parentId: parentId, text: text))
            .execute()
    }

    func profiles(ids: [UUID]) async throws -> [Profile] {
        guard !ids.isEmpty else { return [] }
        return try await client.from("profiles").select().in("id", values: ids).execute().value
    }

    // ── Follow graph (v1.1) ──────────────────────────────────────────────────

    func searchPublicProfiles(_ query: String) async throws -> [Profile] {
        try await client.from("profiles").select()
            .eq("is_public", value: true)
            .or("name.ilike.%\(query)%,username.ilike.%\(query)%")
            .limit(20)
            .execute().value
    }

    func following() async throws -> Set<UUID> {
        let session = try await client.auth.session
        let rows: [Follow] = try await client.from("follows").select()
            .eq("follower_id", value: session.user.id)
            .execute().value
        return Set(rows.map(\.followeeId))
    }

    func setFollowing(_ userId: UUID, _ follow: Bool) async throws {
        let session = try await client.auth.session
        if follow {
            try await client.from("follows")
                .insert(["follower_id": session.user.id.uuidString, "followee_id": userId.uuidString])
                .execute()
        } else {
            try await client.from("follows").delete()
                .eq("follower_id", value: session.user.id)
                .eq("followee_id", value: userId)
                .execute()
        }
    }

    // ── Push (v1.2) ──────────────────────────────────────────────────────────

    func registerDeviceToken(_ token: String) async throws {
        let session = try await client.auth.session
        try await client.from("device_tokens")
            .upsert(["user_id": session.user.id.uuidString, "token": token, "platform": "ios"],
                    onConflict: "user_id,platform")
            .execute()
    }
}
