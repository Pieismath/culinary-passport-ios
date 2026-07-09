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

    func myProfile() async throws -> Profile {
        let session = try await client.auth.session
        return try await client.from("profiles").select().eq("id", value: session.user.id).single().execute().value
    }

    // ── Meal photos (single `photos` bucket, public) ─────────────────────────

    /// Upload a JPEG to photos/{user_id}/{uuid}.jpg; returns the stored path.
    func uploadPhoto(_ jpeg: Data) async throws -> String {
        let session = try await client.auth.session
        let path = "\(session.user.id.uuidString)/\(UUID().uuidString).jpg"
        try await client.storage.from("photos").upload(
            path, data: jpeg,
            options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false)
        )
        return path
    }

    /// Public URL for a stored photo path (the bucket is public).
    func photoURL(_ path: String) -> URL? {
        try? client.storage.from("photos").getPublicURL(path: path)
    }

    func updateEntry(id: UUID, _ patch: EntryUpdate) async throws {
        try await client.from("entries").update(patch).eq("id", value: id).execute()
    }

    func deleteEntry(id: UUID) async throws {
        try await client.from("entries").delete().eq("id", value: id).execute()
    }

    func myGroups() async throws -> [Group] {
        try await client.from("groups").select().execute().value
    }

    func createGroup(name: String) async throws -> Group {
        let session = try await client.auth.session
        // owner membership is seeded by the on_group_created DB trigger
        return try await client.from("groups")
            .insert(["name": name, "created_by": session.user.id.uuidString])
            .select().single().execute().value
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

    func publicProfile(id: UUID) async throws -> Profile {
        try await client.from("profiles").select().eq("id", value: id).single().execute().value
    }

    /// Editable profile fields — username uniqueness is enforced by the DB.
    func updateMyProfile(name: String, username: String?, bio: String?, isPublic: Bool) async throws {
        struct Patch: Encodable {
            let name: String
            let username: String?
            let bio: String?
            let isPublic: Bool
        }
        let session = try await client.auth.session
        try await client.from("profiles")
            .update(Patch(name: name, username: username, bio: bio, isPublic: isPublic))
            .eq("id", value: session.user.id)
            .execute()
    }

    func followCounts(userId: UUID) async throws -> (followers: Int, following: Int) {
        async let followers: [Follow] = client.from("follows").select()
            .eq("followee_id", value: userId).execute().value
        async let followingRows: [Follow] = client.from("follows").select()
            .eq("follower_id", value: userId).execute().value
        return (try await followers.count, try await followingRows.count)
    }

    /// Another user's public entries (RLS returns only rows they've shared).
    func publicEntries(userId: UUID) async throws -> [Entry] {
        try await client.from("entries").select()
            .eq("user_id", value: userId)
            .order("date_tried", ascending: false)
            .execute().value
    }

    /// Discover feed (v1.1 item 8): recent meals from users with a public profile.
    /// (The entries SELECT policy is currently permissive — we gate on the author's
    /// is_public flag here so the feed respects profile privacy.)
    func discoverFeed(limit: Int = 40) async throws -> [FeedItem] {
        let entries: [Entry] = try await client.from("entries").select()
            .order("created_at", ascending: false)
            .limit(150)
            .execute().value
        let authorIds = Array(Set(entries.map(\.userId)))
        let publicAuthors = (try await profiles(ids: authorIds)).filter { $0.isPublic == true }
        let byId = Dictionary(uniqueKeysWithValues: publicAuthors.map { ($0.id, $0) })
        return entries.compactMap { e in byId[e.userId].map { FeedItem(entry: e, author: $0) } }
            .prefix(limit).map { $0 }
    }

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
