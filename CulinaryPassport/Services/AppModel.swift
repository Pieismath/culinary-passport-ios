import SwiftUI
import Supabase

/// The signed-in traveller's world, shared by every tab.
///
/// One source of truth fixes the old cross-tab staleness (log on the globe,
/// and the journal/profile kept showing yesterday until relaunch). Mutations
/// update local state immediately and reconcile with the server; the last
/// known state is cached per account so cold launches render instantly.
@MainActor
@Observable
final class AppModel {
    enum SessionState: Equatable {
        case unknown
        case signedOut
        case signedIn(UUID)
    }

    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    enum Route: Identifiable, Equatable {
        case memory(UUID)
        case joinGroup(String)
        case profile(UUID)

        var id: String {
            switch self {
            case .memory(let id): "memory-\(id)"
            case .joinGroup(let code): "join-\(code)"
            case .profile(let id): "profile-\(id)"
            }
        }
    }

    struct SaveResult {
        let memory: Memory
        /// First time this country is stamped → the stamp moment plays.
        let isNewCountry: Bool
        /// 1-based position among the passport's countries.
        let countryNumber: Int
    }

    private(set) var backend: any Backend
    private(set) var isDemo: Bool
    var session: SessionState = .unknown

    // ── The traveller ────────────────────────────────────────────────────────
    var me: Profile?
    var memories: [Memory] = [] { didSet { rebuildDerived() } }
    var stamps: [Stamp] = [] { didSet { rebuildDerived() } }
    var bucketList: Set<String> = []
    var following: Set<UUID> = []
    var followers: Set<UUID> = []
    var blocked: Set<UUID> = []
    var groups: [Group] = []
    var membersByGroup: [UUID: [GroupMember]] = [:]
    /// Profiles of everyone around you (friends, group mates, authors seen).
    var people: [UUID: Profile] = [:]

    var loadState: LoadState = .idle
    var toast: Toast?
    var route: Route?
    var needsOnboarding = false
    /// Bumped when the stamp book gains countries (drives celebrations).
    var lastStampBurst: [String] = []

    // ── Derived (rebuilt when memories/stamps change) ────────────────────────
    private(set) var visitedCodes: Set<String> = []
    private(set) var stampsByCode: [String: Stamp] = [:]
    private(set) var memoriesByCountry: [String: [Memory]] = [:]
    private(set) var stats = TravelStats()

    var myId: UUID? {
        if case .signedIn(let id) = session { return id }
        return nil
    }

    /// Mutual follows plus everyone you share a group with.
    var friendIds: Set<UUID> {
        following.intersection(followers).union(groupMateIds)
    }

    /// People whose travels you see: who you follow + your groups.
    var networkIds: Set<UUID> {
        following.union(groupMateIds).subtracting(blocked)
    }

    var groupMateIds: Set<UUID> {
        var ids = Set(membersByGroup.values.flatMap { $0.map(\.userId) })
        if let myId { ids.remove(myId) }
        return ids
    }

    init(demo: Bool) {
        isDemo = demo
        backend = demo ? DemoBackend() : SupabaseBackend.shared
    }

    // ── Session ──────────────────────────────────────────────────────────────

    func start() {
        Task { await ImagePipeline.shared.configure(backend: backend) }
        Task.detached(priority: .background) { await ImagePipeline.shared.trimDisk() }
        if isDemo {
            signInDemo()
        } else {
            Task { await observeAuth() }
        }
    }

    /// DEBUG: explore the whole app on fixtures, no account.
    func enterDemo() {
        isDemo = true
        backend = DemoBackend()
        Task { await ImagePipeline.shared.configure(backend: backend) }
        signInDemo()
    }

    private func signInDemo() {
        resetUserData()
        session = .signedIn(DemoBackend.meId)
        Task { await bootstrap() }
    }

    private func observeAuth() async {
        for await state in SupabaseBackend.shared.client.auth.authStateChanges {
            guard !isDemo else { return }
            if let user = state.session?.user {
                if myId != user.id {
                    resetUserData()
                    session = .signedIn(user.id)
                    Task { await bootstrap() }
                }
                if state.event == .signedIn { backend.logEvent("app_open", props: nil) }
                // An expired .initialSession (offline relaunch) still shows the
                // app; side effects wait for a valid session.
                if let session = state.session, !session.isExpired, state.event != .tokenRefreshed {
                    PushRegistrar.registerIfAuthorized()
                }
            } else {
                resetUserData()
                DiskCache.clear()
                session = .signedOut
            }
        }
    }

