import Foundation

// Mirrors the Supabase schema (web repo supabase/migrations). The app is about
// food alone: meals (entries of kind 'meal'), the cuisines they taste, and the
// tables (groups) you eat with. JSON keys are snake_case on the wire; the
// shared decoder converts them, so CodingKeys below use camelCase raw values
// where a Swift name differs from the column's.

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var color: String
    var homeCity: String?
    var homeCountry: String?
    var username: String?
    var bio: String?
    var avatarUrl: String?
    var isPublic: Bool?
    var createdAt: Date?
    /// "How many NEW cuisines this year?" Nil = not set.
    var yearlyGoal: Int?

    var handle: String? { username.flatMap { $0.isEmpty ? nil : "@\($0)" } }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// Who can see a meal. The raw value `groups` predates the tables; it
/// means Friends now — mutual follows or anyone you share a group with.
enum Visibility: String, Codable, CaseIterable, Identifiable {
    case friends = "groups"
    case `public` = "public"
    case `private` = "private"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .friends: "Friends"
        case .public: "Public"
        case .private: "Only me"
        }
    }

    var systemImage: String {
        switch self {
        case .friends: "person.2.fill"
        case .public: "globe"
        case .private: "lock.fill"
        }
    }

    var explanation: String {
        switch self {
        case .friends: "People you follow each other with, and your groups."
        case .public: "Anyone on Stampd, including Discover."
        case .private: "Just you. It still counts on your globe."
        }
    }
}

/// A meal: photos, the restaurant, the dish, a date, a few words. Stored as an
/// `entries` row of kind 'meal'; countryCode is the cuisine's country (a
/// Georgian dinner in San Francisco is GE). Rows of kind 'memory' are from the
/// travel era — still decodable, never loaded.
struct Meal: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case memory, meal }

    let id: UUID
    let userId: UUID
    var kind: Kind
    var countryCode: String
    var title: String
    var city: String?
    /// yyyy-MM-dd (entries.date_tried)
    var date: String
    var notes: String?
    var photos: [String]
    var lat: Double?
    var lng: Double?
    var visibility: Visibility
    let createdAt: Date
    /// Meals: where, and what you had.
    var restaurantName: String
    var dish: String

    enum CodingKeys: String, CodingKey {
        case id, userId, kind, countryCode, title, city, notes, photos, lat, lng, visibility, createdAt
        case restaurantName
        case date = "dateTried"
        case dish = "signatureDish"
    }

    init(id: UUID, userId: UUID, countryCode: String, title: String, city: String?,
         date: String, notes: String?, photos: [String], lat: Double?, lng: Double?,
         visibility: Visibility, createdAt: Date, kind: Kind = .meal,
         restaurantName: String = "", dish: String = "") {
        self.id = id
        self.userId = userId
        self.kind = kind
        self.restaurantName = restaurantName
        self.dish = dish
        self.countryCode = countryCode
        self.title = title
        self.city = city
        self.date = date
        self.notes = notes
        self.photos = photos
        self.lat = lat
        self.lng = lng
        self.visibility = visibility
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userId = try c.decode(UUID.self, forKey: .userId)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .meal
        restaurantName = try c.decodeIfPresent(String.self, forKey: .restaurantName) ?? ""
        dish = try c.decodeIfPresent(String.self, forKey: .dish) ?? ""
        countryCode = try c.decode(String.self, forKey: .countryCode)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city)
        date = try c.decode(String.self, forKey: .date)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lng = try c.decodeIfPresent(Double.self, forKey: .lng)
        visibility = (try? c.decode(Visibility.self, forKey: .visibility)) ?? .friends
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    var country: Country? { CountryStore.byCode[countryCode] }

    var isMeal: Bool { kind == .meal }

    /// "Fushimi Inari" / "Kyoto" / "Japan" — or for a meal, "Khachapuri" /
    /// "Supra" / "Georgian": the best short name we have.
    var displayTitle: String {
        if isMeal {
            if !dish.trimmed.isEmpty { return dish }
            if !restaurantName.trimmed.isEmpty { return restaurantName }
            return Cuisine.name(for: countryCode)
        }
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if let city, !city.isEmpty { return city }
        return country?.name ?? countryCode
    }

    /// "Kyoto, Japan" — or for a meal, "Supra, Brooklyn". Omits whatever the
    /// title already says.
    var placeLine: String {
        if isMeal {
            var parts: [String] = []
            if !restaurantName.isEmpty, restaurantName != displayTitle { parts.append(restaurantName) }
            if let city, !city.isEmpty { parts.append(city) }
            return parts.isEmpty ? Cuisine.name(for: countryCode) : parts.joined(separator: ", ")
        }
        var parts: [String] = []
        if let city, !city.isEmpty, city != title { parts.append(city) }
        parts.append(country?.name ?? countryCode)
        return parts.joined(separator: ", ")
    }

    /// "🇬🇪 Georgian at Supra" (a travel-era memory: "🇯🇵 Kyoto, Japan").
    var feedLine: String {
        guard isMeal else { return "\(country?.flag ?? "") \(placeLine)" }
        let cuisine = "\(Country.flag(for: countryCode)) \(Cuisine.name(for: countryCode))"
        return restaurantName.isEmpty ? cuisine : "\(cuisine) at \(restaurantName)"
    }

    /// "🇬🇪 Georgian" (a travel-era memory: "🇯🇵 Japan").
    var stampLine: String {
        "\(Country.flag(for: countryCode)) \(isMeal ? Cuisine.name(for: countryCode) : country?.name ?? countryCode)"
    }

    var day: Date? { DayFormat.date(from: date) }
    var hasCoordinate: Bool { lat != nil && lng != nil }

    /// Whether this row already holds every field of `patch` (an update whose
    /// response was lost may still have landed).
    func matches(_ patch: MealPatch) -> Bool {
        countryCode == patch.countryCode && title == patch.title && (city ?? "") == patch.city
            && restaurantName == patch.restaurantName && dish == patch.signatureDish
            && String(date.prefix(10)) == patch.dateTried && (notes ?? "") == patch.notes
            && photos == patch.photos && lat == patch.lat && lng == patch.lng
            && visibility.rawValue == patch.visibility
    }
}

