import Foundation
import UIKit

/// In-memory backend with a believable cast, for `-uiPreview`, screenshots
/// and tests. Mirrors the server's visibility rules closely enough that
/// screens behave the way they will against Supabase. Nothing leaves the device.
final class DemoBackend: Backend {
    static let meId = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000001")!

    private let lock = NSLock()
    private var profilesById: [UUID: Profile] = [:]
    private var memoriesById: [UUID: Memory] = [:]
    private var stampsByKey: [String: Stamp] = [:]
    private var bucket: Set<String> = []
    private var follows: Set<[UUID]> = []            // [follower, followee]
    private var blocked: Set<UUID> = []
    private var reactions: [Reaction] = []
    private var comments: [Comment] = []
    private var groups: [Group] = []
    private var members: [GroupMember] = []
    private var posts: [GroupPost] = []
    private var postReactions: [PostReaction] = []
    private var postComments: [PostComment] = []
    private var uploaded: [String: Data] = [:]
    /// Simulated round trip, so loading states are exercised.
    var latency: Duration = .milliseconds(120)

    init(seed: Bool = true) {
        if seed { DemoData.seed(into: self) }
    }

    private func wait() async { try? await Task.sleep(for: latency) }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    // ── Seeding (DemoData) ───────────────────────────────────────────────────

    func seedProfile(_ p: Profile) { sync { profilesById[p.id] = p } }
    func seedMemory(_ m: Memory) {
        sync {
            memoriesById[m.id] = m
            stampFromMemoryLocked(m)
        }
    }
    func seedStamp(_ s: Stamp) { sync { stampsByKey["\(s.userId)|\(s.countryCode)"] = s } }
    func seedFollow(_ follower: UUID, _ followee: UUID) { sync { _ = follows.insert([follower, followee]) } }
    func seedBucket(_ codes: [String]) { sync { bucket.formUnion(codes) } }
    func seedReaction(_ r: Reaction) { sync { reactions.append(r) } }
    func seedComment(_ c: Comment) { sync { comments.append(c) } }
    func seedGroup(_ g: Group, members ids: [UUID]) {
        sync {
            groups.append(g)
            for id in ids {
                members.append(GroupMember(groupId: g.id, userId: id,
                                           role: id == g.createdBy ? .owner : .member, joinedAt: g.createdAt))
            }
        }
    }
    func seedPost(_ p: GroupPost) { sync { posts.append(p) } }
    func seedPostReaction(_ r: PostReaction) { sync { postReactions.append(r) } }
    func seedPostComment(_ c: PostComment) { sync { postComments.append(c) } }

    // ── Rules ────────────────────────────────────────────────────────────────

    private var me: UUID { Self.meId }

    private func sharesGroupLocked(_ a: UUID, _ b: UUID) -> Bool {
        let groupsA = Set(members.filter { $0.userId == a }.map(\.groupId))
        return members.contains { $0.userId == b && groupsA.contains($0.groupId) }
    }

    private func isFriendLocked(_ a: UUID, _ b: UUID) -> Bool {
        guard a != b else { return false }
        return sharesGroupLocked(a, b) || (follows.contains([a, b]) && follows.contains([b, a]))
    }

    private func canSeeLocked(_ m: Memory) -> Bool {
        m.userId == me || m.visibility == .public || (m.visibility == .friends && isFriendLocked(m.userId, me))
    }

    private func canSeeProfileLocked(_ id: UUID) -> Bool {
        id == me || profilesById[id]?.isPublic == true || isFriendLocked(id, me)
    }

    private func stampFromMemoryLocked(_ m: Memory) {
        let key = "\(m.userId)|\(m.countryCode)"
        if var existing = stampsByKey[key] {
            existing.firstVisited = min(existing.firstVisited ?? m.date, m.date)
            existing.lastVisited = max(existing.lastVisited ?? m.date, m.date)
            stampsByKey[key] = existing
        } else {
            stampsByKey[key] = Stamp(userId: m.userId, countryCode: m.countryCode,
                                     firstVisited: m.date, lastVisited: m.date,
                                     source: .memory, createdAt: m.createdAt)
        }
    }

