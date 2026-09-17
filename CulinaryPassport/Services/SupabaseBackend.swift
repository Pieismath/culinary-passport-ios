import Foundation
import Supabase

/// The live backend: one shared Supabase client. Schema + RLS live in the web
/// repo (`supabase/migrations`). Everything visibility-related is enforced
/// there; queries here filter for *relevance*, never for privacy.
final class SupabaseBackend: Backend {
    static let shared = SupabaseBackend()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey,
            options: .init(
                db: .init(encoder: Self.encoder, decoder: Self.decoder),
                auth: .init(
                    storage: AuthClient.Configuration.defaultLocalStorage,
                    // The stored session is emitted as .initialSession right
                    // away (even if expired) instead of after a refresh.
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    // snake_case ⇄ camelCase to match the Postgres schema
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        // Supabase timestamps carry fractional seconds; plain .iso8601 chokes
        // on them. Format styles are value types, built once.
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = try? fractional.parse(s) { return date }
            if let date = try? whole.parse(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(s)"))
        }
        return d
    }()

    /// Keyset cursors keep milliseconds: whole seconds would skip rows created
    /// within the same second as the last one on a page.
    private static let cursorStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Strip characters that are syntax inside a PostgREST `or=(…)` filter
    /// (`,` `(` `)` `"` `:` `\`) or LIKE wildcards (`%` `*`).
    static func sanitizedSearchTerm(_ raw: String) -> String {
        let reserved = Set(",()\":\\%*")
        return String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "@" })
            .filter { !reserved.contains($0) })
    }

    private func uid() async throws -> UUID {
        try await client.auth.session.user.id
    }

    /// Long `in (…)` lists go in the URL; keep each request comfortably short.
    private func chunks<T>(_ items: [T], size: Int = 80) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    // ── Session ──────────────────────────────────────────────────────────────

    func currentUserId() async throws -> UUID { try await uid() }

    func signOut() async {
        try? await client.auth.signOut()
    }

    /// App Store 5.1.1(v). The edge function wipes storage + the auth user.
    func deleteAccount() async throws {
        try await client.functions.invoke("delete-account")
        try? await client.auth.signOut()
    }

    // ── Profiles ─────────────────────────────────────────────────────────────

    func myProfile() async throws -> Profile? {
        try await profile(id: uid())
    }

    func profile(id: UUID) async throws -> Profile? {
        let rows: [Profile] = try await client.from("profiles").select()
            .eq("id", value: id).limit(1).execute().value
        return rows.first
    }

    func profiles(ids: [UUID]) async throws -> [Profile] {
        var result: [Profile] = []
        for chunk in chunks(Array(Set(ids))) {
            let rows: [Profile] = try await client.from("profiles").select()
                .in("id", values: chunk).execute().value
            result += rows
        }
        return result
    }

    func updateProfile(_ patch: ProfilePatch) async throws {
        try await client.from("profiles").update(patch).eq("id", value: uid()).execute()
    }

    func uploadAvatar(_ jpeg: Data) async throws -> String {
        let me = try await uid()
        let path = "\(me.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from("avatars").upload(
            path, data: jpeg,
            options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: false)
        )
        let url = try client.storage.from("avatars").getPublicURL(path: path).absoluteString
        struct AvatarPatch: Encodable { let avatarUrl: String }
        try await client.from("profiles").update(AvatarPatch(avatarUrl: url)).eq("id", value: me).execute()
        return url
    }

    func searchProfiles(_ query: String) async throws -> [Profile] {
        let term = Self.sanitizedSearchTerm(query)
        guard term.count >= 2 else { return [] }
        return try await client.from("profiles").select()
            .eq("is_public", value: true)
            .or("name.ilike.%\(term)%,username.ilike.%\(term)%")
            .limit(25)
            .execute().value
    }

    // ── Memories ─────────────────────────────────────────────────────────────

    func memories(userId: UUID) async throws -> [Memory] {
        try await client.from("entries").select()
            .eq("kind", value: "memory")
            .eq("user_id", value: userId)
            .order("date_tried", ascending: false)
            .order("created_at", ascending: false)
            .execute().value
    }

    func memory(id: UUID) async throws -> Memory? {
        let rows: [Memory] = try await client.from("entries").select()
            .eq("kind", value: "memory").eq("id", value: id).limit(1).execute().value
        return rows.first
    }

    func memories(ids: [UUID]) async throws -> [Memory] {
        var result: [Memory] = []
        for chunk in chunks(Array(Set(ids))) {
            let rows: [Memory] = try await client.from("entries").select()
                .eq("kind", value: "memory").in("id", values: chunk).execute().value
            result += rows
        }
        return result
    }

    func memories(countryCode: String, userIds: [UUID]) async throws -> [Memory] {
        guard !userIds.isEmpty else { return [] }
        var result: [Memory] = []
        for chunk in chunks(userIds) {
            let rows: [Memory] = try await client.from("entries").select()
                .eq("kind", value: "memory")
                .eq("country_code", value: countryCode)
                .in("user_id", values: chunk)
                .order("date_tried", ascending: false)
                .limit(60)
                .execute().value
            result += rows
        }
        return result.sorted { $0.date > $1.date }
    }

    func insertMemory(_ memory: NewMemory) async throws -> Memory {
        try await client.from("entries").insert(memory).select().single().execute().value
    }

    func updateMemory(id: UUID, _ patch: MemoryPatch) async throws -> Memory {
        try await client.from("entries").update(patch).eq("id", value: id).select().single().execute().value
    }

    /// Row first, then its photos (best-effort). The other order could leave
    /// a memory whose photos were already gone if the row delete failed.
    func deleteMemory(_ memory: Memory) async throws {
        try await client.from("entries").delete().eq("id", value: memory.id).execute()
        await removePhotos(memory.photos)
    }

    func uploadPhoto(_ jpeg: Data) async throws -> String {
        let me = try await uid()
        let path = "\(me.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from("photos").upload(
            path, data: jpeg,
            options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: false)
        )
        return path
    }

    func removePhotos(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        _ = try? await client.storage.from("photos").remove(paths: paths)
    }

    func photoData(path: String) async throws -> Data {
        try await client.storage.from("photos").download(path: path)
    }

    // ── Stamps + bucket list ─────────────────────────────────────────────────

    func stamps(userIds: [UUID]) async throws -> [Stamp] {
        var result: [Stamp] = []
        for chunk in chunks(Array(Set(userIds))) {
            let rows: [Stamp] = try await client.from("stamps").select()
                .in("user_id", values: chunk).execute().value
            result += rows
        }
        return result
    }

    func stamps(countryCode: String, userIds: [UUID]) async throws -> [Stamp] {
        guard !userIds.isEmpty else { return [] }
        var result: [Stamp] = []
        for chunk in chunks(Array(Set(userIds))) {
            let rows: [Stamp] = try await client.from("stamps").select()
                .eq("country_code", value: countryCode)
                .in("user_id", values: chunk).execute().value
            result += rows
        }
        return result
    }

    func addStamps(_ items: [StampInput]) async throws {
        guard !items.isEmpty else { return }
        struct Params: Encodable { let items: [StampInput] }
        try await client.rpc("add_stamps", params: Params(items: items)).execute()
    }

    func removeStamp(countryCode: String) async throws {
        try await client.from("stamps").delete()
            .eq("user_id", value: uid())
            .eq("country_code", value: countryCode)
            .execute()
    }

    func bucketList() async throws -> Set<String> {
        struct Row: Decodable { let countryCode: String }
        let rows: [Row] = try await client.from("wishlist").select("country_code")
            .eq("user_id", value: uid()).execute().value
        return Set(rows.map(\.countryCode))
    }

    func setBucketListed(_ code: String, _ on: Bool) async throws {
        let me = try await uid()
        if on {
            // DO NOTHING on conflict: the table has no UPDATE policy, so a
            // DO UPDATE upsert fails when the row already exists.
            try await client.from("wishlist")
                .upsert(["country_code": code, "user_id": me.uuidString],
                        onConflict: "country_code,user_id", ignoreDuplicates: true)
                .execute()
        } else {
            try await client.from("wishlist").delete()
                .eq("country_code", value: code).eq("user_id", value: me).execute()
        }
    }

    // ── Social graph ─────────────────────────────────────────────────────────

    func followingIds(of userId: UUID) async throws -> [UUID] {
        let rows: [Follow] = try await client.from("follows").select()
            .eq("follower_id", value: userId).execute().value
        return rows.map(\.followeeId)
    }

    func followerIds(of userId: UUID) async throws -> [UUID] {
        let rows: [Follow] = try await client.from("follows").select()
            .eq("followee_id", value: userId).execute().value
        return rows.map(\.followerId)
    }

    func followCounts(userId: UUID) async throws -> (followers: Int, following: Int) {
        async let followers = client.from("follows")
            .select("*", head: true, count: .exact)
            .eq("followee_id", value: userId).execute().count
        async let following = client.from("follows")
            .select("*", head: true, count: .exact)
            .eq("follower_id", value: userId).execute().count
        return (try await followers ?? 0, try await following ?? 0)
    }

    func setFollowing(_ userId: UUID, _ follow: Bool) async throws {
        let me = try await uid()
        if follow {
            try await client.from("follows")
                .upsert(["follower_id": me.uuidString, "followee_id": userId.uuidString],
                        onConflict: "follower_id,followee_id", ignoreDuplicates: true)
                .execute()
        } else {
            try await client.from("follows").delete()
                .eq("follower_id", value: me).eq("followee_id", value: userId).execute()
        }
    }

    func blockedIds() async throws -> Set<UUID> {
        struct Row: Decodable { let blockedId: UUID }
        let rows: [Row] = try await client.from("blocks").select("blocked_id")
            .eq("blocker_id", value: uid()).execute().value
        return Set(rows.map(\.blockedId))
    }

    func setBlocked(_ userId: UUID, _ blocked: Bool) async throws {
        let me = try await uid()
        if blocked {
            try await client.from("blocks")
                .upsert(["blocker_id": me.uuidString, "blocked_id": userId.uuidString],
                        onConflict: "blocker_id,blocked_id", ignoreDuplicates: true)
                .execute()
            // Blocking also ends the follow in both directions you control.
            try? await setFollowing(userId, false)
        } else {
            try await client.from("blocks").delete()
                .eq("blocker_id", value: me).eq("blocked_id", value: userId).execute()
        }
    }

    func report(contentType: String, contentId: UUID, reason: String) async throws {
        struct Insert: Encodable {
            let reporterId: UUID
            let contentType: String
            let contentId: UUID
            let reason: String
        }
        try await client.from("reports")
            .insert(Insert(reporterId: uid(), contentType: contentType, contentId: contentId,
                           reason: String(reason.prefix(1000))))
            .execute()
    }

    // ── Feeds ────────────────────────────────────────────────────────────────

    func friendsFeed(before: Date?, limit: Int) async throws -> [Memory] {
        struct Params: Encodable { let beforeTs: String?; let pageSize: Int }
        return try await client.rpc("friends_feed", params: Params(
            beforeTs: before.map { $0.formatted(Self.cursorStyle) }, pageSize: limit
        )).execute().value
    }

    func discoverFeed(before: Date?, limit: Int) async throws -> [Memory] {
        var query = client.from("entries").select()
            .eq("kind", value: "memory")
            .eq("visibility", value: "public")
        if let before {
            query = query.lt("created_at", value: before.formatted(Self.cursorStyle))
        }
        return try await query.order("created_at", ascending: false).limit(limit).execute().value
    }

    func recentStamps(userIds: [UUID], limit: Int) async throws -> [Stamp] {
        guard !userIds.isEmpty else { return [] }
        var result: [Stamp] = []
        for chunk in chunks(Array(Set(userIds))) {
            let rows: [Stamp] = try await client.from("stamps").select()
                .in("user_id", values: chunk)
                .order("created_at", ascending: false)
                .limit(limit)
                .execute().value
            result += rows
        }
        return Array(result.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func activity(limit: Int) async throws -> [ActivityRow] {
        try await client.rpc("my_activity", params: ["page_size": limit]).execute().value
    }

    // ── Reactions + comments ─────────────────────────────────────────────────

    func reactions(memoryIds: [UUID]) async throws -> [Reaction] {
        var result: [Reaction] = []
        for chunk in chunks(Array(Set(memoryIds))) {
            let rows: [Reaction] = try await client.from("entry_reactions").select()
                .in("entry_id", values: chunk).execute().value
            result += rows
        }
        return result
    }

    func setReaction(memoryId: UUID, emoji: String, on: Bool) async throws {
        let me = try await uid()
        if on {
            try await client.from("entry_reactions")
                .upsert(["entry_id": memoryId.uuidString, "user_id": me.uuidString, "emoji": emoji],
                        onConflict: "entry_id,user_id,emoji", ignoreDuplicates: true)
                .execute()
        } else {
            try await client.from("entry_reactions").delete()
                .eq("entry_id", value: memoryId).eq("user_id", value: me).eq("emoji", value: emoji)
                .execute()
        }
    }

    func comments(memoryId: UUID) async throws -> [Comment] {
        try await client.from("entry_comments").select()
            .eq("entry_id", value: memoryId)
            .order("created_at", ascending: true)
            .execute().value
    }

    func commentCounts(memoryIds: [UUID]) async throws -> [UUID: Int] {
        struct Row: Decodable { let entryId: UUID }
        var counts: [UUID: Int] = [:]
        for chunk in chunks(Array(Set(memoryIds))) {
            let rows: [Row] = try await client.from("entry_comments").select("entry_id")
                .in("entry_id", values: chunk).execute().value
            for row in rows { counts[row.entryId, default: 0] += 1 }
        }
        return counts
    }

    func addComment(memoryId: UUID, text: String) async throws {
        struct Insert: Encodable { let entryId: UUID; let authorId: UUID; let text: String }
        try await client.from("entry_comments")
            .insert(Insert(entryId: memoryId, authorId: uid(), text: String(text.prefix(2000))))
            .execute()
    }

    func deleteComment(id: UUID) async throws {
        try await client.from("entry_comments").delete().eq("id", value: id).execute()
    }

    // ── Groups ───────────────────────────────────────────────────────────────

    func myGroups() async throws -> [Group] {
        try await client.from("groups").select().order("created_at", ascending: false).execute().value
    }

    func groupMembers(groupIds: [UUID]) async throws -> [GroupMember] {
        guard !groupIds.isEmpty else { return [] }
        return try await client.from("group_members").select()
            .in("group_id", values: groupIds).execute().value
    }

    func createGroup(name: String) async throws -> Group {
        // owner membership is seeded by the on_group_created DB trigger
        try await client.from("groups")
            .insert(["name": name, "created_by": uid().uuidString])
            .select().single().execute().value
    }

    /// The RPC answers NULL for a wrong code (so the server can count misses
    /// and stop guessing after ten an hour) and raises only for the limit.
    func joinGroup(inviteCode: String) async throws -> UUID {
        let code = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let gid: UUID? = try await client.rpc("join_group_by_invite", params: ["code": code]).execute().value
        guard let gid else { throw AppError("That code didn't match a group. Check it with whoever sent it.") }
        return gid
    }

    func updateGroup(id: UUID, _ patch: GroupPatch) async throws {
        try await client.from("groups").update(patch).eq("id", value: id).execute()
    }

    func uploadGroupCover(groupId: UUID, _ jpeg: Data) async throws -> String {
        let path = "\(groupId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from("group-covers").upload(
            path, data: jpeg,
            options: FileOptions(cacheControl: "31536000", contentType: "image/jpeg", upsert: false)
        )
        return path
    }

    func groupCoverURL(_ path: String) -> URL? {
        try? client.storage.from("group-covers").getPublicURL(path: path)
    }

    func deleteGroup(id: UUID) async throws {
        try await client.from("groups").delete().eq("id", value: id).execute()
    }

    func leaveGroup(id: UUID) async throws {
        try await client.from("group_members").delete()
            .eq("group_id", value: id).eq("user_id", value: uid()).execute()
    }

    // ── Group chat ───────────────────────────────────────────────────────────

    func posts(groupId: UUID, before: Date?, limit: Int) async throws -> [GroupPost] {
        var query = client.from("group_posts").select().eq("group_id", value: groupId)
        if let before {
            query = query.lt("created_at", value: before.formatted(Self.cursorStyle))
        }
        return try await query.order("created_at", ascending: false).limit(limit).execute().value
    }

    func createPost(groupId: UUID, text: String, memoryId: UUID?) async throws {
        struct Insert: Encodable { let groupId: UUID; let authorId: UUID; let entryId: UUID?; let text: String }
        try await client.from("group_posts")
            .insert(Insert(groupId: groupId, authorId: uid(), entryId: memoryId, text: String(text.prefix(4000))))
            .execute()
    }

    func deletePost(id: UUID) async throws {
        try await client.from("group_posts").delete().eq("id", value: id).execute()
    }

    func postReactions(postIds: [UUID]) async throws -> [PostReaction] {
        var result: [PostReaction] = []
        for chunk in chunks(Array(Set(postIds))) {
            let rows: [PostReaction] = try await client.from("post_reactions").select()
                .in("post_id", values: chunk).execute().value
            result += rows
        }
        return result
    }

    func setPostReaction(postId: UUID, emoji: String, on: Bool) async throws {
        let me = try await uid()
        if on {
            try await client.from("post_reactions")
                .upsert(["post_id": postId.uuidString, "user_id": me.uuidString, "emoji": emoji],
                        onConflict: "post_id,user_id,emoji", ignoreDuplicates: true)
                .execute()
        } else {
            try await client.from("post_reactions").delete()
                .eq("post_id", value: postId).eq("user_id", value: me).eq("emoji", value: emoji)
                .execute()
        }
    }

    func postComments(postIds: [UUID]) async throws -> [PostComment] {
        var result: [PostComment] = []
        for chunk in chunks(Array(Set(postIds))) {
            let rows: [PostComment] = try await client.from("post_comments").select()
                .in("post_id", values: chunk)
                .order("created_at", ascending: true)
                .execute().value
            result += rows
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    func addPostComment(postId: UUID, text: String) async throws {
        struct Insert: Encodable { let postId: UUID; let authorId: UUID; let text: String }
        try await client.from("post_comments")
            .insert(Insert(postId: postId, authorId: uid(), text: String(text.prefix(2000))))
            .execute()
    }

    func deletePostComment(id: UUID) async throws {
        try await client.from("post_comments").delete().eq("id", value: id).execute()
    }

    /// Posts are filtered to this group server-side; comments and reactions
    /// carry no group id, so any event RLS lets through triggers a refresh.
    func chatChanges(groupId: UUID) -> AsyncStream<Void> {
        let client = client
        return AsyncStream { continuation in
            let task = Task {
                // A fresh topic per subscription: reopening a chat quickly must
                // not get back the previous, still-joined channel (adding
                // listeners to a joined channel fails).
                let channel = client.channel("group-chat-\(groupId.uuidString.lowercased())-\(UUID().uuidString.prefix(8))")
                let posts = channel.postgresChange(
                    AnyAction.self, schema: "public", table: "group_posts",
                    filter: .eq("group_id", value: groupId.uuidString.lowercased())
                )
                let comments = channel.postgresChange(AnyAction.self, schema: "public", table: "post_comments")
                let reactions = channel.postgresChange(AnyAction.self, schema: "public", table: "post_reactions")
                do {
                    try await channel.subscribeWithError()
                } catch {
                    await client.removeChannel(channel)
                    continuation.finish()
                    return
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await _ in posts { continuation.yield() } }
                    group.addTask { for await _ in comments { continuation.yield() } }
                    group.addTask { for await _ in reactions { continuation.yield() } }
                }
                await client.removeChannel(channel)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // ── Misc ─────────────────────────────────────────────────────────────────

    /// Fire-and-forget (insert-only table). Never throws into product flows.
    func logEvent(_ name: String, props: [String: String]?) {
        Task {
            struct Insert: Encodable { let userId: UUID; let name: String; let props: [String: String]? }
            guard let me = try? await uid() else { return }
            _ = try? await client.from("events").insert(Insert(userId: me, name: name, props: props)).execute()
        }
    }

    func registerDeviceToken(_ token: String) async throws {
        try await client.from("device_tokens")
            .upsert(["user_id": uid().uuidString, "token": token, "platform": "ios"],
                    onConflict: "user_id,platform")
            .execute()
    }

    // ── Auth helpers used by sign-in ─────────────────────────────────────────

    func requestPasswordReset(email: String) async throws {
        try await client.auth.resetPasswordForEmail(email, redirectTo: URL(string: "culinarypassport://reset-password"))
    }

    func updatePassword(_ newPassword: String) async throws {
        try await client.auth.update(user: UserAttributes(password: newPassword))
    }
}