/// Insert payload. The id is chosen on the device so a retried save can't
/// land twice; created_at comes from Postgres.
struct NewMeal: Encodable {
    let id: UUID
    let userId: UUID
    var kind = "meal"
    var countryCode: String
    var title: String
    var city: String
    var dateTried: String
    var notes: String
    var photos: [String]
    var lat: Double?
    var lng: Double?
    var visibility: String
    var restaurantName = ""
    var signatureDish = ""
}

/// Full replacement of the editable fields. Encodes nil coordinates as
/// explicit nulls — clearing a place must clear the stored coordinates too.
struct MealPatch: Encodable {
    var countryCode: String
    var title: String
    var city: String
    var dateTried: String
    var notes: String
    var photos: [String]
    var lat: Double?
    var lng: Double?
    var visibility: String
    var restaurantName = ""
    var signatureDish = ""

    enum CodingKeys: String, CodingKey {
        case countryCode, title, city, dateTried, notes, photos, lat, lng, visibility
        case restaurantName, signatureDish
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(countryCode, forKey: .countryCode)
        try c.encode(title, forKey: .title)
        try c.encode(city, forKey: .city)
        try c.encode(dateTried, forKey: .dateTried)
        try c.encode(notes, forKey: .notes)
        try c.encode(photos, forKey: .photos)
        try c.encode(lat, forKey: .lat)
        try c.encode(lng, forKey: .lng)
        try c.encode(visibility, forKey: .visibility)
        try c.encode(restaurantName, forKey: .restaurantName)
        try c.encode(signatureDish, forKey: .signatureDish)
    }
}

