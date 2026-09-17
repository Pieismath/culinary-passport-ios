import Foundation

// Mirrors the Supabase schema (web repo supabase/migrations, travel model in
// 20260917120000_travel_passport.sql). JSON keys are snake_case on the wire;
// the shared decoder converts them, so CodingKeys below use camelCase raw
// values where a Swift name differs from the column's.

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
    /// "How many NEW countries this year?" Nil = not set.
    var yearlyGoal: Int?

    var handle: String? { username.flatMap { $0.isEmpty ? nil : "@\($0)" } }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// Who can see a memory. The raw value `groups` predates the travel app; it
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
        case .private: "Just you. It still stamps your passport."
        }
    }
}

/// A travel moment: photos, a place, a date, a few words. Stored as an
/// `entries` row with kind = 'memory'.
struct Memory: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
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

    enum CodingKeys: String, CodingKey {
        case id, userId, countryCode, title, city, notes, photos, lat, lng, visibility, createdAt
        case date = "dateTried"
    }

    init(id: UUID, userId: UUID, countryCode: String, title: String, city: String?,
         date: String, notes: String?, photos: [String], lat: Double?, lng: Double?,
         visibility: Visibility, createdAt: Date) {
        self.id = id
        self.userId = userId
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

    /// "Fushimi Inari" / "Kyoto" / "Japan" — the best short name we have.
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if let city, !city.isEmpty { return city }
        return country?.name ?? countryCode
    }

    /// "Kyoto, Japan" — omits whatever the title already says.
    var placeLine: String {
        var parts: [String] = []
        if let city, !city.isEmpty, city != title { parts.append(city) }
        parts.append(country?.name ?? countryCode)
        return parts.joined(separator: ", ")
    }

    var day: Date? { DayFormat.date(from: date) }
    var hasCoordinate: Bool { lat != nil && lng != nil }

    /// Whether this row already holds every field of `patch` (an update whose
    /// response was lost may still have landed).
    func matches(_ patch: MemoryPatch) -> Bool {
        countryCode == patch.countryCode && title == patch.title && (city ?? "") == patch.city
            && String(date.prefix(10)) == patch.dateTried && (notes ?? "") == patch.notes
            && photos == patch.photos && lat == patch.lat && lng == patch.lng
            && visibility.rawValue == patch.visibility
    }
}

/// Insert payload. The id is chosen on the device so a retried save can't
/// land twice; created_at comes from Postgres.
struct NewMemory: Encodable {
    let id: UUID
    let userId: UUID
    let kind = "memory"
    var countryCode: String
    var title: String
    var city: String
    var dateTried: String
    var notes: String
    var photos: [String]
    var lat: Double?
    var lng: Double?
    var visibility: String
}

/// Full replacement of the editable fields. Encodes nil coordinates as
/// explicit nulls — clearing a place must clear the stored coordinates too.
struct MemoryPatch: Encodable {
    var countryCode: String
    var title: String
    var city: String
    var dateTried: String
    var notes: String
    var photos: [String]
    var lat: Double?
    var lng: Double?
    var visibility: String

    enum CodingKeys: String, CodingKey {
        case countryCode, title, city, dateTried, notes, photos, lat, lng, visibility
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
    }
}

/// A passport stamp: "been to this country", with or without memories.
struct Stamp: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case manual, photos, memory }

    let userId: UUID
    let countryCode: String
    var firstVisited: String?
    var lastVisited: String?
    var source: Source
    let createdAt: Date

    var id: String { "\(userId.uuidString)|\(countryCode)" }
    var country: Country? { CountryStore.byCode[countryCode] }

    /// "2019" or "2019 – 2024", nil when we don't know.
    var yearsText: String? {
        let first = firstVisited.map { String($0.prefix(4)) }
        let last = lastVisited.map { String($0.prefix(4)) }
        switch (first, last) {
        case let (f?, l?) where f != l: return "\(f) – \(l)"
        case let (f?, _): return f
        case let (nil, l?): return l
        default: return nil
        }
    }
}

/// One stamp to add in bulk (checklist / photo import).
struct StampInput: Codable, Hashable {
    var countryCode: String
    var firstVisited: String?
    var lastVisited: String?
    var source: Stamp.Source
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

struct GroupPost: Codable, Identifiable, Hashable {
    let id: UUID
    let groupId: UUID
    let authorId: UUID
    /// A shared memory (group_posts.entry_id).
    var entryId: UUID?
    var text: String
    var photos: [String]
    let createdAt: Date
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

/// An emoji reaction on a memory (entry_reactions).
struct Reaction: Codable, Hashable {
    let entryId: UUID
    let userId: UUID
    let emoji: String
    let createdAt: Date?
}

/// A comment on a memory (entry_comments).
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

/// Tallied emoji on a memory or message: most-used first, then stable.
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
/// zone: a memory from "12 April" stays on 12 April.
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
