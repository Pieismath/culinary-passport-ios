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
        /// First stamp of its kind for this country — first visit for a
        /// memory, first taste for a meal — so the stamp moment plays.
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
    /// Meals (entries of kind 'meal') and the cuisines they've tasted.
    var meals: [Memory] = [] { didSet { rebuildDerived() } }
    var tastes: [Taste] = [] { didSet { rebuildDerived() } }
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
    private(set) var tastedCodes: Set<String> = []
    private(set) var tastesByCode: [String: Taste] = [:]
    private(set) var mealsByCountry: [String: [Memory]] = [:]
    private(set) var placesByCountry: [String: [SavedPlace]] = [:]
    /// Restaurants to try, by what they serve.
    private(set) var restaurantsByCuisine: [String: [SavedPlace]] = [:]
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
        meals = []
        tastes = []
        tripPlans = []
        savedPlaces = []
        lastImport = nil
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
            async let myMeals = backend.meals(userId: myId)
            async let myTastes = backend.tastes(userIds: [myId])
            let (p, m, s, b, fing, fers, bl, g) = try await (profile, memories, stamps, bucket,
                                                            following, followers, blocked, groups)
            let (plans, saved, eaten, tasted) = try await (trips, places, myMeals, myTastes)
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
            self.meals = eaten
            self.tastes = tasted
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

    func refreshTastes() async {
        guard let myId, let fresh = try? await backend.tastes(userIds: [myId]), self.myId == myId else { return }
        tastes = fresh
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
        let isMeal = draft.kind == .meal
        let wasVisited = isMeal ? tastedCodes.contains(draft.countryCode) : visitedCodes.contains(draft.countryCode)

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

        if isMeal {
            meals.removeAll { $0.id == saved.id }
            meals.append(saved)
            meals.sort { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
            mergeLocalTaste(saved)
        } else {
            memories.removeAll { $0.id == saved.id }
            memories.append(saved)
            memories.sort { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
            mergeLocalStamp(StampInput(countryCode: saved.countryCode, firstVisited: saved.date,
                                       lastVisited: saved.date, source: .memory))
        }

        for groupId in groupIds {
            try? await backend.createPost(groupId: groupId, text: "", memoryId: saved.id)
        }
        backend.logEvent(original == nil ? (isMeal ? "meal_added" : "memory_added")
                                         : (isMeal ? "meal_edited" : "memory_edited"),
                         props: ["country": saved.countryCode, "photos": String(photos.count)])
        saveSnapshot()
        Task {
            if isMeal { await refreshTastes() } else { await refreshStamps() }
            MemoryReminders.reschedule(memories: memories)
        }

        let isNew = original == nil && !wasVisited
        // Nº among cuisines for a meal; among sovereign countries for a visit.
        let number = isMeal ? max(1, stats.cuisines)
            : (CountryStore.byCode[saved.countryCode]?.isSovereign == true ? max(1, stats.countries) : nil)
        if isNew { lastStampBurst = [saved.countryCode] }
        return SaveResult(memory: saved, isNewCountry: isNew, countryNumber: number)
    }

    func deleteMemory(_ memory: Memory) async throws {
        let owner = myId
        let before = (memories, meals)
        if memory.isMeal { meals.removeAll { $0.id == memory.id } } else { memories.removeAll { $0.id == memory.id } }
        do {
            try await backend.deleteMemory(memory)
            backend.logEvent(memory.isMeal ? "meal_deleted" : "memory_deleted", props: nil)
            guard myId == owner else { return }
            saveSnapshot()
            if memory.isMeal { await refreshTastes() } else { await refreshStamps() }
            MemoryReminders.reschedule(memories: memories)
        } catch {
            if myId == owner { (memories, meals) = before }
            throw error
        }
    }

    // ── Tastes ───────────────────────────────────────────────────────────────

    /// Tick cuisines you've tried without logging a meal (the checklist).
    func addTastes(_ codes: [String]) async throws {
        guard let myId, !codes.isEmpty else { return }
        let before = tastes
        let fresh = codes.filter { !tastedCodes.contains($0) }
        for code in fresh {
            tastes.append(Taste(userId: myId, countryCode: code, firstTasted: nil, lastTasted: nil,
                                meals: 0, source: .manual, createdAt: Date()))
        }
        do {
            try await backend.addTastes(codes)
            guard self.myId == myId else { return }
            backend.logEvent("tastes_added", props: ["count": String(codes.count)])
            saveSnapshot()
            await refreshTastes()
        } catch {
            if self.myId == myId { tastes = before }
            throw error
        }
    }

    func removeTaste(_ code: String) async throws {
        let count = mealsByCountry[code]?.count ?? 0
        guard count == 0 else {
            throw AppError("Delete your \(count.counted("meal")) of \(Cuisine.name(for: code)) food first — they keep the stamp.")
        }
        let owner = myId
        let before = tastes
        tastes.removeAll { $0.countryCode == code }
        do {
            try await backend.removeTaste(countryCode: code)
            if myId == owner { saveSnapshot() }
        } catch {
            if myId == owner { tastes = before }
            throw error
        }
    }

    /// Mirror of sync_taste_from_meal for instant feedback; the server's
    /// answer replaces it moments later.
    private func mergeLocalTaste(_ meal: Memory) {
        guard let myId else { return }
        if let index = tastes.firstIndex(where: { $0.countryCode == meal.countryCode }) {
            var taste = tastes[index]
            taste.firstTasted = min(taste.firstTasted ?? meal.date, meal.date)
            taste.lastTasted = max(taste.lastTasted ?? meal.date, meal.date)
            taste.meals += 1
            tastes[index] = taste
        } else {
            tastes.append(Taste(userId: myId, countryCode: meal.countryCode, firstTasted: meal.date,
                                lastTasted: meal.date, meals: 1, source: .meal, createdAt: Date()))
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
                   lng: Double? = nil, note: String = "", tripId: UUID? = nil, cuisine: String? = nil,
                   from memory: Memory? = nil) async throws -> SavedPlace {
        guard let myId else { throw AppError("You're signed out.") }
        let place = try await backend.savePlace(
            NewSavedPlace(id: UUID(), userId: myId, tripId: tripId, countryCode: countryCode,
                          cuisineCode: cuisine, title: title.trimmed, city: city.trimmed, lat: lat, lng: lng,
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

    /// Upload photos onto a memory that has none — how an imported memory
    /// gets its pictures off the phone, when the traveller decides to.
    func attachPhotos(_ jpegs: [Data], to memory: Memory) async throws {
        guard let myId, !jpegs.isEmpty else { return }
        var uploaded: [String] = []
        do {
            for jpeg in jpegs {
                let path = try await backend.uploadPhoto(jpeg)
                await ImagePipeline.shared.prime(.storage(path), data: jpeg)
                uploaded.append(path)
            }
        } catch {
            await backend.removePhotos(uploaded)
            throw error
        }
        var draft = MemoryDraft(memory: memory)
        draft.keptPhotos = memory.photos + uploaded
        do {
            let saved = try await backend.updateMemory(id: memory.id, draft.patch(photos: draft.keptPhotos))
            guard self.myId == myId else { throw CancellationError() }
            if let index = memories.firstIndex(where: { $0.id == saved.id }) {
                memories[index] = saved
            } else if let index = meals.firstIndex(where: { $0.id == saved.id }) {
                meals[index] = saved
            }
            saveSnapshot()
        } catch {
            await backend.removePhotos(uploaded)
            throw error
        }
    }

    /// What one photo-library import created, so it can be undone whole.
    struct ImportSummary: Codable, Equatable {
        var tripIds: [UUID] = []
        var memoryIds: [UUID] = []
        var countries = 0

        var isEmpty: Bool { tripIds.isEmpty && memoryIds.isEmpty }
        var text: String {
            "\(tripIds.count.counted("trip")) · \(memoryIds.count.counted("place"))"
        }
    }

    /// The last import, while it's still undoable (this launch).
    private(set) var lastImport: ImportSummary?

    /// Turn what the photos say into trips and memories. Everything lands
    /// private and photo-less: the passport fills in, nothing is broadcast,
    /// and a photo is only uploaded if the traveller later picks it.
    @discardableResult
    func importPhotoTrips(_ trips: [PhotoTrip]) async throws -> ImportSummary {
        guard let myId, !trips.isEmpty else { return ImportSummary() }
        var drafts: [NewMemory] = []
        var plans: [NewTripPlan] = []
        for trip in trips {
            plans.append(NewTripPlan(id: UUID(), userId: myId, name: "", countryCodes: trip.countryCodes,
                                     startsOn: DayFormat.string(from: trip.first),
                                     endsOn: DayFormat.string(from: trip.last),
                                     groupId: nil, notes: ""))
            for stop in trip.stops {
                drafts.append(NewMemory(id: UUID(), userId: myId, countryCode: stop.countryCode,
                                        title: stop.title, city: stop.city,
                                        dateTried: DayFormat.string(from: stop.first), notes: "",
                                        photos: [],
                                        // A cluster centre is already vague; round it anyway.
                                        lat: PlaceSearch.coarse(stop.lat), lng: PlaceSearch.coarse(stop.lng),
                                        visibility: Visibility.private.rawValue))
            }
        }

        let savedMemories = try await backend.insertMemories(drafts)
        let savedPlans = try await backend.createTripPlans(plans)
        guard self.myId == myId else { throw CancellationError() }

        memories.append(contentsOf: savedMemories)
        memories.sort { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
        tripPlans.append(contentsOf: savedPlans)
        let summary = ImportSummary(tripIds: savedPlans.map(\.id), memoryIds: savedMemories.map(\.id),
                                    countries: Set(savedMemories.map(\.countryCode)).count)
        lastImport = summary
        backend.logEvent("photos_imported", props: ["trips": String(savedPlans.count),
                                                    "memories": String(savedMemories.count)])
        saveSnapshot()
        await refreshStamps()
        MemoryReminders.reschedule(memories: memories)
        return summary
    }

    /// Stop offering the undo (the traveller is happy with what landed).
    func dismissImportSummary() { lastImport = nil }

    /// Put the passport back exactly as it was before the import.
    func undoImport(_ summary: ImportSummary) async throws {
        let owner = myId
        try await backend.deleteMemories(ids: summary.memoryIds)
        try await backend.deleteTripPlans(ids: summary.tripIds)
        guard myId == owner else { return }
        let removed = Set(summary.memoryIds)
        memories.removeAll { removed.contains($0.id) }
        let removedTrips = Set(summary.tripIds)
        tripPlans.removeAll { removedTrips.contains($0.id) }
        if lastImport == summary { lastImport = nil }
        backend.logEvent("photo_import_undone", props: nil)
        saveSnapshot()
        await refreshStamps()
        MemoryReminders.reschedule(memories: memories)
    }

    /// Save (or unsave) the place a memory is about — how most places get
    /// onto your list: you see where a friend went and keep it.
    func toggleSavedPlace(from memory: Memory) async {
        do {
            if let existing = savedPlace(from: memory) {
                try await deletePlace(existing)
            } else if memory.isMeal {
                // A meal is a restaurant to try: filed where it is, tagged
                // with what it serves.
                let here = memory.lat.flatMap { lat in memory.lng.flatMap { PlaceLocator.country(lat: lat, lng: $0) } }
                try await savePlace(countryCode: here ?? me?.homeCountry ?? memory.countryCode,
                                    title: memory.restaurantName.isEmpty ? memory.displayTitle : memory.restaurantName,
                                    city: memory.city ?? "", lat: memory.lat, lng: memory.lng,
                                    note: memory.dish.isEmpty ? "" : "Try the \(memory.dish.lowercased())",
                                    cuisine: memory.countryCode, from: memory)
                celebrate("Saved to your restaurants")
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
        var meals: [Memory]?
        var tastes: [Taste]?
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
                                tripPlans: tripPlans, savedPlaces: savedPlaces, meals: meals, tastes: tastes,
                                bucketList: bucketList,
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
        meals = snapshot.meals ?? []
        tastes = snapshot.tastes ?? []
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
        tastedCodes = Set(tastes.map(\.countryCode))
        tastesByCode = Dictionary(tastes.map { ($0.countryCode, $0) }, uniquingKeysWith: { a, _ in a })
        mealsByCountry = Dictionary(grouping: meals, by: \.countryCode)
        placesByCountry = Dictionary(grouping: savedPlaces.filter { !$0.done }, by: \.countryCode)
        restaurantsByCuisine = Dictionary(grouping: savedPlaces.filter { !$0.done && $0.cuisineCode != nil },
                                          by: { $0.cuisineCode ?? "" })
        upcomingTrips = tripPlans.filter { !$0.isOver }
            .sorted { ($0.startsOn ?? "9999-99-99", $0.title) < ($1.startsOn ?? "9999-99-99", $1.title) }
        stats = TravelStats(stamps: stamps, memories: memories, tastes: tastes, meals: meals.count)
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
    var kind: Memory.Kind = .memory
    var restaurantName = ""
    var dish = ""
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
        kind = memory.kind
        restaurantName = memory.restaurantName
        dish = memory.dish
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
        NewMemory(id: id, userId: userId, kind: kind.rawValue, countryCode: countryCode, title: title.trimmed,
                  city: city.trimmed, dateTried: DayFormat.string(from: date), notes: notes.trimmed,
                  photos: photos, lat: lat, lng: lng, visibility: visibility.rawValue,
                  restaurantName: restaurantName.trimmed, signatureDish: dish.trimmed)
    }

    func patch(photos: [String]) -> MemoryPatch {
        MemoryPatch(countryCode: countryCode, title: title.trimmed, city: city.trimmed,
                    dateTried: DayFormat.string(from: date), notes: notes.trimmed, photos: photos,
                    lat: lat, lng: lng, visibility: visibility.rawValue,
                    restaurantName: restaurantName.trimmed, signatureDish: dish.trimmed)
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