/// A cuisine you've tasted (`tastes`) — a stamp in the food passport.
/// Refitted from your meals on the server; a cuisine ticked on the checklist
/// has no meals or dates.
struct Taste: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case manual, meal }

    let userId: UUID
    let countryCode: String
    var firstTasted: String?
    var lastTasted: String?
    var meals: Int
    var source: Source
    let createdAt: Date

    init(userId: UUID, countryCode: String, firstTasted: String?, lastTasted: String?,
         meals: Int, source: Source, createdAt: Date) {
        self.userId = userId
        self.countryCode = countryCode
        self.firstTasted = firstTasted
        self.lastTasted = lastTasted
        self.meals = meals
        self.source = source
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        countryCode = try c.decode(String.self, forKey: .countryCode)
        firstTasted = try c.decodeIfPresent(String.self, forKey: .firstTasted)
        lastTasted = try c.decodeIfPresent(String.self, forKey: .lastTasted)
        meals = try c.decodeIfPresent(Int.self, forKey: .meals) ?? 0
        source = (try? c.decode(Source.self, forKey: .source)) ?? .manual
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    var id: String { "\(userId.uuidString)|\(countryCode)" }
    var cuisine: String { Cuisine.name(for: countryCode) }

    /// "2021" or "2019 – 2024"; nil for a cuisine ticked without meals.
    var yearsText: String? {
        let first = firstTasted.map { String($0.prefix(4)) }
        let last = lastTasted.map { String($0.prefix(4)) }
        switch (first, last) {
        case let (f?, l?) where f != l: return "\(f) – \(l)"
        case let (f?, _): return f
        default: return nil
        }
    }
}

struct Group: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var coverPhoto: String?
    var inviteCode: String
    let createdBy: UUID
    let createdAt: Date
}

struct GroupMember: Codable, Hashable {
    let groupId: UUID
    let userId: UUID
    var role: Role
    let joinedAt: Date

    enum Role: String, Codable { case owner, member }
}

/// A message at a table. It can carry a shared meal (entryId) or a dinner
/// pick: the cuisine a spin landed on, and optionally the restaurant someone
/// suggests for it. Members answer a pick with the 🙋 reaction ("I'm in").
struct GroupPost: Codable, Identifiable, Hashable {
    let id: UUID
    let groupId: UUID
    let authorId: UUID
    /// A shared meal (group_posts.entry_id).
    var entryId: UUID?
    var text: String
    var photos: [String]
    let createdAt: Date
    var cuisineCode: String?
    var placeName: String?
    var placeAddress: String?
    var placeLat: Double?
    var placeLng: Double?

    static let imIn = "🙋"

    init(id: UUID, groupId: UUID, authorId: UUID, entryId: UUID?, text: String, photos: [String],
         createdAt: Date, pick: DinnerPick? = nil) {
        self.id = id
        self.groupId = groupId
        self.authorId = authorId
        self.entryId = entryId
        self.text = text
        self.photos = photos
        self.createdAt = createdAt
        cuisineCode = pick?.cuisineCode
        placeName = pick?.placeName
        placeAddress = pick?.placeAddress
        placeLat = pick?.placeLat
        placeLng = pick?.placeLng
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        groupId = try c.decode(UUID.self, forKey: .groupId)
        authorId = try c.decode(UUID.self, forKey: .authorId)
        entryId = try c.decodeIfPresent(UUID.self, forKey: .entryId)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        photos = try c.decodeIfPresent([String].self, forKey: .photos) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        cuisineCode = try c.decodeIfPresent(String.self, forKey: .cuisineCode)
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName)
        placeAddress = try c.decodeIfPresent(String.self, forKey: .placeAddress)
        placeLat = try c.decodeIfPresent(Double.self, forKey: .placeLat)
        placeLng = try c.decodeIfPresent(Double.self, forKey: .placeLng)
    }

    /// The dinner pick this message carries, if any.
    var pick: DinnerPick? {
        guard let cuisineCode else { return nil }
        return DinnerPick(cuisineCode: cuisineCode, placeName: placeName, placeAddress: placeAddress,
                          placeLat: placeLat, placeLng: placeLng)
    }
}

/// "Ethiopian tonight?" — optionally "at Walia, 12 Main St". The restaurant's
/// coordinates are the business's, never the poster's.
struct DinnerPick: Codable, Hashable {
    var cuisineCode: String
    var placeName: String?
    var placeAddress: String?
    var placeLat: Double?
    var placeLng: Double?

    var hasPlace: Bool { !(placeName ?? "").trimmed.isEmpty }
    var hasCoordinate: Bool { placeLat != nil && placeLng != nil }

