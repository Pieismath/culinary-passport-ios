import Foundation

// The planning half of the passport. A trip is where you're going, roughly
// when, who with, and the places you've saved for it; once the dates pass,
// the memories you posted in that window *are* the trip. Nothing to migrate
// when you get home — see `covers(_:)`.

/// A trip you're planning (`trip_plans`).
struct TripPlan: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var name: String
    var countryCodes: [String]
    /// yyyy-MM-dd, both optional — "someday, Japan" is a valid plan.
    var startsOn: String?
    var endsOn: String?
    /// Planning with the people you're going with.
    var groupId: UUID?
    var notes: String
    let createdAt: Date

    init(id: UUID, userId: UUID, name: String, countryCodes: [String], startsOn: String?,
         endsOn: String?, groupId: UUID?, notes: String, createdAt: Date) {
        self.id = id
        self.userId = userId
        self.name = name
        self.countryCodes = countryCodes
        self.startsOn = startsOn
        self.endsOn = endsOn
        self.groupId = groupId
        self.notes = notes
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userId = try c.decode(UUID.self, forKey: .userId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        countryCodes = try c.decodeIfPresent([String].self, forKey: .countryCodes) ?? []
        startsOn = try c.decodeIfPresent(String.self, forKey: .startsOn)
        endsOn = try c.decodeIfPresent(String.self, forKey: .endsOn)
        groupId = try c.decodeIfPresent(UUID.self, forKey: .groupId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    var countries: [Country] { countryCodes.compactMap { CountryStore.byCode[$0] } }
    var flags: String { countryCodes.map(Country.flag(for:)).joined(separator: " ") }

    /// What you called it, or the countries you're going to.
    var title: String {
        if !name.trimmed.isEmpty { return name }
        let names = countries.map(\.name)
        switch names.count {
        case 0: return "Somewhere new"
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) +\(names.count - 2)"
        }
    }

    var start: Date? { startsOn.flatMap { DayFormat.date(from: $0) } }
    var end: Date? { endsOn.flatMap { DayFormat.date(from: $0) } ?? start }

    /// "12 – 19 Apr 2027", or nil while it's still "someday".
    var dateRangeText: String? {
        guard let startsOn else { return nil }
        return DateRange.text(from: startsOn, to: endsOn ?? startsOn)
    }

    var days: Int? {
        guard let start, let end else { return nil }
        return (DayFormat.calendar().dateComponents([.day], from: start, to: end).day ?? 0) + 1
    }

    /// Where this trip sits relative to today.
    enum Phase: Equatable { case someday, upcoming(days: Int), now(day: Int, of: Int), past }

    func phase(on today: Date = Date()) -> Phase {
        guard let start, let end else { return .someday }
        let calendar = DayFormat.calendar()
        let day = calendar.startOfDay(for: today)
        if day < start {
            return .upcoming(days: calendar.dateComponents([.day], from: day, to: start).day ?? 0)
        }
        if day <= end {
            let elapsed = (calendar.dateComponents([.day], from: start, to: day).day ?? 0) + 1
            return .now(day: elapsed, of: days ?? elapsed)
        }
        return .past
    }

    /// "In 24 days" · "Day 3 of 10" · "Someday"
    func countdownText(on today: Date = Date()) -> String {
        switch phase(on: today) {
        case .someday: "Someday"
        case .upcoming(let days) where days <= 1: days <= 0 ? "Starts today" : "Tomorrow"
        case .upcoming(let days): "In \(days) days"
        case .now(let day, let total): "Day \(day) of \(total)"
        case .past: "Been"
        }
    }

    var isOver: Bool { phase() == .past }

    /// Whether a memory belongs to this trip: posted in its window (a day
    /// either side, for flights that land after midnight) and in one of its
    /// countries. A trip with no dates never claims one.
    func covers(_ memory: Memory) -> Bool {
        guard let start, let end, let day = memory.day else { return false }
        let calendar = DayFormat.calendar()
        guard day >= calendar.date(byAdding: .day, value: -1, to: start) ?? start,
              day <= calendar.date(byAdding: .day, value: 1, to: end) ?? end else { return false }
        return countryCodes.isEmpty || countryCodes.contains(memory.countryCode)
    }
}

struct NewTripPlan: Encodable {
    let id: UUID
    let userId: UUID
    var name: String
    var countryCodes: [String]
    var startsOn: String?
    var endsOn: String?
    var groupId: UUID?
    var notes: String
}

/// Full replacement of the editable fields; nil dates and group are cleared.
struct TripPlanPatch: Encodable {
    var name: String
    var countryCodes: [String]
    var startsOn: String?
    var endsOn: String?
    var groupId: UUID?
    var notes: String

    enum CodingKeys: String, CodingKey { case name, countryCodes, startsOn, endsOn, groupId, notes }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(countryCodes, forKey: .countryCodes)
        try c.encode(startsOn, forKey: .startsOn)
        try c.encode(endsOn, forKey: .endsOn)
        try c.encode(groupId, forKey: .groupId)
        try c.encode(notes, forKey: .notes)
    }
}