    private func dropMemoryOnlyStampLocked(user: UUID, code: String, except id: UUID) {
        let key = "\(user)|\(code)"
        guard stampsByKey[key]?.source == .memory else { return }
        let others = memoriesById.values.contains { $0.userId == user && $0.countryCode == code && $0.id != id }
        if !others { stampsByKey[key] = nil }
    }

    // ── Session ──────────────────────────────────────────────────────────────

    func currentUserId() async throws -> UUID { me }
    func signOut() async {}
    func deleteAccount() async throws { await wait() }

    // ── Profiles ─────────────────────────────────────────────────────────────

    func myProfile() async throws -> Profile? { sync { profilesById[me] } }

    func profile(id: UUID) async throws -> Profile? {
        await wait()
        return sync { canSeeProfileLocked(id) ? profilesById[id] : nil }
    }

    func profiles(ids: [UUID]) async throws -> [Profile] {
        sync { ids.compactMap { canSeeProfileLocked($0) ? profilesById[$0] : nil } }
    }

    func updateProfile(_ patch: ProfilePatch) async throws {
        await wait()
        try sync {
            guard var p = profilesById[me] else { return }
            if let username = patch.username,
               profilesById.values.contains(where: { $0.id != me && $0.username == username }) {
                throw AppError("That username is taken.")
            }
            if let v = patch.name { p.name = v }
            if let v = patch.username { p.username = v }
            if let v = patch.bio { p.bio = v }
            if let v = patch.isPublic { p.isPublic = v }
            if let v = patch.color { p.color = v }
            if let v = patch.homeCountry { p.homeCountry = v }
            if let v = patch.homeCity { p.homeCity = v }
            if let goal = patch.yearlyGoal { p.yearlyGoal = goal }
            profilesById[me] = p
        }
    }

    func uploadAvatar(_ jpeg: Data) async throws -> String {
        await wait()
        let path = "demo-avatar-\(UUID().uuidString).jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(path)
        try jpeg.write(to: url)
        sync { profilesById[me]?.avatarUrl = url.absoluteString }
        return url.absoluteString
    }