    /// What older clients and push previews show.
    var fallbackText: String {
        let cuisine = "\(Country.flag(for: cuisineCode)) \(Cuisine.name(for: cuisineCode))"
        if let placeName, hasPlace { return "\(cuisine) at \(placeName)?" }
        return "🎲 The globe says \(cuisine) tonight"
    }
}

struct PostComment: Codable, Identifiable, Hashable {
    let id: UUID
    let postId: UUID
    let authorId: UUID
    var parentId: UUID?
    var text: String
    let createdAt: Date
}

struct PostReaction: Codable, Hashable {
    let postId: UUID
    let userId: UUID
    let emoji: String
}

/// An emoji reaction on a meal (entry_reactions).
struct Reaction: Codable, Hashable {
    let entryId: UUID
    let userId: UUID
    let emoji: String
    let createdAt: Date?
}

/// A comment on a meal (entry_comments).
struct Comment: Codable, Identifiable, Hashable {
    let id: UUID
    let entryId: UUID
    let authorId: UUID
    var text: String
    let createdAt: Date
}

struct Follow: Codable, Hashable {
    let followerId: UUID
    let followeeId: UUID
    let createdAt: Date
}

/// A row from the my_activity() RPC.
struct ActivityRow: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case follow, reaction, comment }

    let kind: Kind
    let actorId: UUID
    let entryId: UUID?
    let emoji: String?
    let body: String?
    let createdAt: Date

    var id: String {
        "\(kind.rawValue)|\(actorId.uuidString)|\(entryId?.uuidString ?? "")|\(emoji ?? "")|\(createdAt.timeIntervalSince1970)"
    }
}

/// Tallied emoji on a meal or message: most-used first, then stable.
struct ReactionTally: Identifiable, Hashable {
    let emoji: String
    let count: Int
    let mine: Bool
    var id: String { emoji }

    static func tally(_ pairs: [(emoji: String, userId: UUID)], me: UUID?) -> [ReactionTally] {
        Dictionary(grouping: pairs, by: \.emoji)
            .map { ReactionTally(emoji: $0.key, count: $0.value.count,
                                 mine: $0.value.contains { $0.userId == me }) }
            .sorted { ($0.count, $1.emoji) > ($1.count, $0.emoji) }
    }
}

// ── Copy ────────────────────────────────────────────────────────────────────

extension Int {
    /// "1 country" / "3 countries" — never "1 countries".
    func counted(_ singular: String, _ plural: String? = nil) -> String {
        "\(self.formatted()) \(self == 1 ? singular : (plural ?? singular + "s"))"
    }
}

// ── Dates ───────────────────────────────────────────────────────────────────

/// Calendar days as Postgres `date` strings, Gregorian in the device's time
/// zone: a meal from "12 April" stays on 12 April.
enum DayFormat {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedCalendar = Calendar(identifier: .gregorian)

    /// Gregorian in `zone` — by default the zone the device is in *now*. A
    /// formatter built once kept the launch zone, so after a flight the date
    /// picker and the saved day disagreed by one.
    static func calendar(in zone: TimeZone = .current) -> Calendar {
        lock.lock(); defer { lock.unlock() }
        if cachedCalendar.timeZone != zone { cachedCalendar.timeZone = zone }
        return cachedCalendar
    }

    static func string(from date: Date, in zone: TimeZone = .current) -> String {
        let parts = calendar(in: zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    static func date(from string: String, in zone: TimeZone = .current) -> Date? {
        let fields = string.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return date(year: fields[0], month: fields[1], day: fields[2], in: zone)
    }

    /// That moment on the wall clock, or nil for times that don't exist (Feb 30).
    static func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0,
                     in zone: TimeZone = .current) -> Date? {
        let gregorian = calendar(in: zone)
        let wanted = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard wanted.isValidDate(in: gregorian) else { return nil }
        return gregorian.date(from: wanted)
    }

    /// "12 Apr 2024"
    static func pretty(_ raw: String) -> String {
        guard let date = date(from: raw) else { return raw }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// "Apr 2024"
    static func monthYear(_ raw: String) -> String {
        guard let date = date(from: raw) else { return raw }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}
