import Foundation

// A camera roll is already a travel diary — it just isn't sorted. This turns
// located photos into trips and the places inside them, so a decade of
// travel can land in the passport without anyone typing a word.
//
// Pure functions over plain values: the library scan collects the photos, this
// decides what they mean, and the tests can run the whole thing offline.

/// One photo with a place and a time — all the scan keeps per asset.
struct LocatedPhoto: Hashable {
    let id: String
    let date: Date
    let lat: Double
    let lng: Double
    let countryCode: String
}

/// Somewhere you stopped on a trip: a cluster of photos around one place.
struct PhotoStop: Identifiable, Hashable {
    let id = UUID()
    var countryCode: String
    var lat: Double
    var lng: Double
    var first: Date
    var last: Date
    var photoCount: Int
    var sampleIds: [String]
    /// Filled in later by reverse geocoding; empty when offline.
    var city = ""

    var country: Country? { CountryStore.byCode[countryCode] }
    var title: String { city.isEmpty ? (country?.name ?? countryCode) : city }
}

/// A run of photos away from home: one trip, in the places you took them.
struct PhotoTrip: Identifiable, Hashable {
    let id = UUID()
    var stops: [PhotoStop]           // chronological
    var countryCodes: [String]       // in the order they were visited

    var first: Date { stops.first?.first ?? .distantPast }
    var last: Date { stops.map(\.last).max() ?? first }
    var photoCount: Int { stops.reduce(0) { $0 + $1.photoCount } }
    var sampleIds: [String] { stops.flatMap(\.sampleIds) }
    var flags: String { countryCodes.map(Country.flag(for:)).joined(separator: " ") }

    /// "Japan & South Korea" — the trip's own name comes later, if you give it one.
    var title: String {
        let names = countryCodes.compactMap { CountryStore.byCode[$0]?.name }
        switch names.count {
        case 0: return "Trip"
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) +\(names.count - 2)"
        }
    }

    var dateRangeText: String {
        DateRange.text(from: DayFormat.string(from: first), to: DayFormat.string(from: last))
    }

    var days: Int {
        (DayFormat.calendar().dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }
}

enum PhotoTripBuilder {
    /// A new trip starts after this long without a located photo.
    static let gapDays = 4
    /// Photos nearer than this to each other are the same stop…
    static let stopRadiusKm = 30.0
    /// …and nearer than this to home aren't a trip at all.
    static let homeRadiusKm = 120.0
    /// Below these, it's a stray photo rather than a trip worth adding.
    static let minPhotos = 5
    static let minStopPhotos = 3
    /// Keep a trip's biggest stops; the rest fold into the nearest kept one.
    static let maxStops = 6

    /// Where the traveller lives, guessed from where they photograph most
    /// days. Used to keep everyday life out of the passport.
    static func home(in photos: [LocatedPhoto]) -> (lat: Double, lng: Double)? {
        guard !photos.isEmpty else { return nil }
        var clusters: [(lat: Double, lng: Double, days: Set<String>, count: Int)] = []
        for photo in photos {
            let day = DayFormat.string(from: photo.date)
            if let index = clusters.firstIndex(where: {
                Geo.distanceKm($0.lat, $0.lng, photo.lat, photo.lng) <= homeRadiusKm
            }) {
                clusters[index].days.insert(day)
                clusters[index].count += 1
            } else {
                clusters.append((photo.lat, photo.lng, [day], 1))
            }
        }
        // Home is where you shoot on the most *different days* — a two-week
        // holiday can easily out-photograph a year of home life.
        return clusters.max { ($0.days.count, $0.count) < ($1.days.count, $1.count) }
            .map { ($0.lat, $0.lng) }
    }

    /// Group located photos into trips. Photos near `home` are skipped, so
    /// weekends at home don't become chapters.
    static func trips(from photos: [LocatedPhoto], home: (lat: Double, lng: Double)?) -> [PhotoTrip] {
        let away = photos
            .filter { photo in
                guard let home else { return true }
                return Geo.distanceKm(home.lat, home.lng, photo.lat, photo.lng) > homeRadiusKm
            }
            .sorted { $0.date < $1.date }
        guard !away.isEmpty else { return [] }

        var runs: [[LocatedPhoto]] = []
        for photo in away {
            if let last = runs.last?.last,
               photo.date.timeIntervalSince(last.date) <= Double(gapDays) * 86_400 {
                runs[runs.count - 1].append(photo)
            } else {
                runs.append([photo])
            }
        }

        return runs.compactMap { run -> PhotoTrip? in
            guard run.count >= minPhotos else { return nil }
            let stops = self.stops(in: run)
            guard !stops.isEmpty else { return nil }
            var order: [String] = []
            for stop in stops where !order.contains(stop.countryCode) { order.append(stop.countryCode) }
            return PhotoTrip(stops: stops, countryCodes: order)
        }
        .sorted { $0.first > $1.first }        // newest trip first
    }

    /// The places inside one trip: greedy clusters within `stopRadiusKm`,
    /// biggest first, each one keeping a few photos to show.
    static func stops(in run: [LocatedPhoto]) -> [PhotoStop] {
        var clusters: [[LocatedPhoto]] = []
        for photo in run {
            if let index = clusters.firstIndex(where: { cluster in
                guard let first = cluster.first, first.countryCode == photo.countryCode else { return false }
                return Geo.distanceKm(first.lat, first.lng, photo.lat, photo.lng) <= stopRadiusKm
            }) {
                clusters[index].append(photo)
            } else {
                clusters.append([photo])
            }
        }

        let kept = clusters
            .filter { $0.count >= minStopPhotos }
            .sorted { $0.count > $1.count }
            .prefix(maxStops)

        return kept
            .map { cluster -> PhotoStop in
                let dates = cluster.map(\.date)
                return PhotoStop(
                    countryCode: cluster[0].countryCode,
                    lat: cluster.map(\.lat).reduce(0, +) / Double(cluster.count),
                    lng: cluster.map(\.lng).reduce(0, +) / Double(cluster.count),
                    first: dates.min() ?? Date(),
                    last: dates.max() ?? Date(),
                    photoCount: cluster.count,
                    sampleIds: PhotoLibraryScanner.sample(cluster.map(\.id), count: 6)
                )
            }
            .sorted { $0.first < $1.first }    // visited in order
    }
}
