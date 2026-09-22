import Foundation
import UIKit

/// In-memory backend with a believable cast of eaters, for `-uiPreview`, screenshots
/// and tests. Mirrors the server's visibility rules closely enough that
/// screens behave the way they will against Supabase. Nothing leaves the device.
final class DemoBackend: Backend {
    static let meId = UUID(uuidString: "0D3E0000-0000-4000-8000-000000000001")!

    private let lock = NSLock()
    private var profilesById: [UUID: Profile] = [:]
    private var mealsById: [UUID: Meal] = [:]
    private var tastesByKey: [String: Taste] = [:]
    private var follows: Set<[UUID]> = []            // [follower, followee]
    private var blocked: Set<UUID> = []
    private var reactions: [Reaction] = []
    private var comments: [Comment] = []
    private var groups: [Group] = []
    private var members: [GroupMember] = []
    private var posts: [GroupPost] = []
    private var postReactions: [PostReaction] = []
    private var postComments: [PostComment] = []
    private var places: [SavedPlace] = []
    private var uploaded: [String: Data] = [:]
    /// Simulated round trip, so loading states are exercised.
    var latency: Duration = .milliseconds(120)

    /// Tests: make the next meal write fail before it lands, or land and
    /// then lose its response (a timeout on bad Wi-Fi).
    enum WriteFault { case beforeWrite, responseLost }
    var nextWriteFault: WriteFault?

    private func takeFault() -> WriteFault? {
        sync {
            defer { nextWriteFault = nil }
            return nextWriteFault
        }
    }

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
    func seedMeal(_ m: Meal) {
        sync {
            mealsById[m.id] = m
            tasteFromMealLocked(m)
        }
    }
    func seedTaste(_ t: Taste) {
        sync {
            let key = "\(t.userId)|\(t.countryCode)"
            if tastesByKey[key] == nil { tastesByKey[key] = t }
            refitTasteLocked(user: t.userId, code: t.countryCode)
        }
    }
    func seedFollow(_ follower: UUID, _ followee: UUID) { sync { _ = follows.insert([follower, followee]) } }
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
    func seedSavedPlace(_ place: SavedPlace) { sync { places.append(place) } }
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

    private func canSeeLocked(_ m: Meal) -> Bool {
        m.userId == me || m.visibility == .public || (m.visibility == .friends && isFriendLocked(m.userId, me))
    }

    private func canSeeProfileLocked(_ id: UUID) -> Bool {
        id == me || profilesById[id]?.isPublic == true || isFriendLocked(id, me)
    }

    // Tastes mirror tastes + sync_taste_from_meal: a meal tastes its
    // cuisine; its last meal going takes a meal-only taste with it.
    private func tasteFromMealLocked(_ m: Meal) {
        guard m.isMeal else { return }
        let key = "\(m.userId)|\(m.countryCode)"
        if tastesByKey[key] == nil {
            tastesByKey[key] = Taste(userId: m.userId, countryCode: m.countryCode, firstTasted: nil,
                                     lastTasted: nil, meals: 0, source: .meal, createdAt: m.createdAt)
        }
        refitTasteLocked(user: m.userId, code: m.countryCode)
    }

    private func dropMealOnlyTasteLocked(user: UUID, code: String, except id: UUID) {
        let key = "\(user)|\(code)"
        let others = mealsById.values.contains {
            $0.isMeal && $0.userId == user && $0.countryCode == code && $0.id != id
        }
        if !others, tastesByKey[key]?.source == .meal { tastesByKey[key] = nil }
        refitTasteLocked(user: user, code: code)
    }

