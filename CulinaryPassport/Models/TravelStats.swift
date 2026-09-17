import Foundation

/// The numbers on a passport, derived from stamps + memories. Pure and cheap —
/// computed on demand, never stored.
struct TravelStats: Equatable {
    /// Sovereign countries stamped (the headline number).
    var countries = 0
    /// Territories stamped (Hong Kong, Puerto Rico, Antarctica…).
    var territories = 0
    var continents = 0
    var cities = 0
    var memories = 0
    var photos = 0
    var continentProgress: [Continent: (visited: Int, total: Int)] = [:]

    var worldFraction: Double {
        guard CountryStore.sovereignCount > 0 else { return 0 }
        return min(1, Double(countries) / Double(CountryStore.sovereignCount))
    }

    var worldPercentText: String {
        let pct = worldFraction * 100
        if pct > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }

    init() {}

    init(stamps: [Stamp], memories: [Memory]) {
        let codes = Set(stamps.map(\.countryCode))
        let places = codes.compactMap { CountryStore.byCode[$0] }
        countries = places.filter(\.isSovereign).count
        territories = places.count - countries
        continents = Set(places.map(\.continent)).count
        cities = Self.cityCount(memories)
        self.memories = memories.count
        photos = memories.reduce(0) { $0 + $1.photos.count }
        for continent in Continent.allCases {
            let all = CountryStore.byContinent(continent)
            let visited = all.filter { codes.contains($0.code) }.count
            continentProgress[continent] = (visited, all.count)
        }
    }

    static func == (lhs: TravelStats, rhs: TravelStats) -> Bool {
        lhs.countries == rhs.countries && lhs.territories == rhs.territories
            && lhs.continents == rhs.continents && lhs.cities == rhs.cities
            && lhs.memories == rhs.memories && lhs.photos == rhs.photos
    }

    /// Distinct city+country pairs (so "Paris, FR" and "Paris, US" differ).
    static func cityCount(_ memories: [Memory]) -> Int {
        Set(memories.compactMap { m -> String? in
            guard let city = m.city?.trimmingCharacters(in: .whitespaces), !city.isEmpty else { return nil }
            return "\(city.lowercased())|\(m.countryCode)"
        }).count
    }

    /// Countries first visited in `year` — the "new countries this year" goal.
    static func newCountries(in year: Int, stamps: [Stamp]) -> [Stamp] {
        let prefix = String(year)
        return stamps.filter { $0.firstVisited?.hasPrefix(prefix) == true }
            .sorted { ($0.firstVisited ?? "") < ($1.firstVisited ?? "") }
    }
}

/// A run of memories close together in time — "Japan, Apr 2024". Chapters are
/// inferred, never stored: nobody has to plan a trip before posting. When a
/// plan does cover them, it lends its name (see TripPlan.covers).
struct Trip: Identifiable, Hashable {
    let memories: [Memory]           // oldest → newest
    let countryCodes: [String]       // in the order they were visited
    var plan: TripPlan?

    var id: String { memories.first.map { $0.id.uuidString } ?? UUID().uuidString }
    var start: String { memories.first?.date ?? "" }
    var end: String { memories.last?.date ?? "" }
    var coverPhoto: String? { memories.lazy.compactMap(\.photos.first).first }
    var photoCount: Int { memories.reduce(0) { $0 + $1.photos.count } }

    var title: String {
        if let named = plan?.name.trimmed, !named.isEmpty { return named }
        let names = countryCodes.compactMap { CountryStore.byCode[$0]?.name }
        switch names.count {
        case 0: return "Trip"
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) +\(names.count - 2)"
        }
    }

    var flags: String { countryCodes.map(Country.flag(for:)).joined(separator: " ") }

    /// "12 – 19 Apr 2024", "28 Mar – 3 Apr 2024", "Dec 2023 – Jan 2024"
    var dateRangeText: String { DateRange.text(from: start, to: end) }

    var days: Int {
        guard let s = DayFormat.date(from: start), let e = DayFormat.date(from: end) else { return 1 }
        return (DayFormat.calendar().dateComponents([.day], from: s, to: e).day ?? 0) + 1
    }
}

