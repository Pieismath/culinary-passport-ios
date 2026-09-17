import Foundation

/// Everything the app asks of a server. `SupabaseBackend` is the real one;
/// `DemoBackend` serves in-memory fixtures so every screen can be built,
/// screenshotted and tested with no network or account (`-uiPreview`).
///
/// Visibility is always the server's call: implementations return only what
/// the signed-in user may see (Supabase RLS; the demo mirrors the rules).
protocol Backend: AnyObject {
    // ── Session ──────────────────────────────────────────────────────────────
    func currentUserId() async throws -> UUID
    func signOut() async
    func deleteAccount() async throws

    // ── Profiles ─────────────────────────────────────────────────────────────
    func myProfile() async throws -> Profile?
    func profile(id: UUID) async throws -> Profile?
    func profiles(ids: [UUID]) async throws -> [Profile]
    func updateProfile(_ patch: ProfilePatch) async throws
    /// Uploads to avatars/{uid}/… and points the profile at it; returns the URL.
    func uploadAvatar(_ jpeg: Data) async throws -> String
    func searchProfiles(_ query: String) async throws -> [Profile]

    // ── Memories ─────────────────────────────────────────────────────────────
    func memories(userId: UUID) async throws -> [Memory]
    func memory(id: UUID) async throws -> Memory?
    func memories(ids: [UUID]) async throws -> [Memory]
    func memories(countryCode: String, userIds: [UUID]) async throws -> [Memory]
    func insertMemory(_ memory: NewMemory) async throws -> Memory
    func updateMemory(id: UUID, _ patch: MemoryPatch) async throws -> Memory
    func deleteMemory(_ memory: Memory) async throws
    func uploadPhoto(_ jpeg: Data) async throws -> String
    func removePhotos(_ paths: [String]) async
    func photoData(path: String) async throws -> Data

    // ── Stamps + bucket list ─────────────────────────────────────────────────
    func stamps(userIds: [UUID]) async throws -> [Stamp]
    func stamps(countryCode: String, userIds: [UUID]) async throws -> [Stamp]
    func addStamps(_ items: [StampInput]) async throws
    func removeStamp(countryCode: String) async throws
    func bucketList() async throws -> Set<String>
    func setBucketListed(_ code: String, _ on: Bool) async throws

    // ── Social graph ─────────────────────────────────────────────────────────
    func followingIds(of userId: UUID) async throws -> [UUID]
    func followerIds(of userId: UUID) async throws -> [UUID]
    func followCounts(userId: UUID) async throws -> (followers: Int, following: Int)
    func setFollowing(_ userId: UUID, _ follow: Bool) async throws
    func blockedIds() async throws -> Set<UUID>
    func setBlocked(_ userId: UUID, _ blocked: Bool) async throws
    func report(contentType: String, contentId: UUID, reason: String) async throws

    // ── Feeds ────────────────────────────────────────────────────────────────
    func friendsFeed(before: Date?, limit: Int) async throws -> [Memory]
    func discoverFeed(before: Date?, limit: Int) async throws -> [Memory]
    /// Recent stamps from people you follow (the "Maya stamped Portugal" strip).
    func recentStamps(userIds: [UUID], limit: Int) async throws -> [Stamp]
    func activity(limit: Int) async throws -> [ActivityRow]

    // ── Reactions + comments on memories ─────────────────────────────────────
    func reactions(memoryIds: [UUID]) async throws -> [Reaction]
    func setReaction(memoryId: UUID, emoji: String, on: Bool) async throws
    func comments(memoryId: UUID) async throws -> [Comment]
    func commentCounts(memoryIds: [UUID]) async throws -> [UUID: Int]
    func addComment(memoryId: UUID, text: String) async throws
    func deleteComment(id: UUID) async throws

    // ── Groups ───────────────────────────────────────────────────────────────
    func myGroups() async throws -> [Group]
    func groupMembers(groupIds: [UUID]) async throws -> [GroupMember]
    func createGroup(name: String) async throws -> Group
    func joinGroup(inviteCode: String) async throws -> UUID
    func updateGroup(id: UUID, _ patch: GroupPatch) async throws
    func uploadGroupCover(groupId: UUID, _ jpeg: Data) async throws -> String
    func groupCoverURL(_ path: String) -> URL?
    func deleteGroup(id: UUID) async throws
    func leaveGroup(id: UUID) async throws

    // ── Group chat ───────────────────────────────────────────────────────────
    func posts(groupId: UUID, before: Date?, limit: Int) async throws -> [GroupPost]
    func createPost(groupId: UUID, text: String, memoryId: UUID?) async throws
    func deletePost(id: UUID) async throws
    func postReactions(postIds: [UUID]) async throws -> [PostReaction]
    func setPostReaction(postId: UUID, emoji: String, on: Bool) async throws
    func postComments(postIds: [UUID]) async throws -> [PostComment]
    func addPostComment(postId: UUID, text: String) async throws
    func deletePostComment(id: UUID) async throws
    /// Fires whenever anything in this group's chat changes (realtime).
    func chatChanges(groupId: UUID) -> AsyncStream<Void>

    // ── Misc ─────────────────────────────────────────────────────────────────
    func logEvent(_ name: String, props: [String: String]?)
    func registerDeviceToken(_ token: String) async throws
}

/// Editable profile fields. Nil = leave untouched.
struct ProfilePatch: Encodable {
    var name: String?
    var username: String?
    var bio: String?
    var isPublic: Bool?
    var color: String?
    var homeCountry: String?
    var homeCity: String?
    var yearlyGoal: Int??

    enum CodingKeys: String, CodingKey {
        case name, username, bio, isPublic, color, homeCountry, homeCity, yearlyGoal
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(bio, forKey: .bio)
        try c.encodeIfPresent(isPublic, forKey: .isPublic)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(homeCountry, forKey: .homeCountry)
        try c.encodeIfPresent(homeCity, forKey: .homeCity)
        // Double optional: .some(nil) clears the goal, nil leaves it alone.
        if let yearlyGoal { try c.encode(yearlyGoal, forKey: .yearlyGoal) }
    }
}

/// Owner-only group edits (RLS enforces ownership). Nil = untouched.
struct GroupPatch: Encodable {
    var name: String?
    var inviteCode: String?
    var coverPhoto: String?
}

enum Handles {
    private static func allowed(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_")
    }

    /// "@Jason.F " → "jason.f". ASCII letters, digits, dot, underscore (no
    /// look-alike Unicode handles); 30 max.
    static func normalizedUsername(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "@" })
            .lowercased()
        return String(trimmed.filter(allowed).prefix(30))
    }

    static func isValidUsername(_ username: String) -> Bool {
        (3...30).contains(username.count) && username == normalizedUsername(username)
            && username.first.map { $0.isLetter || $0.isNumber } == true
    }

    /// Why a typed username won't do, or nil when it's fine (or empty).
    static func problem(with raw: String) -> String? {
        let typed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "@" }))
        guard !typed.isEmpty else { return nil }
        if typed.count > 30 { return "30 characters at most." }
        if !typed.allSatisfy(allowed) { return "Use letters, numbers, dots and underscores." }
        if typed.count < 3 { return "At least 3 characters." }
        if !(typed.first.map { $0.isLetter || $0.isNumber } ?? false) { return "Start with a letter or number." }
        return nil
    }
}
