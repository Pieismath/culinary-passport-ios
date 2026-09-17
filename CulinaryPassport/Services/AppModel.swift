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
        /// "Country Nº 21" — its place among sovereign countries, matching the
        /// headline count. Nil for territories (they don't change that count).
        let countryNumber: Int?
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
    /// Trips you're planning, and the places saved for them.
    var tripPlans: [TripPlan] = [] { didSet { rebuildDerived() } }
    var savedPlaces: [SavedPlace] = [] { didSet { rebuildDerived() } }
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
    private(set) var placesByCountry: [String: [SavedPlace]] = [:]
    /// Trips that haven't ended yet, soonest first (undated ones last).
    private(set) var upcomingTrips: [TripPlan] = []
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
        tripPlans = []
        savedPlaces = []
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
            async let trips = backend.tripPlans()
            async let places = backend.savedPlaces()
            let (p, m, s, b, fing, fers, bl, g) = try await (profile, memories, stamps, bucket,
                                                            following, followers, blocked, groups)
            let (plans, saved) = try await (trips, places)
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
            tripPlans = plans
            savedPlaces = saved
            // The traveller's own data is in: the app is usable from here even
            // if the group/people round trips below fail.
            loadState = .loaded
        } catch {
            guard !(error is CancellationError), self.myId == myId else { return }
            if me == nil && memories.isEmpty && stamps.isEmpty {
                loadState = .failed(AppError.friendly(error))
            }
            return
        }

        let groupIds = groups.map(\.id)
        let members = try? await backend.groupMembers(groupIds: groupIds)
        guard self.myId == myId else { return }
        if let members { membersByGroup = Dictionary(grouping: members, by: \.groupId) }
        let around = following.union(followers).union(groupMateIds)
        if let profiles = try? await backend.profiles(ids: Array(around)) {
            guard self.myId == myId else { return }
            for profile in profiles { people[profile.id] = profile }
        }
        saveSnapshot()
    }

    func refreshStamps() async {
        guard let myId, let fresh = try? await backend.stamps(userIds: [myId]), self.myId == myId else { return }
        stamps = fresh
        saveSnapshot()
    }

    /// Profiles for ids, from the cache when we have them.
    func profiles(for ids: [UUID]) async -> [UUID: Profile] {
        let owner = myId
        let missing = Set(ids).subtracting(people.keys)
        if !missing.isEmpty, let fetched = try? await backend.profiles(ids: Array(missing)), myId == owner {
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
    ///
    /// `newId` names a new memory before it exists; pass the same id when
    /// retrying, so a save whose response was lost can't land twice.
    func saveMemory(_ draft: MemoryDraft, editing original: Memory?, newId: UUID = UUID(),
                    newPhotos: [Data], shareTo groupIds: Set<UUID>) async throws -> SaveResult {
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
            } else {
                saved = try await backend.insertMemory(draft.newMemory(id: newId, userId: myId, photos: photos))
            }
        } catch let saveError {
            // A lost response can hide a write that landed: look before
            // deleting uploads that a saved memory may already point at.
            let row: Memory?
            do {
                row = try await backend.memory(id: original?.id ?? newId)
            } catch {
                // Still can't tell (offline). Keep the uploads; a retry reuses the id.
                throw saveError
            }
            let expected: MemoryPatch? = original == nil ? nil : draft.patch(photos: photos)
            guard let row, expected.map({ row.matches($0) }) ?? true else {
                await backend.removePhotos(uploadedPaths)
                throw saveError
            }
            // It landed — possibly from an earlier attempt with its own uploads.
            await backend.removePhotos(uploadedPaths.filter { !row.photos.contains($0) })
            saved = row
        }
        if let original {
            let dropped = Set(original.photos).subtracting(saved.photos)
            if !dropped.isEmpty { await backend.removePhotos(Array(dropped)) }
        }
        // Signed out (or into another account) while saving: the write stands,
        // but it must not land in someone else's state.
        guard self.myId == myId else { throw CancellationError() }

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
        let number = CountryStore.byCode[saved.countryCode]?.isSovereign == true ? max(1, stats.countries) : nil
        if isNew { lastStampBurst = [saved.countryCode] }
        return SaveResult(memory: saved, isNewCountry: isNew, countryNumber: number)
    }

    func deleteMemory(_ memory: Memory) async throws {
        let owner = myId
        let before = memories
        memories.removeAll { $0.id == memory.id }
        do {
            try await backend.deleteMemory(memory)
            backend.logEvent("memory_deleted", props: nil)
            guard myId == owner else { return }
            saveSnapshot()
            await refreshStamps()
            MemoryReminders.reschedule(memories: memories)
        } catch {
            if myId == owner { memories = before }
            throw error
        }
    }

    // ── Stamps ───────────────────────────────────────────────────────────────

    /// Stamp several countries at once (checklist, photo import).
    func addStamps(_ items: [StampInput]) async throws {
        guard !items.isEmpty else { return }
        let owner = myId
        let before = stamps
        let newCodes = items.map(\.countryCode).filter { !visitedCodes.contains($0) }
        for item in items { mergeLocalStamp(item) }
        do {
            try await backend.addStamps(items)
            backend.logEvent("stamps_added", props: ["count": String(items.count),
                                                     "source": items.first?.source.rawValue ?? ""])
            guard myId == owner else { return }
            if !newCodes.isEmpty { lastStampBurst = newCodes }
            saveSnapshot()
            await refreshStamps()
        } catch {
            if myId == owner { stamps = before }
            throw error
        }
    }

    func removeStamp(_ code: String) async throws {
        let count = memoriesByCountry[code]?.count ?? 0
        guard count == 0 else {
            throw AppError("Delete your \(count) memor\(count == 1 ? "y" : "ies") from here first — they keep the stamp.")
        }
        let owner = myId
        let before = stamps
        stamps.removeAll { $0.countryCode == code }
        do {
            try await backend.removeStamp(countryCode: code)
            if myId == owner { saveSnapshot() }
        } catch {
            if myId == owner { stamps = before }
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
        let owner = myId
        let on = !bucketList.contains(code)
        if on { bucketList.insert(code) } else { bucketList.remove(code) }
        Task {
            do {
                try await backend.setBucketListed(code, on)
                backend.logEvent("bucket_list_toggled", props: ["country": code, "on": String(on)])
                if myId == owner { saveSnapshot() }
            } catch {
                guard myId == owner else { return }
                if on { bucketList.remove(code) } else { bucketList.insert(code) }
                show(error)
            }
        }
    }

    // ── Trips + saved places ─────────────────────────────────────────────────

    @discardableResult
    func createTrip(name: String, countries: [String], startsOn: String?, endsOn: String?,
                    groupId: UUID?, notes: String = "") async throws -> TripPlan {
        guard let myId else { throw AppError("You're signed out.") }
        let plan = try await backend.createTripPlan(
            NewTripPlan(id: UUID(), userId: myId, name: name.trimmed, countryCodes: countries,
                        startsOn: startsOn, endsOn: endsOn, groupId: groupId, notes: notes.trimmed))
        guard self.myId == myId else { throw CancellationError() }
        tripPlans.append(plan)
        backend.logEvent("trip_planned", props: ["countries": String(countries.count)])
        saveSnapshot()
        return plan
    }

    func updateTrip(_ plan: TripPlan, name: String, countries: [String], startsOn: String?,
                    endsOn: String?, groupId: UUID?, notes: String) async throws {
        let owner = myId
        let fresh = try await backend.updateTripPlan(
            id: plan.id, TripPlanPatch(name: name.trimmed, countryCodes: countries, startsOn: startsOn,
                                       endsOn: endsOn, groupId: groupId, notes: notes.trimmed))
        guard myId == owner else { return }
        if let index = tripPlans.firstIndex(where: { $0.id == plan.id }) { tripPlans[index] = fresh }
        saveSnapshot()
    }

    func deleteTrip(_ plan: TripPlan) async throws {
        let owner = myId
        let before = tripPlans
        tripPlans.removeAll { $0.id == plan.id }
        do {
            try await backend.deleteTripPlan(id: plan.id)
            guard myId == owner else { return }
            // Its places stay on your list, just unattached (as on the server).
            for index in savedPlaces.indices where savedPlaces[index].tripId == plan.id {
                savedPlaces[index].tripId = nil
            }
            saveSnapshot()
        } catch {
            if myId == owner { tripPlans = before }
            throw error
        }
    }

    /// Save somewhere you want to go. `from` credits the memory it came from.
    @discardableResult
    func savePlace(countryCode: String, title: String, city: String = "", lat: Double? = nil,
                   lng: Double? = nil, note: String = "", tripId: UUID? = nil,
                   from memory: Memory? = nil) async throws -> SavedPlace {
        guard let myId else { throw AppError("You're signed out.") }
        let place = try await backend.savePlace(
            NewSavedPlace(id: UUID(), userId: myId, tripId: tripId, countryCode: countryCode,
                          title: title.trimmed, city: city.trimmed, lat: lat, lng: lng,
                          note: note.trimmed, sourceEntryId: memory?.id))
        guard self.myId == myId else { throw CancellationError() }
        savedPlaces.insert(place, at: 0)
        backend.logEvent("place_saved", props: ["country": countryCode,
                                                "from": memory == nil ? "search" : "memory"])
        saveSnapshot()
        return place
    }

    func updatePlace(_ place: SavedPlace, title: String? = nil, city: String? = nil,
                     note: String? = nil, tripId: UUID?? = nil, done: Bool? = nil) async throws {
        let owner = myId
        let before = savedPlaces
        var edited = place
        if let title { edited.title = title.trimmed }
        if let city { edited.city = city.trimmed }
        if let note { edited.note = note.trimmed }
        if let tripId { edited.tripId = tripId }
        if let done { edited.done = done }
        if let index = savedPlaces.firstIndex(where: { $0.id == place.id }) { savedPlaces[index] = edited }
        do {
            let fresh = try await backend.updateSavedPlace(
                id: place.id, SavedPlacePatch(tripId: edited.tripId, title: edited.title,
                                              city: edited.city, note: edited.note, done: edited.done))
            guard myId == owner else { return }
            if let index = savedPlaces.firstIndex(where: { $0.id == place.id }) { savedPlaces[index] = fresh }
            saveSnapshot()
        } catch {
            if myId == owner { savedPlaces = before }
            throw error
        }
    }

    /// Save (or unsave) the place a memory is about — how most places get
    /// onto your list: you see where a friend went and keep it.
    func toggleSavedPlace(from memory: Memory) async {
        do {
            if let existing = savedPlace(from: memory) {
                try await deletePlace(existing)
            } else {
                try await savePlace(countryCode: memory.countryCode, title: memory.title,
                                    city: memory.city ?? "", lat: memory.lat, lng: memory.lng,
                                    from: memory)
                celebrate("Saved to your places")
            }
        } catch {
            show(error)
        }
    }

    func deletePlace(_ place: SavedPlace) async throws {
        let owner = myId
        let before = savedPlaces
        savedPlaces.removeAll { $0.id == place.id }
        do {
            try await backend.deleteSavedPlace(id: place.id)
            if myId == owner { saveSnapshot() }
        } catch {
            if myId == owner { savedPlaces = before }
            throw error
        }
    }

    // ── People ───────────────────────────────────────────────────────────────

    func setFollowing(_ userId: UUID, _ follow: Bool) {
        let owner = myId
        if follow { following.insert(userId) } else { following.remove(userId) }
        Task {
            do {
                try await backend.setFollowing(userId, follow)
                backend.logEvent(follow ? "followed" : "unfollowed", props: nil)
                guard myId == owner else { return }
                if follow, people[userId] == nil { _ = await profiles(for: [userId]) }
                if myId == owner { saveSnapshot() }
            } catch {
                guard myId == owner else { return }
                if follow { following.remove(userId) } else { following.insert(userId) }
                show(error)
            }
        }
    }

    func block(_ userId: UUID) async {
        let owner = myId
        do {
            try await backend.setBlocked(userId, true)
            guard myId == owner else { return }
            blocked.insert(userId)
            following.remove(userId)
            toast = Toast(message: "Blocked. They won't show up in your feeds.", style: .success)
        } catch {
            show(error)
        }
    }

    func unblock(_ userId: UUID) async {
        let owner = myId
        do {
            try await backend.setBlocked(userId, false)
            guard myId == owner else { return }
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
        let owner = myId
        try await backend.updateProfile(patch)
        let fresh = try? await backend.myProfile()
        guard myId == owner else { return }
        if let fresh, fresh.id == owner { me = fresh }
        saveSnapshot()
    }

    func uploadAvatar(_ jpeg: Data) async throws {
        let owner = myId
        let url = try await backend.uploadAvatar(jpeg)
        if let parsed = URL(string: url) { await ImagePipeline.shared.prime(.url(parsed), data: jpeg) }
        guard myId == owner else { return }
        me?.avatarUrl = url
        saveSnapshot()
    }

    // ── Groups ───────────────────────────────────────────────────────────────

    func refreshGroups() async {
        let owner = myId
        guard let fresh = try? await backend.myGroups(), myId == owner else { return }
        groups = fresh
        if let members = try? await backend.groupMembers(groupIds: fresh.map(\.id)) {
            guard myId == owner else { return }
            membersByGroup = Dictionary(grouping: members, by: \.groupId)
            _ = await profiles(for: members.map(\.userId))
        }
        guard myId == owner else { return }
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
        let owner = myId
        try await backend.leaveGroup(id: id)
        guard myId == owner else { return }
        groups.removeAll { $0.id == id }
        membersByGroup[id] = nil
        saveSnapshot()
    }

    func deleteGroup(_ id: UUID) async throws {
        let owner = myId
        try await backend.deleteGroup(id: id)
        guard myId == owner else { return }
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
        guard let owner = myId, let rows = try? await backend.activity(limit: 50), myId == owner else { return }
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
        /// Optional so a snapshot written before trips existed still loads.
        var tripPlans: [TripPlan]?
        var savedPlaces: [SavedPlace]?
        var bucketList: Set<String>
        var following: Set<UUID>
        var followers: Set<UUID>
        var groups: [Group]
        var members: [GroupMember]
        var people: [Profile]
    }

    private func saveSnapshot() {
        guard let myId, !isDemo else { return }
        let snapshot = Snapshot(me: me, memories: memories, stamps: stamps,
                                tripPlans: tripPlans, savedPlaces: savedPlaces, bucketList: bucketList,
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
        tripPlans = snapshot.tripPlans ?? []
        savedPlaces = snapshot.savedPlaces ?? []
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
        placesByCountry = Dictionary(grouping: savedPlaces.filter { !$0.done }, by: \.countryCode)
        upcomingTrips = tripPlans.filter { !$0.isOver }
            .sorted { ($0.startsOn ?? "9999-99-99", $0.title) < ($1.startsOn ?? "9999-99-99", $1.title) }
        stats = TravelStats(stamps: stamps, memories: memories)
    }

    /// Chapters of your travels: memories grouped into trips, named by the
    /// plan that covers them when there is one.
    var tripChapters: [Trip] { TripBuilder.trips(from: memories, plans: tripPlans) }

    func places(on trip: TripPlan) -> [SavedPlace] {
        savedPlaces.filter { $0.tripId == trip.id }
            .sorted { ($0.done ? 1 : 0, $1.createdAt) < ($1.done ? 1 : 0, $0.createdAt) }
    }

    func memories(on trip: TripPlan) -> [Memory] {
        memories.filter(trip.covers).sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
    }

    /// Whether this memory is already on your list (so the button can say so).
    func savedPlace(from memory: Memory) -> SavedPlace? {
        savedPlaces.first { $0.sourceEntryId == memory.id }
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

    func newMemory(id: UUID, userId: UUID, photos: [String]) -> NewMemory {
        NewMemory(id: id, userId: userId, countryCode: countryCode, title: title.trimmed, city: city.trimmed,
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