    func searchProfiles(_ query: String) async throws -> [Profile] {
        await wait()
        let q = query.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "@" })
        guard q.count >= 2 else { return [] }
        return sync {
            profilesById.values.filter {
                $0.id != me && $0.isPublic == true && !blocked.contains($0.id)
                    && ($0.name.localizedCaseInsensitiveContains(q)
                        || ($0.username ?? "").localizedCaseInsensitiveContains(q))
            }
            .sorted { $0.name < $1.name }
        }
    }

    // ── Memories ─────────────────────────────────────────────────────────────

    func memories(userId: UUID) async throws -> [Memory] {
        await wait()
        return sync {
            memoriesById.values.filter { $0.userId == userId && canSeeLocked($0) }
                .sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
        }
    }

    func memory(id: UUID) async throws -> Memory? {
        sync { memoriesById[id].flatMap { canSeeLocked($0) ? $0 : nil } }
    }

    func memories(ids: [UUID]) async throws -> [Memory] {
        sync { ids.compactMap { memoriesById[$0] }.filter { canSeeLocked($0) } }
    }

    func memories(countryCode: String, userIds: [UUID]) async throws -> [Memory] {
        await wait()
        let ids = Set(userIds)
        return sync {
            memoriesById.values
                .filter { $0.countryCode == countryCode && ids.contains($0.userId) && canSeeLocked($0) }
                .sorted { $0.date > $1.date }
        }
    }

    func insertMemory(_ new: NewMemory) async throws -> Memory {
        await wait()
        let memory = Memory(id: UUID(), userId: me, countryCode: new.countryCode, title: new.title,
                            city: new.city, date: new.dateTried, notes: new.notes, photos: new.photos,
                            lat: new.lat, lng: new.lng,
                            visibility: Visibility(rawValue: new.visibility) ?? .friends, createdAt: Date())
        sync {
            memoriesById[memory.id] = memory
            stampFromMemoryLocked(memory)
        }
        return memory
    }

    func updateMemory(id: UUID, _ patch: MemoryPatch) async throws -> Memory {
        await wait()
        return try sync {
            guard var memory = memoriesById[id], memory.userId == me else {
                throw AppError("That memory is gone.")
            }
            let oldCode = memory.countryCode
            memory.countryCode = patch.countryCode
            memory.title = patch.title
            memory.city = patch.city
            memory.date = patch.dateTried
            memory.notes = patch.notes
            memory.photos = patch.photos
            memory.lat = patch.lat
            memory.lng = patch.lng
            memory.visibility = Visibility(rawValue: patch.visibility) ?? .friends
            memoriesById[id] = memory
            if oldCode != memory.countryCode {
                dropMemoryOnlyStampLocked(user: me, code: oldCode, except: id)
            }
            stampFromMemoryLocked(memory)
            return memory
        }
    }

    func deleteMemory(_ memory: Memory) async throws {
        await wait()
        sync {
            memoriesById[memory.id] = nil
            dropMemoryOnlyStampLocked(user: memory.userId, code: memory.countryCode, except: memory.id)
            reactions.removeAll { $0.entryId == memory.id }
            comments.removeAll { $0.entryId == memory.id }
        }
    }

    func uploadPhoto(_ jpeg: Data) async throws -> String {
        try? await Task.sleep(for: .milliseconds(250))
        let path = "\(me.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        sync { uploaded[path] = jpeg }
        return path
    }

    func removePhotos(_ paths: [String]) async {
        sync { for p in paths { uploaded[p] = nil } }
    }

    func photoData(path: String) async throws -> Data {
        if let data = sync({ uploaded[path] }) { return data }
        guard let data = DemoPhotos.jpeg(for: path) else { throw AppError("Photo unavailable.") }
        return data
    }

    // ── Stamps + bucket list ─────────────────────────────────────────────────

    func stamps(userIds: [UUID]) async throws -> [Stamp] {
        let ids = Set(userIds)
        return sync {
            stampsByKey.values.filter { ids.contains($0.userId) && canSeeProfileLocked($0.userId) }
        }
    }

    func stamps(countryCode: String, userIds: [UUID]) async throws -> [Stamp] {
        let ids = Set(userIds)
        return sync {
            stampsByKey.values.filter {
                $0.countryCode == countryCode && ids.contains($0.userId) && canSeeProfileLocked($0.userId)
            }
        }
    }

    func addStamps(_ items: [StampInput]) async throws {
        await wait()
        sync {
            for item in items {
                let key = "\(me)|\(item.countryCode)"
                if var existing = stampsByKey[key] {
                    if let f = item.firstVisited { existing.firstVisited = min(existing.firstVisited ?? f, f) }
                    if let l = item.lastVisited { existing.lastVisited = max(existing.lastVisited ?? l, l) }
                    if existing.source == .memory { existing.source = item.source }
                    stampsByKey[key] = existing
                } else {
                    stampsByKey[key] = Stamp(userId: me, countryCode: item.countryCode,
                                             firstVisited: item.firstVisited, lastVisited: item.lastVisited,
                                             source: item.source, createdAt: Date())
                }
            }
        }
    }

    func removeStamp(countryCode: String) async throws {
        await wait()
        sync { stampsByKey["\(me)|\(countryCode)"] = nil }
    }

    func bucketList() async throws -> Set<String> { sync { bucket } }

    func setBucketListed(_ code: String, _ on: Bool) async throws {
        sync { if on { bucket.insert(code) } else { bucket.remove(code) } }
    }

    // ── Social graph ─────────────────────────────────────────────────────────

    func followingIds(of userId: UUID) async throws -> [UUID] {
        sync { follows.filter { $0[0] == userId }.map { $0[1] } }
    }

    func followerIds(of userId: UUID) async throws -> [UUID] {
        sync { follows.filter { $0[1] == userId }.map { $0[0] } }
    }

    func followCounts(userId: UUID) async throws -> (followers: Int, following: Int) {
        sync { (follows.filter { $0[1] == userId }.count, follows.filter { $0[0] == userId }.count) }
    }

    func setFollowing(_ userId: UUID, _ follow: Bool) async throws {
        await wait()
        sync { if follow { follows.insert([me, userId]) } else { follows.remove([me, userId]) } }
    }

    func blockedIds() async throws -> Set<UUID> { sync { blocked } }

    func setBlocked(_ userId: UUID, _ isBlocked: Bool) async throws {
        sync {
            if isBlocked {
                blocked.insert(userId)
                follows.remove([me, userId])
            } else {
                blocked.remove(userId)
            }
        }
    }

    func report(contentType: String, contentId: UUID, reason: String) async throws { await wait() }

    // ── Feeds ────────────────────────────────────────────────────────────────

    func friendsFeed(before: Date?, limit: Int) async throws -> [Memory] {
        await wait()
        return sync {
            let following = Set(follows.filter { $0[0] == me }.map { $0[1] })
            return memoriesById.values
                .filter { m in
                    m.userId != me && !blocked.contains(m.userId)
                        && (following.contains(m.userId) || sharesGroupLocked(m.userId, me))
                        && canSeeLocked(m)
                        && (before.map { m.createdAt < $0 } ?? true)
                }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    func discoverFeed(before: Date?, limit: Int) async throws -> [Memory] {
        await wait()
        return sync {
            memoriesById.values
                .filter { m in m.visibility == .public && m.userId != me && (before.map { m.createdAt < $0 } ?? true) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    func recentStamps(userIds: [UUID], limit: Int) async throws -> [Stamp] {
        let ids = Set(userIds)
        return sync {
            stampsByKey.values
                .filter { ids.contains($0.userId) && canSeeProfileLocked($0.userId) && !blocked.contains($0.userId) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    func activity(limit: Int) async throws -> [ActivityRow] {
        await wait()
        return sync {
            var rows: [ActivityRow] = []
            for f in follows where f[1] == me {
                rows.append(ActivityRow(kind: .follow, actorId: f[0], entryId: nil, emoji: nil, body: nil,
                                        createdAt: DemoData.followDates[f[0]] ?? Date().addingTimeInterval(-86400 * 20)))
            }
            let mine = Set(memoriesById.values.filter { $0.userId == me }.map(\.id))
            for r in reactions where mine.contains(r.entryId) && r.userId != me {
                rows.append(ActivityRow(kind: .reaction, actorId: r.userId, entryId: r.entryId, emoji: r.emoji,
                                        body: nil, createdAt: r.createdAt ?? Date()))
            }
            for c in comments where mine.contains(c.entryId) && c.authorId != me {
                rows.append(ActivityRow(kind: .comment, actorId: c.authorId, entryId: c.entryId, emoji: nil,
                                        body: c.text, createdAt: c.createdAt))
            }
            return rows.filter { !blocked.contains($0.actorId) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    // ── Reactions + comments ─────────────────────────────────────────────────

    func reactions(memoryIds: [UUID]) async throws -> [Reaction] {
        let ids = Set(memoryIds)
        return sync { reactions.filter { ids.contains($0.entryId) } }
    }

    func setReaction(memoryId: UUID, emoji: String, on: Bool) async throws {
        sync {
            reactions.removeAll { $0.entryId == memoryId && $0.userId == me && $0.emoji == emoji }
            if on { reactions.append(Reaction(entryId: memoryId, userId: me, emoji: emoji, createdAt: Date())) }
        }
    }

    func comments(memoryId: UUID) async throws -> [Comment] {
        await wait()
        return sync { comments.filter { $0.entryId == memoryId }.sorted { $0.createdAt < $1.createdAt } }
    }

    func commentCounts(memoryIds: [UUID]) async throws -> [UUID: Int] {
        let ids = Set(memoryIds)
        return sync {
            Dictionary(grouping: comments.filter { ids.contains($0.entryId) }, by: \.entryId).mapValues(\.count)
        }
    }

    func addComment(memoryId: UUID, text: String) async throws {
        await wait()
        sync { comments.append(Comment(id: UUID(), entryId: memoryId, authorId: me, text: text, createdAt: Date())) }
    }

    func deleteComment(id: UUID) async throws {
        sync { comments.removeAll { $0.id == id } }
    }

    // ── Groups ───────────────────────────────────────────────────────────────

    func myGroups() async throws -> [Group] {
        await wait()
        return sync {
            let mine = Set(members.filter { $0.userId == me }.map(\.groupId))
            return groups.filter { mine.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func groupMembers(groupIds: [UUID]) async throws -> [GroupMember] {
        let ids = Set(groupIds)
        return sync { members.filter { ids.contains($0.groupId) } }
    }

    func createGroup(name: String) async throws -> Group {
        await wait()
        let group = Group(id: UUID(), name: name, coverPhoto: nil,
                          inviteCode: String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12)),
                          createdBy: me, createdAt: Date())
        sync {
            groups.append(group)
            members.append(GroupMember(groupId: group.id, userId: me, role: .owner, joinedAt: Date()))
        }
        return group
    }

    func joinGroup(inviteCode: String) async throws -> UUID {
        await wait()
        let code = inviteCode.trimmingCharacters(in: .whitespaces).lowercased()
        return try sync {
            guard let group = groups.first(where: { $0.inviteCode == code }) else {
                throw AppError("That code didn't match a group. Check it with whoever sent it.")
            }
            if !members.contains(where: { $0.groupId == group.id && $0.userId == me }) {
                members.append(GroupMember(groupId: group.id, userId: me, role: .member, joinedAt: Date()))
            }
            return group.id
        }
    }

    func updateGroup(id: UUID, _ patch: GroupPatch) async throws {
        await wait()
        try sync {
            guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
            if let code = patch.inviteCode {
                guard code.range(of: "^[a-z0-9]{6,32}$", options: .regularExpression) != nil else {
                    throw AppError("Invite codes are 6–32 letters and numbers.")
                }
                guard !groups.contains(where: { $0.inviteCode == code && $0.id != id }) else {
                    throw AppError("That code is taken — try another.")
                }
                groups[index].inviteCode = code
            }
            if let name = patch.name { groups[index].name = name }
            if let cover = patch.coverPhoto { groups[index].coverPhoto = cover }
        }
    }

    func uploadGroupCover(groupId: UUID, _ jpeg: Data) async throws -> String {
        await wait()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-cover-\(UUID().uuidString).jpg")
        try jpeg.write(to: url)
        return url.absoluteString
    }

    func groupCoverURL(_ path: String) -> URL? { URL(string: path) }

    func deleteGroup(id: UUID) async throws {
        await wait()
        sync {
            groups.removeAll { $0.id == id }
            members.removeAll { $0.groupId == id }
            posts.removeAll { $0.groupId == id }
        }
    }

    func leaveGroup(id: UUID) async throws {
        await wait()
        sync { members.removeAll { $0.groupId == id && $0.userId == me } }
    }

    // ── Group chat ───────────────────────────────────────────────────────────

    func posts(groupId: UUID, before: Date?, limit: Int) async throws -> [GroupPost] {
        await wait()
        return sync {
            posts.filter { p in p.groupId == groupId && (before.map { p.createdAt < $0 } ?? true) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    func createPost(groupId: UUID, text: String, memoryId: UUID?) async throws {
        sync {
            posts.append(GroupPost(id: UUID(), groupId: groupId, authorId: me, entryId: memoryId,
                                   text: text, photos: [], createdAt: Date()))
        }
    }

    func deletePost(id: UUID) async throws {
        sync { posts.removeAll { $0.id == id && $0.authorId == me } }
    }

    func postReactions(postIds: [UUID]) async throws -> [PostReaction] {
        let ids = Set(postIds)
        return sync { postReactions.filter { ids.contains($0.postId) } }
    }

    func setPostReaction(postId: UUID, emoji: String, on: Bool) async throws {
        sync {
            postReactions.removeAll { $0.postId == postId && $0.userId == me && $0.emoji == emoji }
            if on { postReactions.append(PostReaction(postId: postId, userId: me, emoji: emoji)) }
        }
    }

    func postComments(postIds: [UUID]) async throws -> [PostComment] {
        let ids = Set(postIds)
        return sync { postComments.filter { ids.contains($0.postId) }.sorted { $0.createdAt < $1.createdAt } }
    }

    func addPostComment(postId: UUID, text: String) async throws {
        sync {
            postComments.append(PostComment(id: UUID(), postId: postId, authorId: me, parentId: nil,
                                            text: text, createdAt: Date()))
        }
    }

    func deletePostComment(id: UUID) async throws {
        sync { postComments.removeAll { $0.id == id && $0.authorId == me } }
    }

    func chatChanges(groupId: UUID) -> AsyncStream<Void> {
        AsyncStream { _ in }
    }

    // ── Misc ─────────────────────────────────────────────────────────────────

    func logEvent(_ name: String, props: [String: String]?) {}
    func registerDeviceToken(_ token: String) async throws {}
}

// ── Postcards ───────────────────────────────────────────────────────────────

/// Stand-in travel photos: a painted sky, a sun, layered hills or waves and
/// the scene's emoji. Deterministic per name, rendered on demand.
enum DemoPhotos {
    private struct Scene {
        let top: UInt32
        let bottom: UInt32
        let ground: UInt32
        let emoji: String
        var water = false
        var night = false
    }

    private static let scenes: [String: Scene] = [
        "kyoto": Scene(top: 0xF6B38A, bottom: 0xE0566B, ground: 0x5B2A3A, emoji: "⛩️"),
        "tokyo": Scene(top: 0x241B4D, bottom: 0xC44B8A, ground: 0x160F2E, emoji: "🗼", night: true),
        "seoul": Scene(top: 0x9CC3E6, bottom: 0xF1C6A8, ground: 0x4B5B6E, emoji: "🏯"),
        "hongkong": Scene(top: 0x10233F, bottom: 0x2E7C8C, ground: 0x0A1626, emoji: "🌃", water: true, night: true),
        "halong": Scene(top: 0xBFE6E0, bottom: 0x5FB3A6, ground: 0x2C6E62, emoji: "⛰️", water: true),
        "bangkok": Scene(top: 0xFAD48B, bottom: 0xE8914A, ground: 0x7A3E1D, emoji: "🛕"),
        "singapore": Scene(top: 0x2B2A5E, bottom: 0x3FA7A3, ground: 0x13213A, emoji: "🌆", water: true, night: true),
        "lisbon": Scene(top: 0xA7D3F2, bottom: 0xF7E3A1, ground: 0xC4623A, emoji: "🚋"),
        "marrakech": Scene(top: 0xF3C58B, bottom: 0xD9744A, ground: 0x8A3B22, emoji: "🕌"),
        "machupicchu": Scene(top: 0xCFE3E8, bottom: 0x9DBF9E, ground: 0x3E6B45, emoji: "🏔️"),
        "santorini": Scene(top: 0x2E5AA8, bottom: 0xF29E6B, ground: 0xF4F0E8, emoji: "🌅", water: true),
        "iceland": Scene(top: 0xB9CBD6, bottom: 0x7FA0A8, ground: 0x3D5A4C, emoji: "🏞️"),
        "rome": Scene(top: 0xF5D9A8, bottom: 0xE0A35E, ground: 0x9C5B2E, emoji: "🏛️"),
        "milford": Scene(top: 0x9FC9D9, bottom: 0x5E8E86, ground: 0x2F4F46, emoji: "🛶", water: true),
        "sydney": Scene(top: 0x7FC4EA, bottom: 0xBFE3F2, ground: 0x2A6FA0, emoji: "⛵️", water: true),
        "bigsur": Scene(top: 0xF2B880, bottom: 0x7FA8C9, ground: 0x2F4B5E, emoji: "🌊", water: true),
        "lakelouise": Scene(top: 0xBFE0F0, bottom: 0x62B6C9, ground: 0x2D5E5A, emoji: "🛶", water: true),
        "barcelona": Scene(top: 0xF7D08A, bottom: 0xE58B5C, ground: 0x8F4A2E, emoji: "⛪️"),
        "borabora": Scene(top: 0x7FD3E8, bottom: 0x3DB7B0, ground: 0x1F7C73, emoji: "🏝️", water: true),
        "petra": Scene(top: 0xF2C9A0, bottom: 0xD08257, ground: 0x8C4A2F, emoji: "🏜️"),
        "edinburgh": Scene(top: 0x9AA9B8, bottom: 0xC7B9A5, ground: 0x4A4F57, emoji: "🏰"),
        "capetown": Scene(top: 0x8FC8EE, bottom: 0xF4D9A4, ground: 0x4F6B4A, emoji: "⛰️"),
        "hoian": Scene(top: 0x30204F, bottom: 0xE0833C, ground: 0x1E1430, emoji: "🏮", night: true),
        "agra": Scene(top: 0xF6D6B8, bottom: 0xE9A77F, ground: 0xB8B0A5, emoji: "🕌"),
        "hallstatt": Scene(top: 0xCBE0EC, bottom: 0x8FB7C4, ground: 0x3F5E58, emoji: "🏘️", water: true),
        "cappadocia": Scene(top: 0xF7C89B, bottom: 0xF09A7A, ground: 0x9E6A4B, emoji: "🎈"),
        "iguazu": Scene(top: 0xB8E0C8, bottom: 0x6FB59A, ground: 0x2F6A4F, emoji: "💦", water: true),
        "reykjavik": Scene(top: 0x112A3E, bottom: 0x2FA38A, ground: 0x0B1A26, emoji: "🌌", night: true),
    ]

    private static var cache: [String: Data] = [:]
    private static let cacheLock = NSLock()

    /// "demo/kyoto-2" → a postcard of Kyoto (variant 2).
    static func jpeg(for path: String) -> Data? {
        cacheLock.lock()
        if let hit = cache[path] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let base = path.split(separator: "/").last.map(String.init) ?? path
        let parts = base.split(separator: "-")
        let name = parts.first.map(String.init) ?? base
        let variant = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let scene = scenes[name] ?? Scene(top: 0xCFE3E8, bottom: 0xF1E3C8, ground: 0x6B7F6A, emoji: "📍")
        let data = render(scene, variant: variant)

        cacheLock.lock(); cache[path] = data; cacheLock.unlock()
        return data
    }

    private static func render(_ scene: Scene, variant: Int) -> Data? {
        let size = CGSize(width: 1080, height: 1350)
        let renderer = UIGraphicsImageRenderer(size: size, format: .pixels)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(rgb: scene.top).cgColor, UIColor(rgb: scene.bottom).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.75), options: [.drawsAfterEndLocation])
            }

            // Sun or moon
            let sunX = size.width * (variant % 2 == 0 ? 0.28 : 0.7)
            let sunY = size.height * 0.3
            let sun = UIColor.white.withAlphaComponent(scene.night ? 0.85 : 0.55)
            sun.setFill()
            cg.fillEllipse(in: CGRect(x: sunX - 90, y: sunY - 90, width: 180, height: 180))
            UIColor.white.withAlphaComponent(0.12).setFill()
            cg.fillEllipse(in: CGRect(x: sunX - 170, y: sunY - 170, width: 340, height: 340))
            if scene.night {
                UIColor.white.withAlphaComponent(0.7).setFill()
                for i in 0..<40 {
                    let x = CGFloat((i * 97 + variant * 31) % Int(size.width))
                    let y = CGFloat((i * 53 + variant * 17) % Int(size.height * 0.5))
                    cg.fillEllipse(in: CGRect(x: x, y: y, width: 4, height: 4))
                }
            }

            // Far hills, near ground
            func hills(_ baseY: CGFloat, amplitude: CGFloat, color: UIColor, phase: CGFloat) {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: baseY))
                var x: CGFloat = 0
                while x <= size.width {
                    let y = baseY - amplitude * sin((x / size.width) * .pi * 2.2 + phase)
                        - amplitude * 0.4 * sin((x / size.width) * .pi * 5.1 + phase * 2)
                    path.addLine(to: CGPoint(x: x, y: y))
                    x += 12
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.close()
                color.setFill()
                path.fill()
            }
            let ground = UIColor(rgb: scene.ground)
            hills(size.height * 0.62, amplitude: 70, color: ground.withAlphaComponent(0.45), phase: CGFloat(variant))
            hills(size.height * 0.72, amplitude: scene.water ? 18 : 55, color: ground.withAlphaComponent(0.8), phase: CGFloat(variant) + 1.3)
            if scene.water {
                UIColor.white.withAlphaComponent(0.25).setStroke()
                for i in 0..<6 {
                    let y = size.height * (0.8 + CGFloat(i) * 0.03)
                    let line = UIBezierPath()
                    line.move(to: CGPoint(x: size.width * 0.15 + CGFloat(i * 40), y: y))
                    line.addLine(to: CGPoint(x: size.width * 0.55 + CGFloat(i * 30), y: y))
                    line.lineWidth = 5
                    line.stroke()
                }
            }

            // The landmark
            let emoji = scene.emoji as NSString
            let font = UIFont.systemFont(ofSize: 330)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let textSize = emoji.size(withAttributes: attrs)
            let offset = CGFloat((variant - 1) * 90)
            emoji.draw(at: CGPoint(x: (size.width - textSize.width) / 2 + offset,
                                   y: size.height * 0.52 - textSize.height / 2), withAttributes: attrs)
        }
        return image.jpegData(compressionQuality: 0.82)
    }
}