    func signOut() async {
        if isDemo {
            isDemo = false
            backend = SupabaseBackend.shared
            await ImagePipeline.shared.configure(backend: backend)
            resetUserData()
            session = .signedOut
            Task { await observeAuth() }
            return
        }
        await backend.signOut()
        await ImagePipeline.shared.clearAll()
        MemoryReminders.cancelAll()
    }

    func deleteAccount() async throws {
        try await backend.deleteAccount()
        await ImagePipeline.shared.clearAll()
        MemoryReminders.cancelAll()
        if isDemo { await signOut() }
    }

    private func resetUserData() {
        me = nil
        memories = []
        stamps = []
        bucketList = []
        following = []
        followers = []
        blocked = []
        groups = []
        membersByGroup = [:]
        people = [:]
        loadState = .idle
        needsOnboarding = false
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    func bootstrap() async {
        guard let myId else { return }
        restoreSnapshot(for: myId)
        loadState = (memories.isEmpty && stamps.isEmpty && me == nil) ? .loading : .loaded
        await refresh()
        guard self.myId == myId else { return }
        if !Onboarding.isDone(for: myId), stamps.isEmpty, memories.isEmpty, loadState == .loaded {
            needsOnboarding = true
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-onboarding") { needsOnboarding = true }
        #endif
        MemoryReminders.reschedule(memories: memories)
    }

    /// Reload everything about the traveller. Safe to call from pull-to-refresh.
    func refresh() async {
        guard let myId else { return }
        let backend = self.backend
        do {
            async let profile = backend.myProfile()
            async let memories = backend.memories(userId: myId)
            async let stamps = backend.stamps(userIds: [myId])
            async let bucket = backend.bucketList()
            async let following = backend.followingIds(of: myId)
            async let followers = backend.followerIds(of: myId)
            async let blocked = backend.blockedIds()
            async let groups = backend.myGroups()
            let (p, m, s, b, fing, fers, bl, g) = try await (profile, memories, stamps, bucket,
                                                            following, followers, blocked, groups)
            guard self.myId == myId else { return }
            guard let p else {
                // Profile row is gone (deleted account / stale session).
                await backend.signOut()
                return
            }
            me = p
            self.memories = m
            self.stamps = s
            bucketList = b
            self.following = Set(fing)
            self.followers = Set(fers)
            self.blocked = bl
            self.groups = g

            let members = try await backend.groupMembers(groupIds: g.map(\.id))
            membersByGroup = Dictionary(grouping: members, by: \.groupId)
            let around = Set(fing).union(fers).union(members.map(\.userId)).subtracting([myId])
            let profiles = try await backend.profiles(ids: Array(around))
            for profile in profiles { people[profile.id] = profile }

            loadState = .loaded
            saveSnapshot()
        } catch {
            guard !(error is CancellationError) else { return }
            if me == nil && memories.isEmpty && stamps.isEmpty {
                loadState = .failed(AppError.friendly(error))
            }
        }
    }

    func refreshStamps() async {
        guard let myId, let fresh = try? await backend.stamps(userIds: [myId]) else { return }
        stamps = fresh
        saveSnapshot()
    }

    /// Profiles for ids, from the cache when we have them.
    func profiles(for ids: [UUID]) async -> [UUID: Profile] {
        let missing = Set(ids).subtracting(people.keys)
        if !missing.isEmpty, let fetched = try? await backend.profiles(ids: Array(missing)) {
            for profile in fetched { people[profile.id] = profile }
        }
        if let me { people[me.id] = me }
        return people.filter { ids.contains($0.key) }
    }

    func profile(_ id: UUID) -> Profile? {
        id == me?.id ? me : people[id]
    }

    // ── Memories ─────────────────────────────────────────────────────────────

    /// Upload photos, then insert or update the memory, share it to groups,
    /// and fold the result into local state.
    func saveMemory(_ draft: MemoryDraft, editing original: Memory?, newPhotos: [Data],
                    shareTo groupIds: Set<UUID>) async throws -> SaveResult {
        guard let myId else { throw AppError("You're signed out.") }
        let wasVisited = visitedCodes.contains(draft.countryCode)

        var uploadedPaths: [String] = []
        do {
            for jpeg in newPhotos {
                let path = try await backend.uploadPhoto(jpeg)
                await ImagePipeline.shared.prime(.storage(path), data: jpeg)
                uploadedPaths.append(path)
            }
        } catch {
            await backend.removePhotos(uploadedPaths)
            throw error
        }
        let photos = draft.keptPhotos + uploadedPaths

        let saved: Memory
        do {
            if let original {
                saved = try await backend.updateMemory(id: original.id, draft.patch(photos: photos))
                let dropped = Set(original.photos).subtracting(photos)
                if !dropped.isEmpty { await backend.removePhotos(Array(dropped)) }
            } else {
                saved = try await backend.insertMemory(draft.newMemory(userId: myId, photos: photos))
            }
        } catch {
            // Don't strand what we just uploaded if the row never landed.
            await backend.removePhotos(uploadedPaths)
            throw error
        }

        memories.removeAll { $0.id == saved.id }
        memories.append(saved)
        memories.sort { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
        mergeLocalStamp(StampInput(countryCode: saved.countryCode, firstVisited: saved.date,
                                   lastVisited: saved.date, source: .memory))

        for groupId in groupIds {
            try? await backend.createPost(groupId: groupId, text: "", memoryId: saved.id)
        }
        backend.logEvent(original == nil ? "memory_added" : "memory_edited",
                         props: ["country": saved.countryCode, "photos": String(photos.count)])
        saveSnapshot()
        Task {
            await refreshStamps()
            MemoryReminders.reschedule(memories: memories)
        }

        let isNew = original == nil && !wasVisited
        let number = stats.countries + stats.territories
        if isNew { lastStampBurst = [saved.countryCode] }
        return SaveResult(memory: saved, isNewCountry: isNew, countryNumber: max(1, number))
    }

    func deleteMemory(_ memory: Memory) async throws {
        let before = memories
        memories.removeAll { $0.id == memory.id }
        do {
            try await backend.deleteMemory(memory)
            backend.logEvent("memory_deleted", props: nil)
            saveSnapshot()
            await refreshStamps()
            MemoryReminders.reschedule(memories: memories)
        } catch {
            memories = before
            throw error
        }
    }

    // ── Stamps ───────────────────────────────────────────────────────────────

    /// Stamp several countries at once (checklist, photo import).
    func addStamps(_ items: [StampInput]) async throws {
        guard !items.isEmpty else { return }
        let before = stamps
        let newCodes = items.map(\.countryCode).filter { !visitedCodes.contains($0) }
        for item in items { mergeLocalStamp(item) }
        do {
            try await backend.addStamps(items)
            backend.logEvent("stamps_added", props: ["count": String(items.count),
                                                     "source": items.first?.source.rawValue ?? ""])
            if !newCodes.isEmpty { lastStampBurst = newCodes }
            saveSnapshot()
            await refreshStamps()
        } catch {
            stamps = before
            throw error
        }
    }

    func removeStamp(_ code: String) async throws {
        let count = memoriesByCountry[code]?.count ?? 0
        guard count == 0 else {
            throw AppError("Delete your \(count) memor\(count == 1 ? "y" : "ies") from here first — they keep the stamp.")
        }
        let before = stamps
        stamps.removeAll { $0.countryCode == code }
        do {
            try await backend.removeStamp(countryCode: code)
            saveSnapshot()
        } catch {
            stamps = before
            throw error
        }
    }

    private func mergeLocalStamp(_ item: StampInput) {
        guard let myId else { return }
        if let index = stamps.firstIndex(where: { $0.countryCode == item.countryCode }) {
            var stamp = stamps[index]
            if let f = item.firstVisited { stamp.firstVisited = min(stamp.firstVisited ?? f, f) }
            if let l = item.lastVisited { stamp.lastVisited = max(stamp.lastVisited ?? l, l) }
            stamps[index] = stamp
        } else {
            stamps.append(Stamp(userId: myId, countryCode: item.countryCode, firstVisited: item.firstVisited,
                                lastVisited: item.lastVisited, source: item.source, createdAt: Date()))
        }
    }

    func toggleBucketList(_ code: String) {
        let on = !bucketList.contains(code)
        if on { bucketList.insert(code) } else { bucketList.remove(code) }
        Task {
            do {
                try await backend.setBucketListed(code, on)
                backend.logEvent("bucket_list_toggled", props: ["country": code, "on": String(on)])
                saveSnapshot()
            } catch {
                if on { bucketList.remove(code) } else { bucketList.insert(code) }
                show(error)
            }
        }
    }

    // ── People ───────────────────────────────────────────────────────────────

    func setFollowing(_ userId: UUID, _ follow: Bool) {
        if follow { following.insert(userId) } else { following.remove(userId) }
        Task {
            do {
                try await backend.setFollowing(userId, follow)
                backend.logEvent(follow ? "followed" : "unfollowed", props: nil)
                if follow, people[userId] == nil { _ = await profiles(for: [userId]) }
                saveSnapshot()
            } catch {
                if follow { following.remove(userId) } else { following.insert(userId) }
                show(error)
            }
        }
    }

    func block(_ userId: UUID) async {
        do {
            try await backend.setBlocked(userId, true)
            blocked.insert(userId)
            following.remove(userId)
            toast = Toast(message: "Blocked. They won't show up in your feeds.", style: .success)
        } catch {
            show(error)
        }
    }

    func unblock(_ userId: UUID) async {
        do {
            try await backend.setBlocked(userId, false)
            blocked.remove(userId)
        } catch {
            show(error)
        }
    }

    func report(_ contentType: String, id: UUID, reason: String) async {
        do {
            try await backend.report(contentType: contentType, contentId: id,
                                     reason: reason.isEmpty ? "inappropriate" : reason)
            toast = Toast(message: "Reported. Thanks — we'll take a look.", style: .success)
        } catch {
            show(error)
        }
    }

    // ── Profile ──────────────────────────────────────────────────────────────

    func updateProfile(_ patch: ProfilePatch) async throws {
        try await backend.updateProfile(patch)
        if let fresh = try? await backend.myProfile() { me = fresh }
        saveSnapshot()
    }

    func uploadAvatar(_ jpeg: Data) async throws {
        let url = try await backend.uploadAvatar(jpeg)
        if let parsed = URL(string: url) { await ImagePipeline.shared.prime(.url(parsed), data: jpeg) }
        me?.avatarUrl = url
        saveSnapshot()
    }

    // ── Groups ───────────────────────────────────────────────────────────────

    func refreshGroups() async {
        guard let fresh = try? await backend.myGroups() else { return }
        groups = fresh
        if let members = try? await backend.groupMembers(groupIds: fresh.map(\.id)) {
            membersByGroup = Dictionary(grouping: members, by: \.groupId)
            _ = await profiles(for: members.map(\.userId))
        }
        saveSnapshot()
    }

    @discardableResult
    func createGroup(name: String) async throws -> Group {
        let group = try await backend.createGroup(name: name)
        backend.logEvent("group_created", props: nil)
        await refreshGroups()
        return group
    }

    @discardableResult
    func joinGroup(code: String) async throws -> UUID {
        let id = try await backend.joinGroup(inviteCode: code)
        backend.logEvent("group_joined", props: nil)
        await refreshGroups()
        return id
    }

    func leaveGroup(_ id: UUID) async throws {
        try await backend.leaveGroup(id: id)
        groups.removeAll { $0.id == id }
        membersByGroup[id] = nil
        saveSnapshot()
    }

    func deleteGroup(_ id: UUID) async throws {
        try await backend.deleteGroup(id: id)
        groups.removeAll { $0.id == id }
        membersByGroup[id] = nil
        saveSnapshot()
    }

    func members(of groupId: UUID) -> [UUID] {
        (membersByGroup[groupId] ?? []).sorted { $0.joinedAt < $1.joinedAt }.map(\.userId)
    }

    // ── Activity ─────────────────────────────────────────────────────────────

    /// Follows, reactions and comments since you last opened Activity.
    var unseenActivity = 0

    var activityLastSeen: Date {
        guard let myId else { return .distantPast }
        return UserDefaults.standard.object(forKey: "activitySeen.\(myId.uuidString)") as? Date ?? .distantPast
    }

    func checkActivity() async {
        guard myId != nil, let rows = try? await backend.activity(limit: 50) else { return }
        let seen = activityLastSeen
        unseenActivity = rows.filter { $0.createdAt > seen && !blocked.contains($0.actorId) }.count
    }

    func markActivitySeen() {
        guard let myId else { return }
        UserDefaults.standard.set(Date(), forKey: "activitySeen.\(myId.uuidString)")
        unseenActivity = 0
    }

    // ── Feedback ─────────────────────────────────────────────────────────────

    func show(_ error: Error) {
        guard !(error is CancellationError) else { return }
        toast = Toast(message: AppError.friendly(error), style: .error)
    }

    func celebrate(_ message: String) {
        toast = Toast(message: message, style: .success)
    }

    // ── Deep links ───────────────────────────────────────────────────────────

    /// culinarypassport://join/<code> · culinarypassport://memory/<uuid>
    func handle(url: URL) {
        guard url.scheme == "culinarypassport" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "join":
            let code = parts.first
                ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
            if let code, !code.isEmpty { route = .joinGroup(code) }
        case "memory":
            if let raw = parts.first, let id = UUID(uuidString: raw) { route = .memory(id) }
        case "profile":
            if let raw = parts.first, let id = UUID(uuidString: raw) { route = .profile(id) }
        default:
            break
        }
    }

    // ── Cache ────────────────────────────────────────────────────────────────

    private struct Snapshot: Codable {
        var me: Profile?
        var memories: [Memory]
        var stamps: [Stamp]
        var bucketList: Set<String>
        var following: Set<UUID>
        var followers: Set<UUID>
        var groups: [Group]
        var members: [GroupMember]
        var people: [Profile]
    }

    private func saveSnapshot() {
        guard let myId, !isDemo else { return }
        let snapshot = Snapshot(me: me, memories: memories, stamps: stamps, bucketList: bucketList,
                                following: following, followers: followers, groups: groups,
                                members: membersByGroup.values.flatMap { $0 },
                                people: Array(people.values))
        DiskCache.save(snapshot, key: "passport-v2", user: myId)
    }

    private func restoreSnapshot(for user: UUID) {
        guard !isDemo, let snapshot = DiskCache.load("passport-v2", user: user, as: Snapshot.self) else { return }
        me = snapshot.me
        memories = snapshot.memories
        stamps = snapshot.stamps
        bucketList = snapshot.bucketList
        following = snapshot.following
        followers = snapshot.followers
        groups = snapshot.groups
        membersByGroup = Dictionary(grouping: snapshot.members, by: \.groupId)
        for person in snapshot.people { people[person.id] = person }
    }

    private func rebuildDerived() {
        visitedCodes = Set(stamps.map(\.countryCode))
        stampsByCode = Dictionary(stamps.map { ($0.countryCode, $0) }, uniquingKeysWith: { a, _ in a })
        memoriesByCountry = Dictionary(grouping: memories, by: \.countryCode)
        stats = TravelStats(stamps: stamps, memories: memories)
    }
}

/// The fields a person edits for one memory.
struct MemoryDraft: Equatable {
    var countryCode = ""
    var title = ""
    var city = ""
    var date = Date()
    var notes = ""
    var lat: Double?
    var lng: Double?
    var visibility: Visibility = .friends
    /// Photos already stored (editing) that are being kept, in order.
    var keptPhotos: [String] = []

    init() {}

    init(memory: Memory) {
        countryCode = memory.countryCode
        title = memory.title
        city = memory.city ?? ""
        date = memory.day ?? Date()
        notes = memory.notes ?? ""
        lat = memory.lat
        lng = memory.lng
        visibility = memory.visibility
        keptPhotos = memory.photos
    }

    func newMemory(userId: UUID, photos: [String]) -> NewMemory {
        NewMemory(userId: userId, countryCode: countryCode, title: title.trimmed, city: city.trimmed,
                  dateTried: DayFormat.string(from: date), notes: notes.trimmed, photos: photos,
                  lat: lat, lng: lng, visibility: visibility.rawValue)
    }

    func patch(photos: [String]) -> MemoryPatch {
        MemoryPatch(countryCode: countryCode, title: title.trimmed, city: city.trimmed,
                    dateTried: DayFormat.string(from: date), notes: notes.trimmed, photos: photos,
                    lat: lat, lng: lng, visibility: visibility.rawValue)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// First-run bookkeeping, per account (the old flag was per device, so a
/// second account on the same phone never got onboarding).
enum Onboarding {
    static func isDone(for user: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: "onboarded.\(user.uuidString)")
    }

    static func markDone(for user: UUID) {
        UserDefaults.standard.set(true, forKey: "onboarded.\(user.uuidString)")
    }
}
