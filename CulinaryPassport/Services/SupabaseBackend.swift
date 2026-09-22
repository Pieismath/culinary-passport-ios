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

    /// PostgREST silently caps a response (1,000 rows on hosted projects).
    /// Page through a stably ordered query until a short page ends it.
    private func allPages<T: Decodable>(pageSize: Int = 500,
                                        _ page: (_ from: Int, _ to: Int) async throws -> [T]) async throws -> [T] {
        var result: [T] = []
        while true {
            let rows = try await page(result.count, result.count + pageSize - 1)
            result += rows
            if rows.count < pageSize { return result }
        }
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
        let me = try await uid()
        return try await client.from("profiles").select()
            .eq("is_public", value: true)
            .or("name.ilike.%\(term)%,username.ilike.%\(term)%")
            .neq("id", value: me)
            .limit(25)
            .execute().value
    }

    // ── Meals ────────────────────────────────────────────────────────────────

    func meals(userId: UUID) async throws -> [Meal] {
        try await allPages { from, to in
            try await client.from("entries").select()
                .eq("kind", value: "meal")
                .eq("user_id", value: userId)
                .order("date_tried", ascending: false)
                .order("created_at", ascending: false)
                .order("id")
                .range(from: from, to: to)
                .execute().value
        }
    }

    func meal(id: UUID) async throws -> Meal? {
        let rows: [Meal] = try await client.from("entries").select()
            .eq("kind", value: "meal").eq("id", value: id).limit(1).execute().value
        return rows.first
    }

    func meals(ids: [UUID]) async throws -> [Meal] {
        var result: [Meal] = []
        for chunk in chunks(Array(Set(ids))) {
            let rows: [Meal] = try await client.from("entries").select()
                .eq("kind", value: "meal").in("id", values: chunk).execute().value
            result += rows
        }
        return result
    }

    func meals(countryCode: String, userIds: [UUID]) async throws -> [Meal] {
        guard !userIds.isEmpty else { return [] }
        var result: [Meal] = []
        for chunk in chunks(userIds) {
            let rows: [Meal] = try await client.from("entries").select()
                .eq("kind", value: "meal")
                .eq("country_code", value: countryCode)
                .in("user_id", values: chunk)
                .order("date_tried", ascending: false)
                .limit(60)
                .execute().value
            result += rows
        }
        return result.sorted { $0.date > $1.date }
    }

    func insertMeal(_ meal: NewMeal) async throws -> Meal {
        try await client.from("entries").insert(meal).select().single().execute().value
    }

    func updateMeal(id: UUID, _ patch: MealPatch) async throws -> Meal {
        try await client.from("entries").update(patch).eq("id", value: id).select().single().execute().value
    }

    /// Row first, then its photos (best-effort). The other order could leave
    /// a meal whose photos were already gone if the row delete failed.
    func deleteMeal(_ meal: Meal) async throws {
        try await client.from("entries").delete().eq("id", value: meal.id).execute()
        await removePhotos(meal.photos)
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

    // ── Tastes ───────────────────────────────────────────────────────────────

    func tastes(userIds: [UUID]) async throws -> [Taste] {
        var result: [Taste] = []
        for chunk in chunks(Array(Set(userIds))) {
            let rows: [Taste] = try await allPages { from, to in
                try await client.from("tastes").select()
                    .in("user_id", values: chunk)
                    .order("user_id").order("country_code")
                    .range(from: from, to: to)
                    .execute().value
            }
            result += rows
        }
        return result
    }

    func addTastes(_ codes: [String]) async throws {
        guard !codes.isEmpty else { return }
        struct Params: Encodable { let codes: [String] }
        try await client.rpc("add_tastes", params: Params(codes: codes)).execute()
    }

    func removeTaste(countryCode: String) async throws {
        try await client.from("tastes").delete()
            .eq("user_id", value: uid())
            .eq("country_code", value: countryCode)
            .execute()
    }

    // ── Restaurants to try ───────────────────────────────────────────────────

    func savedPlaces() async throws -> [SavedPlace] {
        try await allPages { from, to in
            try await client.from("saved_places").select()
                .eq("user_id", value: uid())
                .not("cuisine_code", operator: .is, value: "null")
                .order("created_at", ascending: false)
                .order("id")
                .range(from: from, to: to)
                .execute().value
        }
    }

    func savePlace(_ place: NewSavedPlace) async throws -> SavedPlace {
        try await client.from("saved_places").insert(place).select().single().execute().value
    }

    func updateSavedPlace(id: UUID, _ patch: SavedPlacePatch) async throws -> SavedPlace {
        try await client.from("saved_places").update(patch).eq("id", value: id).select().single().execute().value
    }

    func deleteSavedPlace(id: UUID) async throws {
        try await client.from("saved_places").delete().eq("id", value: id).execute()
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

    /// friends_feed still returns travel-era memories too; they're skipped
    /// here, reading on until a page of meals is full (or the feed ends).
    func friendsFeed(before: Date?, limit: Int) async throws -> [Meal] {
        struct Params: Encodable { let beforeTs: String?; let pageSize: Int }
        var cursor = before
        var meals: [Meal] = []
        for _ in 0..<4 {
            let page: [Meal] = try await client.rpc("friends_feed", params: Params(
                beforeTs: cursor.map { $0.formatted(Self.cursorStyle) }, pageSize: limit
            )).execute().value
            meals += page.filter(\.isMeal)
            guard page.count == limit, meals.count < limit, let last = page.last else { break }
            cursor = last.createdAt
        }
        return Array(meals.prefix(limit))
    }

    func discoverFeed(before: Date?, limit: Int) async throws -> [Meal] {
        let me = try await uid()
        var query = client.from("entries").select()
            .eq("kind", value: "meal")
            .eq("visibility", value: "public")
            .neq("user_id", value: me)
        if let before {
            query = query.lt("created_at", value: before.formatted(Self.cursorStyle))
        }
        return try await query.order("created_at", ascending: false).limit(limit).execute().value
    }

    func recentTastes(userIds: [UUID], limit: Int) async throws -> [Taste] {
        guard !userIds.isEmpty else { return [] }
        var result: [Taste] = []
        for chunk in chunks(Array(Set(userIds))) {
            let rows: [Taste] = try await client.from("tastes").select()
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

    func reactions(mealIds: [UUID]) async throws -> [Reaction] {
        var result: [Reaction] = []
        for chunk in chunks(Array(Set(mealIds))) {
            let rows: [Reaction] = try await client.from("entry_reactions").select()
                .in("entry_id", values: chunk).execute().value
            result += rows
        }
        return result
    }

    func setReaction(mealId: UUID, emoji: String, on: Bool) async throws {
        let me = try await uid()
        if on {
            try await client.from("entry_reactions")
                .upsert(["entry_id": mealId.uuidString, "user_id": me.uuidString, "emoji": emoji],
                        onConflict: "entry_id,user_id,emoji", ignoreDuplicates: true)
                .execute()
        } else {
            try await client.from("entry_reactions").delete()
                .eq("entry_id", value: mealId).eq("user_id", value: me).eq("emoji", value: emoji)
                .execute()
        }
    }

    func comments(mealId: UUID) async throws -> [Comment] {
        try await client.from("entry_comments").select()
            .eq("entry_id", value: mealId)
            .order("created_at", ascending: true)
            .execute().value
    }

    func commentCounts(mealIds: [UUID]) async throws -> [UUID: Int] {
        struct Row: Decodable { let entryId: UUID }
        var counts: [UUID: Int] = [:]
        for chunk in chunks(Array(Set(mealIds))) {
            let rows: [Row] = try await client.from("entry_comments").select("entry_id")
                .in("entry_id", values: chunk).execute().value
            for row in rows { counts[row.entryId, default: 0] += 1 }
        }
        return counts
    }

    func addComment(mealId: UUID, text: String) async throws {
        struct Insert: Encodable { let entryId: UUID; let authorId: UUID; let text: String }
        try await client.from("entry_comments")
            .insert(Insert(entryId: mealId, authorId: uid(), text: String(text.prefix(2000))))
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

    func createPost(groupId: UUID, text: String, mealId: UUID?, pick: DinnerPick?) async throws {
        struct Insert: Encodable {
            let groupId: UUID
            let authorId: UUID
            let entryId: UUID?
            let text: String
            let cuisineCode: String?
            let placeName: String?
            let placeAddress: String?
            let placeLat: Double?
            let placeLng: Double?
        }
        // A pick always carries a readable line for older clients and pushes.
        let body = text.trimmed.isEmpty ? (pick?.fallbackText ?? "") : text
        let place = pick?.hasPlace == true ? pick : nil
        try await client.from("group_posts")
            .insert(Insert(groupId: groupId, authorId: uid(), entryId: mealId,
                           text: String(body.prefix(4000)),
                           cuisineCode: pick?.cuisineCode,
                           placeName: place?.placeName.map { String($0.prefix(200)) },
                           placeAddress: place?.placeAddress.map { String($0.prefix(300)) },
                           placeLat: place?.placeLat, placeLng: place?.placeLng))
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
