import Foundation

/// A restaurant you want to try (`saved_places` with a cuisine) — from a
/// spin, a friend's meal, or a map search. countryCode is where it is;
/// cuisineCode is what it serves (Supra in San Francisco: US, GE).
struct SavedPlace: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    /// Travel-era trip link. Still decoded, never shown or written.
    var tripId: UUID?
    var countryCode: String
    var title: String
    var city: String
    var lat: Double?
    var lng: Double?
    var note: String
    /// The meal this came from, so it can credit whoever ate there.
    var sourceEntryId: UUID?
    var done: Bool
    let createdAt: Date
    var cuisineCode: String?

    init(id: UUID, userId: UUID, tripId: UUID? = nil, countryCode: String, title: String, city: String,
         lat: Double?, lng: Double?, note: String, sourceEntryId: UUID?, done: Bool, createdAt: Date,
         cuisineCode: String? = nil) {
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
        self.cuisineCode = cuisineCode
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

    var isRestaurant: Bool { cuisineCode != nil }
    var displayTitle: String { title.isEmpty ? (city.isEmpty ? "A restaurant" : city) : title }
    var hasCoordinate: Bool { lat != nil && lng != nil }

    /// "🇬🇪 Georgian · San Francisco"
    var cuisineLine: String {
        let place = city.isEmpty ? (CountryStore.byCode[countryCode]?.name ?? "") : city
        guard let cuisineCode else { return place }
        let cuisine = "\(Country.flag(for: cuisineCode)) \(Cuisine.name(for: cuisineCode))"
        return place.isEmpty ? cuisine : "\(cuisine) · \(place)"
    }
}

struct NewSavedPlace: Encodable {
    let id: UUID
    let userId: UUID
    var countryCode: String
    var cuisineCode: String?
    var title: String
    var city: String
    var lat: Double?
    var lng: Double?
    var note: String
    var sourceEntryId: UUID?
}

/// The fields you can edit on a saved restaurant. The trip link isn't one of
/// them, so an edit never touches it.
struct SavedPlacePatch: Encodable {
    var title: String
    var city: String
    var note: String
    var done: Bool
}