/// Somewhere you want to go (`saved_places`) — from a friend's memory, from
/// Discover, or from a map search.
struct SavedPlace: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var tripId: UUID?
    var countryCode: String
    var title: String
    var city: String
    var lat: Double?
    var lng: Double?
    var note: String
    /// The memory this idea came from, so it can credit whoever posted it.
    var sourceEntryId: UUID?
    var done: Bool
    let createdAt: Date
    /// What a restaurant serves (GE for a Georgian place in San Francisco);
    /// countryCode is where it is.
    var cuisineCode: String?

    init(id: UUID, userId: UUID, tripId: UUID?, countryCode: String, title: String, city: String,
         lat: Double?, lng: Double?, note: String, sourceEntryId: UUID?, done: Bool, createdAt: Date,
         cuisineCode: String? = nil) {
        self.cuisineCode = cuisineCode
        self.id = id
        self.userId = userId
        self.tripId = tripId
        self.countryCode = countryCode
        self.title = title
        self.city = city
        self.lat = lat
        self.lng = lng
        self.note = note
        self.sourceEntryId = sourceEntryId
        self.done = done
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        userId = try c.decode(UUID.self, forKey: .userId)
        tripId = try c.decodeIfPresent(UUID.self, forKey: .tripId)
        countryCode = try c.decode(String.self, forKey: .countryCode)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        lat = try c.decodeIfPresent(Double.self, forKey: .lat)
        lng = try c.decodeIfPresent(Double.self, forKey: .lng)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        sourceEntryId = try c.decodeIfPresent(UUID.self, forKey: .sourceEntryId)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        cuisineCode = try c.decodeIfPresent(String.self, forKey: .cuisineCode)
    }

    var country: Country? { CountryStore.byCode[countryCode] }
    var isRestaurant: Bool { cuisineCode != nil }
    var displayTitle: String { title.isEmpty ? (city.isEmpty ? country?.name ?? countryCode : city) : title }

    /// "Kyoto, Japan" — omits whatever the title already says.
    var placeLine: String {
        var parts: [String] = []
        if !city.isEmpty, city != title { parts.append(city) }
        parts.append(country?.name ?? countryCode)
        return parts.joined(separator: ", ")
    }

    var hasCoordinate: Bool { lat != nil && lng != nil }
}

struct NewSavedPlace: Encodable {
    let id: UUID
    let userId: UUID
    var tripId: UUID?
    var countryCode: String
    var cuisineCode: String?
    var title: String
    var city: String
    var lat: Double?
    var lng: Double?
    var note: String
    var sourceEntryId: UUID?
}

struct SavedPlacePatch: Encodable {
    var tripId: UUID?
    var title: String
    var city: String
    var note: String
    var done: Bool

    enum CodingKeys: String, CodingKey { case tripId, title, city, note, done }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tripId, forKey: .tripId)
        try c.encode(title, forKey: .title)
        try c.encode(city, forKey: .city)
        try c.encode(note, forKey: .note)
        try c.encode(done, forKey: .done)
    }
}

/// Human date ranges, shared by planned trips and the chapters they become.
enum DateRange {
    /// "Apr 6 – 21, 2027", "28 Mar – 3 Apr 2027", "Dec 2026 – Jan 2027" —
    /// written the way the reader's locale writes a date range.
    static func text(from start: String, to end: String) -> String {
        guard let s = DayFormat.date(from: start), let e = DayFormat.date(from: end) else { return start }
        let calendar = DayFormat.calendar()
        if calendar.isDate(s, inSameDayAs: e) || e < s {
            return s.formatted(.dateTime.day().month(.abbreviated).year())
        }
        if calendar.component(.year, from: s) != calendar.component(.year, from: e) {
            // Months apart: months and years read better than two full dates.
            return "\(s.formatted(.dateTime.month(.abbreviated).year())) – \(e.formatted(.dateTime.month(.abbreviated).year()))"
        }
        return (s..<e).formatted(.interval.day().month(.abbreviated).year())
    }
}
