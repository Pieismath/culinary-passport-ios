import SwiftUI
import Supabase
import UserNotifications

/// The signed-in eater's world, shared by every tab: meals, the cuisines
/// they've tasted, restaurants to try, friends and tables.
///
/// One source of truth, so a meal logged from the globe shows up on Me and at
/// every table at once. Mutations update local state immediately and
/// reconcile with the server; the last known state is cached per account so
/// cold launches render instantly.
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
        case meal(UUID)
        case joinGroup(String)
        case profile(UUID)

        var id: String {
            switch self {
            case .meal(let id): "meal-\(id)"
            case .joinGroup(let code): "join-\(code)"
            case .profile(let id): "profile-\(id)"
            }
        }
    }

    struct SaveResult {
        let meal: Meal
        /// The cuisine's first taste, so the stamp moment plays.
        let isFirstTaste: Bool
        /// "Cuisine Nº 21" — how many cuisines you've tasted, this one included.
        let cuisineNumber: Int
    }

    private(set) var backend: any Backend
    private(set) var isDemo: Bool
    var session: SessionState = .unknown

    // ── The eater ────────────────────────────────────────────────────────────
    var me: Profile?
    var meals: [Meal] = [] { didSet { rebuildDerived() } }
    var tastes: [Taste] = [] { didSet { rebuildDerived() } }
    /// Restaurants saved to try (and the ones ticked off).
    var savedPlaces: [SavedPlace] = [] { didSet { rebuildDerived() } }
    var following: Set<UUID> = []
    var followers: Set<UUID> = []
    var blocked: Set<UUID> = []
    var groups: [Group] = []
    var membersByGroup: [UUID: [GroupMember]] = [:]
    /// Profiles of everyone around you (friends, table mates, authors seen).
    var people: [UUID: Profile] = [:]
    /// What everyone around you has tasted: table globes, table spins, and
    /// "Maya's had it" on a cuisine.
    var peopleTastes: [UUID: Set<String>] = [:]

    var loadState: LoadState = .idle
    var toast: Toast?
    var route: Route?
    var needsOnboarding = false

    // ── Derived (rebuilt when meals/tastes/places change) ────────────────────
    private(set) var tastedCodes: Set<String> = []
    private(set) var tastesByCode: [String: Taste] = [:]
    private(set) var mealsByCountry: [String: [Meal]] = [:]
    /// Restaurants still to try, by what they serve.
    private(set) var restaurantsByCuisine: [String: [SavedPlace]] = [:]
    /// Restaurants still to try, newest first.
    private(set) var toTry: [SavedPlace] = []
    private(set) var stats = FoodStats()

    var myId: UUID? {
        if case .signedIn(let id) = session { return id }
        return nil
    }

    /// Mutual follows plus everyone you share a table with.
    var friendIds: Set<UUID> {
        following.intersection(followers).union(groupMateIds)
    }

    /// People whose meals you see: who you follow + your tables.
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
        Self.cancelTravelReminders()
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
    }

    func deleteAccount() async throws {
        try await backend.deleteAccount()
        await ImagePipeline.shared.clearAll()
        if isDemo { await signOut() }
    }

    private func resetUserData() {
        me = nil
        meals = []
        tastes = []
        savedPlaces = []
        following = []
        followers = []
        blocked = []
        groups = []
        membersByGroup = [:]
        people = [:]
        peopleTastes = [:]
        loadState = .idle
        needsOnboarding = false
    }

    /// The travel build scheduled "on this day" reminders for trips; they'd
    /// open links that go nowhere now.
    private static func cancelTravelReminders() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("onthisday-") }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    // ── Loading ──────────────────────────────────────────────────────────────

    func bootstrap() async {
        guard let myId else { return }
        restoreSnapshot(for: myId)
        loadState = (meals.isEmpty && tastes.isEmpty && me == nil) ? .loading : .loaded
        await refresh()
        guard self.myId == myId else { return }
        if !Onboarding.isDone(for: myId), tastes.isEmpty, meals.isEmpty, loadState == .loaded {
            needsOnboarding = true
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-onboarding") { needsOnboarding = true }
        #endif
    }

    /// Reload everything about the eater. Safe to call from pull-to-refresh.
    func refresh() async {
        guard let myId else { return }
        let backend = self.backend
        do {
            async let profile = backend.myProfile()
            async let meals = backend.meals(userId: myId)
            async let tastes = backend.tastes(userIds: [myId])
            async let places = backend.savedPlaces()
            async let following = backend.followingIds(of: myId)
            async let followers = backend.followerIds(of: myId)
            async let blocked = backend.blockedIds()
            async let groups = backend.myGroups()
            let (p, m, t, sp) = try await (profile, meals, tastes, places)
            let (fing, fers, bl, g) = try await (following, followers, blocked, groups)
            guard self.myId == myId else { return }
            guard let p else {
                // Profile row is gone (deleted account / stale session).
                await backend.signOut()
                return
            }
            me = p
            self.meals = m
            self.tastes = t
            savedPlaces = sp
            self.following = Set(fing)
            self.followers = Set(fers)
            self.blocked = bl
            self.groups = g
            // Your own world is in: the app is usable from here even if the
            // table/people round trips below fail.
            loadState = .loaded
        } catch {
            guard !(error is CancellationError), self.myId == myId else { return }
            if me == nil && meals.isEmpty && tastes.isEmpty {
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
        await refreshPeopleTastes()
        saveSnapshot()
    }

    func refreshTastes() async {
        guard let myId, let fresh = try? await backend.tastes(userIds: [myId]), self.myId == myId else { return }
        tastes = fresh
        saveSnapshot()
    }

    /// What your friends and table mates have tasted (or just `ids`).
    func refreshPeopleTastes(_ ids: [UUID]? = nil) async {
        let owner = myId
        let wanted = ids ?? Array(networkIds.union(groupMateIds))
        let others = wanted.filter { $0 != owner }
        guard !others.isEmpty, let found = try? await backend.tastes(userIds: others), myId == owner else { return }
        var fresh = Dictionary(grouping: found, by: \.userId).mapValues { Set($0.map(\.countryCode)) }
        // Someone who's tasted nothing (or hides it) is still "loaded".
        for id in others where fresh[id] == nil { fresh[id] = [] }
        peopleTastes.merge(fresh) { _, new in new }
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

    // ── Meals ────────────────────────────────────────────────────────────────

    /// Upload photos, then insert or update the meal, share it to tables,
    /// and fold the result into local state.
    ///
    /// `newId` names a new meal before it exists; pass the same id when
    /// retrying, so a save whose response was lost can't land twice.
    func saveMeal(_ draft: MealDraft, editing original: Meal?, newId: UUID = UUID(),
                  newPhotos: [Data], shareTo groupIds: Set<UUID>) async throws -> SaveResult {
        guard let myId else { throw AppError("You're signed out.") }
        let wasTasted = tastedCodes.contains(draft.countryCode)

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

        let saved: Meal
        do {
            if let original {
                saved = try await backend.updateMeal(id: original.id, draft.patch(photos: photos))
            } else {
                saved = try await backend.insertMeal(draft.newMeal(id: newId, userId: myId, photos: photos))
            }
        } catch let saveError {
            // A lost response can hide a write that landed: look before
            // deleting uploads that a saved meal may already point at.
            let row: Meal?
            do {
                row = try await backend.meal(id: original?.id ?? newId)
            } catch {
                // Still can't tell (offline). Keep the uploads; a retry reuses the id.
                throw saveError
            }
            let expected: MealPatch? = original == nil ? nil : draft.patch(photos: photos)
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

        meals.removeAll { $0.id == saved.id }
        meals.append(saved)
        meals.sort { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
        if original == nil { mergeLocalTaste(saved) }

        for groupId in groupIds {
            try? await backend.createPost(groupId: groupId, text: "", mealId: saved.id, pick: nil)
        }
        backend.logEvent(original == nil ? "meal_added" : "meal_edited",
                         props: ["cuisine": saved.countryCode, "photos": String(photos.count)])
        saveSnapshot()
        Task { await refreshTastes() }

        let isNew = original == nil && !wasTasted
        return SaveResult(meal: saved, isFirstTaste: isNew, cuisineNumber: max(1, stats.cuisines))
    }

    func deleteMeal(_ meal: Meal) async throws {
        let owner = myId
        let before = meals
        meals.removeAll { $0.id == meal.id }
        do {
            try await backend.deleteMeal(meal)
            backend.logEvent("meal_deleted", props: nil)
            guard myId == owner else { return }
            saveSnapshot()
            await refreshTastes()
        } catch {
            if myId == owner { meals = before }
            throw error
        }
    }

    // ── Tastes ───────────────────────────────────────────────────────────────

    /// Tick cuisines you've tried without logging a meal.
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
    private func mergeLocalTaste(_ meal: Meal) {
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

    // ── Restaurants to try ───────────────────────────────────────────────────

    /// Keep a restaurant for later. `from` credits the meal it came from.
    @discardableResult
    func savePlace(countryCode: String, title: String, city: String = "", lat: Double? = nil,
                   lng: Double? = nil, note: String = "", cuisine: String,
                   from meal: Meal? = nil) async throws -> SavedPlace {
        guard let myId else { throw AppError("You're signed out.") }
        let place = try await backend.savePlace(
            NewSavedPlace(id: UUID(), userId: myId, countryCode: countryCode, cuisineCode: cuisine,
                          title: title.trimmed, city: city.trimmed, lat: lat, lng: lng,
                          note: note.trimmed, sourceEntryId: meal?.id))
        guard self.myId == myId else { throw CancellationError() }
        savedPlaces.insert(place, at: 0)
        backend.logEvent("place_saved", props: ["cuisine": cuisine, "from": meal == nil ? "search" : "meal"])
        saveSnapshot()
        return place
    }

    func updatePlace(_ place: SavedPlace, title: String? = nil, city: String? = nil,
                     note: String? = nil, done: Bool? = nil) async throws {
        let owner = myId
        let before = savedPlaces
        var edited = place
        if let title { edited.title = title.trimmed }
        if let city { edited.city = city.trimmed }
        if let note { edited.note = note.trimmed }
        if let done { edited.done = done }
        if let index = savedPlaces.firstIndex(where: { $0.id == place.id }) { savedPlaces[index] = edited }
        do {
            let fresh = try await backend.updateSavedPlace(
                id: place.id, SavedPlacePatch(title: edited.title, city: edited.city,
                                              note: edited.note, done: edited.done))
            guard myId == owner else { return }
            if let index = savedPlaces.firstIndex(where: { $0.id == place.id }) { savedPlaces[index] = fresh }
            saveSnapshot()
        } catch {
            if myId == owner { savedPlaces = before }
            throw error
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

    /// Save (or unsave) the restaurant a friend's meal was at — filed where
    /// the restaurant is, tagged with what it serves.
    func toggleSavedPlace(from meal: Meal) async {
        do {
            if let existing = savedPlace(from: meal) {
                try await deletePlace(existing)
            } else {
                let here = meal.lat.flatMap { lat in meal.lng.flatMap { PlaceLocator.country(lat: lat, lng: $0) } }
                try await savePlace(countryCode: here ?? me?.homeCountry ?? meal.countryCode,
                                    title: meal.restaurantName.isEmpty ? meal.displayTitle : meal.restaurantName,
                                    city: meal.city ?? "", lat: meal.lat, lng: meal.lng,
                                    note: meal.dish.isEmpty ? "" : "Try the \(meal.dish.lowercased())",
                                    cuisine: meal.countryCode, from: meal)
                celebrate("Saved to restaurants to try")
            }
        } catch {
            show(error)
        }
    }

    /// Whether this meal's restaurant is already on your list.
    func savedPlace(from meal: Meal) -> SavedPlace? {
        savedPlaces.first { $0.sourceEntryId == meal.id }
    }

    // ── Tables + spins ───────────────────────────────────────────────────────

    /// Who's eating: just you, or everyone at a table.
    func eaters(at groupId: UUID?) -> [UUID] {
        guard let groupId else { return myId.map { [$0] } ?? [] }
        return members(of: groupId)
    }

    /// Every cuisine anyone in `ids` has tasted.
    func tasted(by ids: [UUID]) -> Set<String> {
        ids.reduce(into: Set<String>()) { result, id in
            result.formUnion(id == myId ? tastedCodes : peopleTastes[id] ?? [])
        }
    }

    /// Cuisines every one of `ids` has tasted.
    func tastedByEveryone(_ ids: [UUID]) -> Set<String> {
        guard let first = ids.first else { return [] }
        return ids.dropFirst().reduce(first == myId ? tastedCodes : peopleTastes[first] ?? []) { result, id in
            result.intersection(id == myId ? tastedCodes : peopleTastes[id] ?? [])
        }
    }

    /// What a spin can land on: a cuisine nobody eating has tasted.
    func spinPool(for groupId: UUID?) -> [String] {
        Cuisine.dinnerPool(tastedByTable: tasted(by: eaters(at: groupId)), tastedByMe: tastedCodes)
    }

    /// Put a dinner pick in front of a table.
    func postPick(_ pick: DinnerPick, to groupId: UUID, text: String = "") async throws {
        try await backend.createPost(groupId: groupId, text: text, mealId: nil, pick: pick)
        backend.logEvent("pick_shared", props: ["cuisine": pick.cuisineCode, "restaurant": String(pick.hasPlace)])
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
                if follow { await refreshPeopleTastes([userId]) }
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
            toast = Toast(message: "Blocked. They won't show up for you anymore.", style: .success)
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

    // ── Tables (groups) ──────────────────────────────────────────────────────

    func refreshGroups() async {
        let owner = myId
        guard let fresh = try? await backend.myGroups(), myId == owner else { return }
        groups = fresh
        if let members = try? await backend.groupMembers(groupIds: fresh.map(\.id)) {
            guard myId == owner else { return }
            membersByGroup = Dictionary(grouping: members, by: \.groupId)
            _ = await profiles(for: members.map(\.userId))
            await refreshPeopleTastes(members.map(\.userId))
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

    /// Members in the order they sat down.
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

    /// culinarypassport://join/<code> · culinarypassport://meal/<uuid>
    /// (travel-era culinarypassport://memory/<uuid> links open the same way).
    func handle(url: URL) {
        guard url.scheme == "culinarypassport" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "join":
            let code = parts.first
                ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value
            if let code, !code.isEmpty { route = .joinGroup(code) }
        case "meal", "memory":
            if let raw = parts.first, let id = UUID(uuidString: raw) { route = .meal(id) }
        case "profile":
            if let raw = parts.first, let id = UUID(uuidString: raw) { route = .profile(id) }
        default:
            break
        }
    }

    // ── Cache ────────────────────────────────────────────────────────────────

    private struct Snapshot: Codable {
        var me: Profile?
        var meals: [Meal]
        var tastes: [Taste]
        var savedPlaces: [SavedPlace]
        var following: Set<UUID>
        var followers: Set<UUID>
        var groups: [Group]
        var members: [GroupMember]
        var people: [Profile]
        var peopleTastes: [UUID: Set<String>]?
    }

    private static let snapshotKey = "food-v1"

    private func saveSnapshot() {
        guard let myId, !isDemo else { return }
        let snapshot = Snapshot(me: me, meals: meals, tastes: tastes, savedPlaces: savedPlaces,
                                following: following, followers: followers, groups: groups,
                                members: membersByGroup.values.flatMap { $0 },
                                people: Array(people.values), peopleTastes: peopleTastes)
        DiskCache.save(snapshot, key: Self.snapshotKey, user: myId)
    }

    private func restoreSnapshot(for user: UUID) {
        guard !isDemo, let snapshot = DiskCache.load(Self.snapshotKey, user: user, as: Snapshot.self) else { return }
        me = snapshot.me
        meals = snapshot.meals
        tastes = snapshot.tastes
        savedPlaces = snapshot.savedPlaces
        following = snapshot.following
        followers = snapshot.followers
        groups = snapshot.groups
        membersByGroup = Dictionary(grouping: snapshot.members, by: \.groupId)
        for person in snapshot.people { people[person.id] = person }
        peopleTastes = snapshot.peopleTastes ?? [:]
    }

    private func rebuildDerived() {
        tastedCodes = Set(tastes.map(\.countryCode))
        tastesByCode = Dictionary(tastes.map { ($0.countryCode, $0) }, uniquingKeysWith: { a, _ in a })
        mealsByCountry = Dictionary(grouping: meals, by: \.countryCode)
        toTry = savedPlaces.filter { !$0.done && $0.isRestaurant }.sorted { $0.createdAt > $1.createdAt }
        restaurantsByCuisine = Dictionary(grouping: toTry, by: { $0.cuisineCode ?? "" })
        stats = FoodStats(tastes: tastes, meals: meals)
    }
}

/// The fields a person edits for one meal.
struct MealDraft: Equatable {
    /// Carried through untouched: meals don't show it, but rows from the
    /// culinary era have one.
    var title = ""
    var restaurantName = ""
    var dish = ""
    var countryCode = ""
    var city = ""
    var date = Date()
    var notes = ""
    var lat: Double?
    var lng: Double?
    var visibility: Visibility = .friends
    /// Photos already stored (editing) that are being kept, in order.
    var keptPhotos: [String] = []

    init() {}

    init(meal: Meal) {
        title = meal.title
        restaurantName = meal.restaurantName
        dish = meal.dish
        countryCode = meal.countryCode
        city = meal.city ?? ""
        date = meal.day ?? Date()
        notes = meal.notes ?? ""
        lat = meal.lat
        lng = meal.lng
        visibility = meal.visibility
        keptPhotos = meal.photos
    }

    func newMeal(id: UUID, userId: UUID, photos: [String]) -> NewMeal {
        NewMeal(id: id, userId: userId, kind: Meal.Kind.meal.rawValue, countryCode: countryCode, title: title.trimmed,
                city: city.trimmed, dateTried: DayFormat.string(from: date), notes: notes.trimmed,
                photos: photos, lat: lat, lng: lng, visibility: visibility.rawValue,
                restaurantName: restaurantName.trimmed, signatureDish: dish.trimmed)
    }

    func patch(photos: [String]) -> MealPatch {
        MealPatch(countryCode: countryCode, title: title.trimmed, city: city.trimmed,
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