    private func refitTasteLocked(user: UUID, code: String) {
        let key = "\(user)|\(code)"
        guard var taste = tastesByKey[key] else { return }
        let days = mealsById.values
            .filter { $0.isMeal && $0.userId == user && $0.countryCode == code }
            .map { String($0.date.prefix(10)) }
        taste.firstTasted = days.min()
        taste.lastTasted = days.max()
        taste.meals = days.count
        tastesByKey[key] = taste
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

    // ── Meals ────────────────────────────────────────────────────────────────

    func meals(userId: UUID) async throws -> [Meal] {
        await wait()
        return sync {
            mealsById.values.filter { $0.isMeal && $0.userId == userId && canSeeLocked($0) }
                .sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
        }
    }

    func meal(id: UUID) async throws -> Meal? {
        sync { mealsById[id].flatMap { $0.isMeal && canSeeLocked($0) ? $0 : nil } }
    }

    func meals(ids: [UUID]) async throws -> [Meal] {
        sync { ids.compactMap { mealsById[$0] }.filter { $0.isMeal && canSeeLocked($0) } }
    }

    func meals(countryCode: String, userIds: [UUID]) async throws -> [Meal] {
        await wait()
        let ids = Set(userIds)
        return sync {
            mealsById.values
                .filter { $0.isMeal && $0.countryCode == countryCode && ids.contains($0.userId) && canSeeLocked($0) }
                .sorted { $0.date > $1.date }
        }
    }

    func insertMeal(_ new: NewMeal) async throws -> Meal {
        await wait()
        let meal = Meal(id: new.id, userId: me, countryCode: new.countryCode, title: new.title,
                        city: new.city, date: new.dateTried, notes: new.notes, photos: new.photos,
                        lat: new.lat, lng: new.lng,
                        visibility: Visibility(rawValue: new.visibility) ?? .friends, createdAt: Date(),
                        kind: Meal.Kind(rawValue: new.kind) ?? .meal,
                        restaurantName: new.restaurantName, dish: new.signatureDish)
        let fault = takeFault()
        if fault == .beforeWrite { throw URLError(.notConnectedToInternet) }
        try sync {
            guard mealsById[meal.id] == nil else {
                throw AppError("duplicate key value violates unique constraint \"entries_pkey\"")
            }
            mealsById[meal.id] = meal
            tasteFromMealLocked(meal)
        }
        if fault == .responseLost { throw URLError(.timedOut) }
        return meal
    }

    func updateMeal(id: UUID, _ patch: MealPatch) async throws -> Meal {
        await wait()
        let fault = takeFault()
        if fault == .beforeWrite { throw URLError(.notConnectedToInternet) }
        let updated: Meal = try sync {
            guard var meal = mealsById[id], meal.userId == me else {
                throw AppError("That meal is gone.")
            }
            let oldCode = meal.countryCode
            meal.countryCode = patch.countryCode
            meal.title = patch.title
            meal.city = patch.city
            meal.date = patch.dateTried
            meal.notes = patch.notes
            meal.photos = patch.photos
            meal.lat = patch.lat
            meal.lng = patch.lng
            meal.visibility = Visibility(rawValue: patch.visibility) ?? .friends
            meal.restaurantName = patch.restaurantName
            meal.dish = patch.signatureDish
            mealsById[id] = meal
            if oldCode != meal.countryCode { dropMealOnlyTasteLocked(user: me, code: oldCode, except: id) }
            tasteFromMealLocked(meal)
            return meal
        }
        if fault == .responseLost { throw URLError(.timedOut) }
        return updated
    }

    func deleteMeal(_ meal: Meal) async throws {
        await wait()
        sync {
            mealsById[meal.id] = nil
            dropMealOnlyTasteLocked(user: meal.userId, code: meal.countryCode, except: meal.id)
            reactions.removeAll { $0.entryId == meal.id }
            comments.removeAll { $0.entryId == meal.id }
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

    // ── Tastes ───────────────────────────────────────────────────────────────

    func tastes(userIds: [UUID]) async throws -> [Taste] {
        let ids = Set(userIds)
        return sync {
            tastesByKey.values.filter { ids.contains($0.userId) && canSeeProfileLocked($0.userId) }
        }
    }

    func addTastes(_ codes: [String]) async throws {
        await wait()
        sync {
            for code in codes.map({ $0.uppercased() }) where tastesByKey["\(me)|\(code)"] == nil {
                tastesByKey["\(me)|\(code)"] = Taste(userId: me, countryCode: code, firstTasted: nil,
                                                      lastTasted: nil, meals: 0, source: .manual,
                                                      createdAt: Date())
                refitTasteLocked(user: me, code: code)
            }
        }
    }

    func removeTaste(countryCode: String) async throws {
        await wait()
        sync { tastesByKey["\(me)|\(countryCode)"] = nil }
    }

    // ── Restaurants to try ───────────────────────────────────────────────────

    func savedPlaces() async throws -> [SavedPlace] {
        sync { places.filter { $0.userId == me && $0.isRestaurant }.sorted { $0.createdAt > $1.createdAt } }
    }

    func savePlace(_ place: NewSavedPlace) async throws -> SavedPlace {
        await wait()
        let made = SavedPlace(id: place.id, userId: me, countryCode: place.countryCode,
                              title: place.title, city: place.city, lat: place.lat, lng: place.lng,
                              note: place.note, sourceEntryId: place.sourceEntryId, done: false,
                              createdAt: Date(), cuisineCode: place.cuisineCode)
        sync { places.append(made) }
        return made
    }

    func updateSavedPlace(id: UUID, _ patch: SavedPlacePatch) async throws -> SavedPlace {
        await wait()
        return try sync {
            guard let index = places.firstIndex(where: { $0.id == id && $0.userId == me }) else {
                throw AppError("That restaurant is gone.")
            }
            places[index].title = patch.title
            places[index].city = patch.city
            places[index].note = patch.note
            places[index].done = patch.done
            return places[index]
        }
    }

    func deleteSavedPlace(id: UUID) async throws {
        await wait()
        sync { places.removeAll { $0.id == id && $0.userId == me } }
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

    func friendsFeed(before: Date?, limit: Int) async throws -> [Meal] {
        await wait()
        return sync {
            let following = Set(follows.filter { $0[0] == me }.map { $0[1] })
            return mealsById.values
                .filter { m in
                    m.isMeal && m.userId != me && !blocked.contains(m.userId)
                        && (following.contains(m.userId) || sharesGroupLocked(m.userId, me))
                        && canSeeLocked(m)
                        && (before.map { m.createdAt < $0 } ?? true)
                }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    func discoverFeed(before: Date?, limit: Int) async throws -> [Meal] {
        await wait()
        return sync {
            mealsById.values
                .filter { m in
                    m.isMeal && m.visibility == .public && m.userId != me && (before.map { m.createdAt < $0 } ?? true)
                }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    func recentTastes(userIds: [UUID], limit: Int) async throws -> [Taste] {
        let ids = Set(userIds)
        return sync {
            tastesByKey.values
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
            let mine = Set(mealsById.values.filter { $0.userId == me }.map(\.id))
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

    func reactions(mealIds: [UUID]) async throws -> [Reaction] {
        let ids = Set(mealIds)
        return sync { reactions.filter { ids.contains($0.entryId) } }
    }

    func setReaction(mealId: UUID, emoji: String, on: Bool) async throws {
        sync {
            reactions.removeAll { $0.entryId == mealId && $0.userId == me && $0.emoji == emoji }
            if on { reactions.append(Reaction(entryId: mealId, userId: me, emoji: emoji, createdAt: Date())) }
        }
    }

    func comments(mealId: UUID) async throws -> [Comment] {
        await wait()
        return sync { comments.filter { $0.entryId == mealId }.sorted { $0.createdAt < $1.createdAt } }
    }

    func commentCounts(mealIds: [UUID]) async throws -> [UUID: Int] {
        let ids = Set(mealIds)
        return sync {
            Dictionary(grouping: comments.filter { ids.contains($0.entryId) }, by: \.entryId).mapValues(\.count)
        }
    }

    func addComment(mealId: UUID, text: String) async throws {
        await wait()
        sync { comments.append(Comment(id: UUID(), entryId: mealId, authorId: me, text: text, createdAt: Date())) }
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

    // ── Table chat ───────────────────────────────────────────────────────────

    func posts(groupId: UUID, before: Date?, limit: Int) async throws -> [GroupPost] {
        await wait()
        return sync {
            posts.filter { p in p.groupId == groupId && (before.map { p.createdAt < $0 } ?? true) }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit).map { $0 }
        }
    }

    func createPost(groupId: UUID, text: String, mealId: UUID?, pick: DinnerPick?) async throws {
        let body = text.trimmed.isEmpty ? (pick?.fallbackText ?? "") : text
        sync {
            posts.append(GroupPost(id: UUID(), groupId: groupId, authorId: me, entryId: mealId,
                                   text: body, photos: [], createdAt: Date(), pick: pick))
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

/// Stand-in meal photos: a dish on a plate on a table, from above, with the
/// dish's emoji. Deterministic per name, rendered on demand.
enum DemoPhotos {
    private struct Scene {
        let top: UInt32
        let bottom: UInt32
        let ground: UInt32
        let emoji: String
        var water = false
        var night = false
        /// A dish on a table rather than a view.
        var plate = false
    }

    private static let scenes: [String: Scene] = [
        // Meals
        "khachapuri": Scene(top: 0xF4DDB5, bottom: 0xD9A56B, ground: 0x6E3E22, emoji: "🧀", plate: true),
        "injera": Scene(top: 0xF0D6B0, bottom: 0xB9764A, ground: 0x5A3421, emoji: "🍛", plate: true),
        "ramen": Scene(top: 0x3B2A26, bottom: 0x8A5A3C, ground: 0x1E1512, emoji: "🍜", plate: true),
        "tacos": Scene(top: 0xF7E1A0, bottom: 0xE39A55, ground: 0x7A3B1E, emoji: "🌮", plate: true),
        "pho": Scene(top: 0xE9EFE2, bottom: 0xA9BF9A, ground: 0x49613F, emoji: "🍲", plate: true),
        "ceviche": Scene(top: 0xE4F3F1, bottom: 0x8FCBC0, ground: 0x2E6E66, emoji: "🐟", plate: true),
        "bibimbap": Scene(top: 0x2B2B2B, bottom: 0x6B4A3A, ground: 0x151515, emoji: "🥘", plate: true),
        "dosa": Scene(top: 0xF6E7C6, bottom: 0xD9A441, ground: 0x7A4E18, emoji: "🫓", plate: true),
        "pasta": Scene(top: 0xF5E9DA, bottom: 0xD08A5C, ground: 0x6B3A26, emoji: "🍝", plate: true),
        "khaosoi": Scene(top: 0xF7DFA8, bottom: 0xE0913C, ground: 0x6E3A15, emoji: "🍜", plate: true),
        "teasalad": Scene(top: 0xE6EFD2, bottom: 0x9BB36B, ground: 0x4A5A2A, emoji: "🥗", plate: true),
        "mantu": Scene(top: 0xF3E6D6, bottom: 0xC99A77, ground: 0x6B4A33, emoji: "🥟", plate: true),
        "plov": Scene(top: 0xF5E2BC, bottom: 0xD7964D, ground: 0x7A4A1C, emoji: "🍚", plate: true),
        "arepa": Scene(top: 0xF8ECCB, bottom: 0xE3B25E, ground: 0x7C5220, emoji: "🫓", plate: true),
        "churrasco": Scene(top: 0x3A2320, bottom: 0x9A4A32, ground: 0x1E1210, emoji: "🥩", plate: true),
        "dumplings": Scene(top: 0xF2EBDD, bottom: 0xC9B08A, ground: 0x5E4A30, emoji: "🥟", plate: true),
        "kebab": Scene(top: 0xF3D9B3, bottom: 0xC8703F, ground: 0x6A2E17, emoji: "🥙", plate: true),
        "suya": Scene(top: 0x3A2419, bottom: 0xB0552E, ground: 0x1F130D, emoji: "🍢", plate: true),
        "thieb": Scene(top: 0xF5DFB8, bottom: 0xD4643A, ground: 0x6E2A16, emoji: "🐟", plate: true),
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

            if scene.plate {
                // A table from above: the plate, its rim, the dish.
                let centre = CGPoint(x: size.width / 2 + CGFloat((variant - 1) * 40), y: size.height * 0.5)
                UIColor.black.withAlphaComponent(0.18).setFill()
                cg.fillEllipse(in: CGRect(x: centre.x - 410, y: centre.y - 380, width: 820, height: 820))
                UIColor(white: 0.97, alpha: 1).setFill()
                cg.fillEllipse(in: CGRect(x: centre.x - 400, y: centre.y - 400, width: 800, height: 800))
                UIColor(rgb: scene.ground).withAlphaComponent(0.12).setFill()
                cg.fillEllipse(in: CGRect(x: centre.x - 300, y: centre.y - 300, width: 600, height: 600))
                let dish = scene.emoji as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 380)]
                let dishSize = dish.size(withAttributes: attrs)
                dish.draw(at: CGPoint(x: centre.x - dishSize.width / 2, y: centre.y - dishSize.height / 2),
                          withAttributes: attrs)
                return
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
