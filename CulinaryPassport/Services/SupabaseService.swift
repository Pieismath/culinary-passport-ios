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
            options: .init(
                db: .init(encoder: Self.encoder, decoder: Self.decoder),
                auth: .init(
                    storage: AuthClient.Configuration.defaultLocalStorage,
                    // Opt into the next-major behavior: the locally stored
                    // session is emitted as .initialSession immediately (even
                    // if expired) instead of after a refresh attempt.
                    // SessionStore checks isExpired before side effects.
                    emitLocalSessionAsInitialSession: true
                )
            )
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

    /// Strictly the signed-in user's OWN entries — their journal, their globe,
    /// their profile numbers.
    ///
    /// Filtered server-side rather than trusting RLS to mean "mine": the
    /// entries policy deliberately also returns public and group-shared meals
    /// from other people, which belongs on the group globe and the discover
    /// feed (`entriesForUsers`, `discoverFeed`) — never in "my journal".
    func myEntries() async throws -> [Entry] {
        let session = try await client.auth.session
        return try await client.from("entries").select()
            .eq("user_id", value: session.user.id)
            .order("date_tried", ascending: false)
            .execute().value
    }

    func addEntry(_ entry: NewEntry) async throws {
        try await client.from("entries").insert(entry).execute()
    }

    /// Current user's profile, or nil if the row is gone (deleted user / stale
    /// session). Fetched as an array + `.first` rather than `.single()`, so a
    /// missing row returns nil instead of throwing a coercion error that would
    /// break the globe and profile screens. Callers should sign out on nil.
    func myProfile() async throws -> Profile? {
        let session = try await client.auth.session
        let rows: [Profile] = try await client.from("profiles")
            .select().eq("id", value: session.user.id).limit(1).execute().value
        return rows.first
    }

    /// Sign the current user out (routes the app back to the sign-in screen via
    /// the auth state observer). Used when the profile row has vanished.
    func signOut() async {
        try? await client.auth.signOut()
    }

    // ── Meal photos (private `photos` bucket — render via SignedPhotoImage) ──

    /// Upload a JPEG to photos/{user_id}/{uuid}.jpg; returns the stored path.
    /// Reads go through PhotoURLCache / SignedPhotoImage (signed, expiring
    /// URLs) — the bucket is private and gated on entry visibility.
    func uploadPhoto(_ jpeg: Data) async throws -> String {
        let session = try await client.auth.session
        let path = "\(session.user.id.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from("photos").upload(
            path, data: jpeg,
            options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false)
        )
        return path
    }

    func updateEntry(id: UUID, _ patch: EntryUpdate) async throws {
        try await client.from("entries").update(patch).eq("id", value: id).execute()
    }

    func deleteEntry(id: UUID) async throws {
        try await client.from("entries").delete().eq("id", value: id).execute()
    }

    /// Delete an entry AND its stored photos (photo removal is best-effort —
    /// an orphaned object is invisible behind the private bucket anyway).
    func deleteEntry(_ entry: Entry) async throws {
        if !entry.photos.isEmpty {
            _ = try? await client.storage.from("photos").remove(paths: entry.photos)
        }
        try await deleteEntry(id: entry.id)
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

    func groupMemberIds(groupId: UUID) async throws -> [UUID] {
        try await groupMembers(groupId: groupId).map(\.userId)
    }

    func groupMembers(groupId: UUID) async throws -> [GroupMember] {
        try await client.from("group_members").select()
            .eq("group_id", value: groupId).execute().value
    }

    /// Memberships for several groups at once — the groups list needs member
    /// counts and faces without a query per row.
    func groupMembers(groupIds: [UUID]) async throws -> [GroupMember] {
        guard !groupIds.isEmpty else { return [] }
        return try await client.from("group_members").select()
            .in("group_id", values: groupIds).execute().value
    }

    /// Fresh copy of one group (post-edit refresh); nil if we lost access.
    func group(id: UUID) async throws -> Group? {
        let rows: [Group] = try await client.from("groups").select()
            .eq("id", value: id).limit(1).execute().value
        return rows.first
    }

    /// Owner-only edits (RLS enforces ownership). Nil fields are left untouched.
    struct GroupPatch: Encodable {
        var name: String?
        var inviteCode: String?
        var coverPhoto: String?
    }

    func updateGroup(id: UUID, _ patch: GroupPatch) async throws {
        try await client.from("groups").update(patch).eq("id", value: id).execute()
    }

    /// Upload a group photo; returns the stored path for groups.cover_photo.
    /// Unique name per upload — the bucket has no UPDATE policy, so overwriting
    /// in place isn't possible (old covers are orphaned, which is fine).
    func uploadGroupCover(groupId: UUID, _ jpeg: Data) async throws -> String {
        let path = "\(groupId.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from("group-covers").upload(
            path, data: jpeg,
            options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false)
        )
        return path
    }

    /// Public URL for a group cover (the bucket is public by design).
    func groupCoverURL(_ path: String) -> URL? {
        try? client.storage.from("group-covers").getPublicURL(path: path)
    }

    /// Owner-only (RLS). Members, posts, comments and reactions cascade.
    func deleteGroup(id: UUID) async throws {
        try await client.from("groups").delete().eq("id", value: id).execute()
    }

    func leaveGroup(groupId: UUID) async throws {
        let session = try await client.auth.session
        try await client.from("group_members").delete()
            .eq("group_id", value: groupId)
            .eq("user_id", value: session.user.id)
            .execute()
    }

    /// Entries for a set of users (RLS returns only what the caller may read —
    /// for co-members that includes each other's group-shared + public entries).
    func entriesForUsers(_ ids: [UUID]) async throws -> [Entry] {
        guard !ids.isEmpty else { return [] }
        return try await client.from("entries").select().in("user_id", values: ids).execute().value
    }

    /// A single entry by id, or nil if it isn't visible to the caller / was
    /// deleted. Used to render linked meal cards in the group feed.
    func entry(id: UUID) async throws -> Entry? {
        let rows: [Entry] = try await client.from("entries")
            .select().eq("id", value: id).limit(1).execute().value
        return rows.first
    }

    // ── Group feed (v1.2) ────────────────────────────────────────────────────

    /// One page of chat, newest first. `before` pages into history.
    func feedPosts(groupId: UUID, before: Date? = nil, limit: Int = 50) async throws -> [GroupPost] {
        var query = client.from("group_posts").select()
            .eq("group_id", value: groupId)
        if let before {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            query = query.lt("created_at", value: iso.string(from: before))
        }
        return try await query
            .order("created_at", ascending: false)
            .limit(limit)
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
            // Idempotent: picking an emoji you've already used must not blow up
            // on the (post, user, emoji) primary key.
            try await client.from("post_reactions")
                .upsert(["post_id": postId.uuidString, "user_id": session.user.id.uuidString, "emoji": emoji],
                        onConflict: "post_id,user_id,emoji")
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

    /// All comments for a batch of posts — the chat renders threads inline, so
    /// it loads every visible post's comments in one query.
    func comments(postIds: [UUID]) async throws -> [PostComment] {
        guard !postIds.isEmpty else { return [] }
        return try await client.from("post_comments").select()
            .in("post_id", values: postIds)
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
    /// `color` is the user's globe color; groups re-map duplicates at render
    /// time (GroupPalette), so two members never share a color in one group.
    func updateMyProfile(name: String, username: String?, bio: String?,
                         isPublic: Bool, color: String) async throws {
        struct Patch: Encodable {
            let name: String
            let username: String?
            let bio: String?
            let isPublic: Bool
            let color: String
        }
        let session = try await client.auth.session
        // Usernames are @handles: store lowercase so "Jason" and "jason"
        // can't coexist as different people.
        try await client.from("profiles")
            .update(Patch(name: name, username: username?.lowercased(), bio: bio,
                          isPublic: isPublic, color: color))
            .eq("id", value: session.user.id)
            .execute()
    }

    // ── Profile photo ────────────────────────────────────────────────────────

    /// Upload a profile photo and point the profile at it. Users own the
    /// `avatars/{user_id}/…` folder (see the user_avatar_uploads migration);
    /// the path is unique per upload so caches can't serve a stale face.
    /// Returns the public URL now stored on the profile.
    func uploadAvatar(_ jpeg: Data) async throws -> String {
        let session = try await client.auth.session
        let path = "\(session.user.id.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        try await client.storage.from("avatars").upload(
            path, data: jpeg,
            options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false)
        )
        let url = try client.storage.from("avatars").getPublicURL(path: path).absoluteString
        struct AvatarPatch: Encodable { let avatarUrl: String }
        try await client.from("profiles")
            .update(AvatarPatch(avatarUrl: url))
            .eq("id", value: session.user.id)
            .execute()
        return url
    }

    /// Who follows this user / who they follow. The profiles the ids resolve to
    /// are filtered by the profiles SELECT policy, so private strangers simply
    /// don't come back — counts can legitimately exceed the visible list.
    func followerIds(userId: UUID) async throws -> [UUID] {
        let rows: [Follow] = try await client.from("follows").select()
            .eq("followee_id", value: userId).execute().value
        return rows.map(\.followerId)
    }

    func followingIds(userId: UUID) async throws -> [UUID] {
        let rows: [Follow] = try await client.from("follows").select()
            .eq("follower_id", value: userId).execute().value
        return rows.map(\.followeeId)
    }

    func followCounts(userId: UUID) async throws -> (followers: Int, following: Int) {
        // head:true + count → the DB counts; no rows cross the wire.
        async let followers = client.from("follows")
            .select("*", head: true, count: .exact)
            .eq("followee_id", value: userId).execute().count
        async let following = client.from("follows")
            .select("*", head: true, count: .exact)
            .eq("follower_id", value: userId).execute().count
        return (try await followers ?? 0, try await following ?? 0)
    }

    /// Another user's public entries (RLS returns only rows they've shared).
    func publicEntries(userId: UUID) async throws -> [Entry] {
        try await client.from("entries").select()
            .eq("user_id", value: userId)
            .order("date_tried", ascending: false)
            .execute().value
    }

    /// Discover feed (v1.1 item 8): recent *public* meals from users with a
    /// public profile.
    ///
    /// Entry privacy now lives in the DB: we ask only for `visibility = public`
    /// rows (the entries SELECT policy also permits own/group-shared rows, but we
    /// don't want those in discover), so no private/group meals are fetched and
    /// discarded client-side.
    ///
    /// The author `isPublic` filter stays and is *not* redundant: the profiles
    /// SELECT policy intentionally also returns group co-members' rows (private or
    /// not) so the group globe/feed can render them — this filter keeps discover
    /// limited to genuinely public profiles.
    func discoverFeed(limit: Int = 40) async throws -> [FeedItem] {
        let entries: [Entry] = try await client.from("entries").select()
            .eq("visibility", value: "public")
            .order("created_at", ascending: false)
            .limit(150)
            .execute().value
        let authorIds = Array(Set(entries.map(\.userId)))
        let publicAuthors = (try await profiles(ids: authorIds)).filter { $0.isPublic == true }
        let byId = Dictionary(uniqueKeysWithValues: publicAuthors.map { ($0.id, $0) })
        return entries.compactMap { e in byId[e.userId].map { FeedItem(entry: e, author: $0) } }
            .prefix(limit).map { $0 }
    }

    /// Well-rated meals from people the user follows or shares a group with —
    /// the raw material for restaurant recommendations. RLS already limits this
    /// to entries those people chose to share.
    func entriesFromMyPeople(limit: Int = 300) async throws -> (entries: [Entry], people: [UUID: Profile]) {
        let session = try await client.auth.session
        var ids = Set<UUID>()
        ids.formUnion(try await followingIds(userId: session.user.id))
        for group in (try? await myGroups()) ?? [] {
            ids.formUnion((try? await groupMemberIds(groupId: group.id)) ?? [])
        }
        ids.remove(session.user.id)
        guard !ids.isEmpty else { return ([], [:]) }

        let entries: [Entry] = try await client.from("entries").select()
            .in("user_id", values: Array(ids))
            .gte("rating", value: 4)
            .order("date_tried", ascending: false)
            .limit(limit)
            .execute().value
        let profiles = try await profiles(ids: Array(Set(entries.map(\.userId))))
        return (entries, Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) }))
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

    // ── Want to Try (country wishlist + saved restaurants) ──────────────────

    func wishlist() async throws -> Set<String> {
        struct Row: Decodable { let countryCode: String }
        let session = try await client.auth.session
        let rows: [Row] = try await client.from("wishlist").select("country_code")
            .eq("user_id", value: session.user.id).execute().value
        return Set(rows.map(\.countryCode))
    }

    func setWishlisted(_ code: String, _ on: Bool) async throws {
        let session = try await client.auth.session
        if on {
            try await client.from("wishlist")
                .upsert(["country_code": code, "user_id": session.user.id.uuidString],
                        onConflict: "country_code,user_id")
                .execute()
        } else {
            try await client.from("wishlist").delete()
                .eq("country_code", value: code)
                .eq("user_id", value: session.user.id)
                .execute()
        }
    }

    func savedRestaurants() async throws -> [SavedRestaurant] {
        let session = try await client.auth.session
        return try await client.from("saved_restaurants").select()
            .eq("user_id", value: session.user.id)
            .order("created_at", ascending: false)
            .execute().value
    }

    func saveRestaurant(name: String, city: String?, countryCode: String, note: String?) async throws {
        struct Insert: Encodable {
            let userId: UUID
            let restaurantName: String
            let city: String?
            let countryCode: String
            let note: String?
        }
        let session = try await client.auth.session
        try await client.from("saved_restaurants")
            .upsert(Insert(userId: session.user.id, restaurantName: name, city: city,
                           countryCode: countryCode, note: note),
                    onConflict: "user_id,restaurant_name,country_code")
            .execute()
    }

    func unsaveRestaurant(id: UUID) async throws {
        try await client.from("saved_restaurants").delete().eq("id", value: id).execute()
    }

    // ── Reactions & comments on meals ────────────────────────────────────────

    func entryReactions(entryIds: [UUID]) async throws -> [EntryReaction] {
        guard !entryIds.isEmpty else { return [] }
        return try await client.from("entry_reactions").select()
            .in("entry_id", values: entryIds).execute().value
    }

    func toggleEntryReaction(entryId: UUID, emoji: String, on: Bool) async throws {
        let session = try await client.auth.session
        if on {
            try await client.from("entry_reactions")
                .upsert(["entry_id": entryId.uuidString,
                         "user_id": session.user.id.uuidString,
                         "emoji": emoji],
                        onConflict: "entry_id,user_id,emoji")
                .execute()
        } else {
            try await client.from("entry_reactions").delete()
                .eq("entry_id", value: entryId)
                .eq("user_id", value: session.user.id)
                .eq("emoji", value: emoji)
                .execute()
        }
    }

    func entryComments(entryId: UUID) async throws -> [EntryComment] {
        try await client.from("entry_comments").select()
            .eq("entry_id", value: entryId)
            .order("created_at", ascending: true)
            .execute().value
    }

    func addEntryComment(entryId: UUID, text: String) async throws {
        struct Insert: Encodable { let entryId: UUID; let authorId: UUID; let text: String }
        let session = try await client.auth.session
        try await client.from("entry_comments")
            .insert(Insert(entryId: entryId, authorId: session.user.id, text: text))
            .execute()
    }

    func deleteEntryComment(id: UUID) async throws {
        try await client.from("entry_comments").delete().eq("id", value: id).execute()
    }

    // ── Blocks & reports (UGC moderation) ────────────────────────────────────

    func blockedIds() async throws -> Set<UUID> {
        struct Row: Decodable { let blockedId: UUID }
        let session = try await client.auth.session
        let rows: [Row] = try await client.from("blocks").select("blocked_id")
            .eq("blocker_id", value: session.user.id).execute().value
        return Set(rows.map(\.blockedId))
    }

    func setBlocked(_ userId: UUID, _ blocked: Bool) async throws {
        let session = try await client.auth.session
        if blocked {
            try await client.from("blocks")
                .upsert(["blocker_id": session.user.id.uuidString, "blocked_id": userId.uuidString],
                        onConflict: "blocker_id,blocked_id")
                .execute()
        } else {
            try await client.from("blocks").delete()
                .eq("blocker_id", value: session.user.id)
                .eq("blocked_id", value: userId)
                .execute()
        }
    }

    /// Write-only moderation queue; reviewed out-of-band.
    func report(contentType: String, contentId: UUID, reason: String) async throws {
        struct Insert: Encodable {
            let reporterId: UUID
            let contentType: String
            let contentId: UUID
            let reason: String
        }
        let session = try await client.auth.session
        try await client.from("reports")
            .insert(Insert(reporterId: session.user.id, contentType: contentType,
                           contentId: contentId, reason: reason))
            .execute()
    }

    // ── Activity ("someone noticed you") ─────────────────────────────────────

    /// Recent follows, reactions, and comments aimed at the current user,
    /// newest first. Assembled from the base tables — no extra infra.
    func activity(limit: Int = 60) async throws -> [ActivityItem] {
        let session = try await client.auth.session
        let me = session.user.id

        struct FollowRow: Decodable { let followerId: UUID; let createdAt: Date }
        async let followRows: [FollowRow] = client.from("follows").select()
            .eq("followee_id", value: me)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value

        let mine = try await myEntries()
        let mineById = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0) })
        let ids = Array(mineById.keys)

        async let reactionRows: [EntryReaction] = entryReactions(entryIds: ids)
        struct CommentRow: Decodable {
            let id: UUID; let entryId: UUID; let authorId: UUID
            let text: String; let createdAt: Date
        }
        async let commentRows: [CommentRow] = ids.isEmpty ? [] :
            client.from("entry_comments").select()
                .in("entry_id", values: ids)
                .order("created_at", ascending: false)
                .limit(limit)
                .execute().value

        let (follows, reactions, comments) = try await (followRows, reactionRows, commentRows)

        var items: [ActivityItem] = []
        var actorIds = Set<UUID>()

        for f in follows {
            actorIds.insert(f.followerId)
            items.append(.init(id: "f-\(f.followerId)", actor: .placeholder(f.followerId),
                               kind: .followedYou, date: f.createdAt))
        }
        for r in reactions where r.userId != me {
            guard let entry = mineById[r.entryId] else { continue }
            actorIds.insert(r.userId)
            items.append(.init(id: "r-\(r.entryId)-\(r.userId)-\(r.emoji)",
                               actor: .placeholder(r.userId),
                               kind: .reacted(emoji: r.emoji, entry: entry),
                               date: r.createdAt ?? entry.createdAt))
        }
        for c in comments where c.authorId != me {
            guard let entry = mineById[c.entryId] else { continue }
            actorIds.insert(c.authorId)
            items.append(.init(id: "c-\(c.id)", actor: .placeholder(c.authorId),
                               kind: .commented(text: c.text, entry: entry),
                               date: c.createdAt))
        }

        // Resolve actor profiles in one round trip.
        let people = (try? await profiles(ids: Array(actorIds))) ?? []
        let byId = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        return items
            .compactMap { item in byId[item.actor.id].map {
                ActivityItem(id: item.id, actor: $0, kind: item.kind, date: item.date)
            } }
            .sorted { $0.date > $1.date }
    }

    // ── Yearly goal ──────────────────────────────────────────────────────────

    func updateYearlyGoal(_ goal: Int?) async throws {
        struct Patch: Encodable { let yearlyGoal: Int? }
        let session = try await client.auth.session
        try await client.from("profiles")
            .update(Patch(yearlyGoal: goal))
            .eq("id", value: session.user.id)
            .execute()
    }

    // ── Auth lifecycle ───────────────────────────────────────────────────────

    /// Sends the reset email; the link deep-links back into the app, which
    /// then lets the user set a new password.
    func requestPasswordReset(email: String) async throws {
        try await client.auth.resetPasswordForEmail(
            email, redirectTo: URL(string: "culinarypassport://reset-password"))
    }

    func updatePassword(_ newPassword: String) async throws {
        try await client.auth.update(user: UserAttributes(password: newPassword))
    }

    /// App Store 5.1.1(v): permanent in-app account deletion. The edge
    /// function wipes storage and the auth user; local session is then dead.
    func deleteAccount() async throws {
        try await client.functions.invoke("delete-account")
        try? await client.auth.signOut()
    }

    // ── Minimal analytics ────────────────────────────────────────────────────

    /// Fire-and-forget event logging (insert-only table; nobody reads it via
    /// the API). Never throws into product flows.
    func logEvent(_ name: String, props: [String: String]? = nil) {
        Task {
            struct Insert: Encodable {
                let userId: UUID
                let name: String
                let props: [String: String]?
            }
            guard let session = try? await client.auth.session else { return }
            _ = try? await client.from("events")
                .insert(Insert(userId: session.user.id, name: name, props: props))
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