enum TripBuilder {
    /// Group memories into trips: sorted by date, a new trip starts after a
    /// gap of more than `maxGapDays` between consecutive memories (people
    /// don't post every day of a trip — a week of silence is still the same
    /// trip). Newest trip first.
    static func trips(from memories: [Memory], plans: [TripPlan] = [], maxGapDays: Int = 7) -> [Trip] {
        let sorted = memories.sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
        var trips: [[Memory]] = []
        var lastDay: Date?
        for memory in sorted {
            let day = memory.day
            if let lastDay, let day,
               let gap = DayFormat.calendar().dateComponents([.day], from: lastDay, to: day).day,
               gap <= maxGapDays, !trips.isEmpty {
                trips[trips.count - 1].append(memory)
            } else {
                trips.append([memory])
            }
            lastDay = day ?? lastDay
        }
        return trips.reversed().map { group in
            var order: [String] = []
            for m in group where !order.contains(m.countryCode) { order.append(m.countryCode) }
            // The plan that covers most of this chapter named it.
            let plan = plans
                .map { plan in (plan, group.filter(plan.covers).count) }
                .filter { $0.1 * 2 > group.count }
                .max { $0.1 < $1.1 }?.0
            return Trip(memories: group, countryCodes: order, plan: plan)
        }
    }
}

enum Geo {
    /// Great-circle distance in kilometres (haversine).
    static func distanceKm(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Distance along memories in date order, using each memory's coordinates
    /// (or its country's centroid when it has none). A lower bound on how far
    /// you went — it's the journey between the places you recorded.
    static func journeyKm(_ memories: [Memory]) -> Double {
        let points: [(Double, Double)] = memories
            .sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
            .compactMap { m in
                if let lat = m.lat, let lng = m.lng { return (lat, lng) }
                return m.country.map { ($0.centroid.lat, $0.centroid.lng) }
            }
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += distanceKm(points[i - 1].0, points[i - 1].1, points[i].0, points[i].1)
        }
        return total
    }
}

/// Year in review, from the user's own stamps + memories.
struct YearInReview {
    let year: Int
    let countries: [String]          // visited this year, in order
    let newCountries: [String]       // first-ever visits this year
    let cities: Int
    let memories: Int
    let photos: Int
    let continents: Int
    let distanceKm: Double
    let trips: [Trip]
    let topCountry: (code: String, memories: Int)?

    var isEmpty: Bool { countries.isEmpty && memories == 0 }

    init(year: Int, stamps: [Stamp], memories allMemories: [Memory]) {
        self.year = year
        let prefix = String(year)
        let yearly = allMemories.filter { $0.date.hasPrefix(prefix) }
            .sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }

        var ordered: [String] = []
        for m in yearly where !ordered.contains(m.countryCode) { ordered.append(m.countryCode) }
        // Stamps whose visit window touches this year but have no memories
        // (photo import) still count as places you were.
        for stamp in stamps.sorted(by: { ($0.firstVisited ?? "") < ($1.firstVisited ?? "") }) {
            let first = stamp.firstVisited.flatMap { Int($0.prefix(4)) }
            let last = stamp.lastVisited.flatMap { Int($0.prefix(4)) } ?? first
            if let first, let last, first <= year, year <= last, !ordered.contains(stamp.countryCode) {
                ordered.append(stamp.countryCode)
            }
        }
        countries = ordered
        newCountries = TravelStats.newCountries(in: year, stamps: stamps).map(\.countryCode)
        cities = TravelStats.cityCount(yearly)
        memories = yearly.count
        photos = yearly.reduce(0) { $0 + $1.photos.count }
        continents = Set(ordered.compactMap { CountryStore.byCode[$0]?.continent }).count
        distanceKm = Geo.journeyKm(yearly)
        trips = TripBuilder.trips(from: yearly)
        topCountry = Dictionary(grouping: yearly, by: \.countryCode)
            .map { (code: $0.key, memories: $0.value.count) }
            .max { ($0.memories, $1.code) < ($1.memories, $0.code) }
    }

    /// Years worth offering in the picker: any year with memories or visits.
    static func availableYears(stamps: [Stamp], memories: [Memory]) -> [Int] {
        var years = Set(memories.compactMap { Int($0.date.prefix(4)) })
        for stamp in stamps {
            if let f = stamp.firstVisited.flatMap({ Int($0.prefix(4)) }) { years.insert(f) }
            if let l = stamp.lastVisited.flatMap({ Int($0.prefix(4)) }) { years.insert(l) }
        }
        years.insert(Calendar.current.component(.year, from: Date()))
        return years.sorted(by: >)
    }
}
