import Foundation
import MapKit
import CoreLocation

/// A resolved place for a memory.
struct PlaceResult: Equatable {
    var title: String
    var city: String
    var countryCode: String?
    var latitude: Double?
    var longitude: Double?
}

/// Place autocomplete on Apple Maps — free, no API key, no proxy. (The
/// restaurant-era Google Places proxy billed per request.)
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet {
            let trimmed = query.trimmed
            if trimmed.count < 2 {
                results = []
                completer.cancel()
            } else {
                completer.queryFragment = trimmed
            }
        }
    }
    var results: [MKLocalSearchCompletion] = []
    var failed = false

    private let completer = MKLocalSearchCompleter()

    /// `foodOnly` narrows to places that serve food, searched around the
    /// neighbourhood rather than the country — for logging a meal.
    init(near coordinate: CLLocationCoordinate2D? = nil, foodOnly: Bool = false) {
        super.init()
        completer.delegate = self
        if foodOnly {
            completer.resultTypes = .pointOfInterest
            completer.pointOfInterestFilter = PlaceSearch.foodFilter
        } else {
            completer.resultTypes = [.pointOfInterest, .address]
        }
        if let coordinate {
            let span = foodOnly ? 0.4 : 12
            completer.region = MKCoordinateRegion(center: coordinate,
                                                  span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
        }
    }

    static let foodFilter = MKPointOfInterestFilter(including: [
        .restaurant, .cafe, .bakery, .brewery, .winery, .foodMarket, .nightlife,
    ])

    /// Restaurants serving a cuisine near a point — what the dinner dice
    /// shows once it lands. Apple Maps understands "Georgian restaurant".
    static func restaurants(serving code: String, near coordinate: CLLocationCoordinate2D,
                            limit: Int = 8) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(Cuisine.name(for: code)) restaurant"
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = foodFilter
        request.region = MKCoordinateRegion(center: coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35))
        // The region is only a hint by default — "Moroccan restaurant" near
        // San Francisco came back from Delaware.
        if #available(iOS 18.0, *) { request.regionPriority = .required }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return Array(response.mapItems
            .compactMap { item -> (MKMapItem, CLLocationDistance)? in
                guard let there = item.placemark.location else { return nil }
                let distance = there.distance(from: here)
                return distance <= maxDinnerDistance ? (item, distance) : nil
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
            .prefix(limit))
    }

    /// Dinner tonight means somewhere you can get to tonight.
    static let maxDinnerDistance: CLLocationDistance = 40_000

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let fresh = completer.results
        MainActor.assumeIsolated {
            results = Array(fresh.prefix(12))
            failed = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { failed = true }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> PlaceResult {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response.mapItems.first else { throw AppError("Couldn't find that place.") }
        var result = Self.result(from: item.placemark, name: item.name)
        if result.title.isEmpty { result.title = completion.title }
        return result
    }

    /// "Where was this photo taken?" — on-device reverse geocoding. The
    /// country comes from our own polygons first (offline, consistent with the
    /// globe), the name and city from Apple Maps.
    ///
    /// The coordinates saved with the memory are rounded to ~1 km: a photo's
    /// GPS can be someone's front door, and friends can read a memory's
    /// coordinates. (Places picked from search are public, so they stay exact.)
    static func reverseGeocode(latitude: Double, longitude: Double) async -> PlaceResult {
        var result = PlaceResult(title: "", city: "",
                                 countryCode: PlaceLocator.country(lat: latitude, lng: longitude),
                                 latitude: coarse(latitude), longitude: coarse(longitude))
        let location = CLLocation(latitude: latitude, longitude: longitude)
        if let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let named = Self.result(from: placemark, name: nil)
            result.city = named.city
            // Prefer Apple's ISO code when it names a place we know.
            if let code = named.countryCode, CountryStore.byCode[code] != nil {
                result.countryCode = code
            }
            if let poi = placemark.areasOfInterest?.first { result.title = poi }
        }
        return result
    }

    /// Two decimal places ≈ 1.1 km.
    nonisolated static func coarse(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func result(from placemark: CLPlacemark, name: String?) -> PlaceResult {
        let city = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea ?? ""
        var code = placemark.isoCountryCode?.uppercased()
        if let lat = placemark.location?.coordinate.latitude, let lng = placemark.location?.coordinate.longitude,
           let local = PlaceLocator.country(lat: lat, lng: lng), CountryStore.byCode[local]?.hasShape == false {
            // Hong Kong, Macau, Puerto Rico… Apple may report the parent country.
            code = local
        }
        var title = name ?? ""
        if title == city { title = "" }
        return PlaceResult(title: title, city: city, countryCode: code,
                           latitude: placemark.location?.coordinate.latitude,
                           longitude: placemark.location?.coordinate.longitude)
    }
}

/// "On this day": a local notification on the anniversary of a memory.
/// Local notifications need no push entitlement or server.
enum MemoryReminders {
    private static let enabledKey = "reminders.onThisDay"
    private static let prefix = "onthisday-"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Turn reminders on (asking for permission in context) or off.
    @MainActor
    static func setEnabled(_ on: Bool, memories: [Memory]) async -> Bool {
        if on {
            let granted = await PushRegistrar.requestAndRegister()
            isEnabled = granted
            if granted { reschedule(memories: memories) }
            return granted
        }
        isEnabled = false
        cancelAll()
        return false
    }

    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Schedule the next occurrence of each anniversary (one per calendar
    /// day, favouring memories with photos), nearest first, within iOS's cap.
    static func reschedule(memories: [Memory], now: Date = Date()) {
        guard isEnabled else { return }
        let plan = upcoming(memories: memories, now: now, limit: 48)
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let old = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for item in plan {
                let content = UNMutableNotificationContent()
                content.title = "On this day \(item.flag)"
                content.body = item.body
                content.sound = .default
                content.userInfo = ["url": "culinarypassport://memory/\(item.memoryId.uuidString)"]
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                center.add(UNNotificationRequest(identifier: prefix + item.memoryId.uuidString + "-\(parts.year ?? 0)",
                                                 content: content, trigger: trigger))
            }
        }
    }

    struct Planned: Equatable {
        let memoryId: UUID
        let fireDate: Date
        let body: String
        let flag: String
    }

    /// Pure planning step (unit-tested). Each memory's next anniversary is
    /// computed first, so a memory from earlier this year can't claim a day's
    /// slot and crowd out a real anniversary on the same date.
    static func upcoming(memories: [Memory], now: Date, limit: Int) -> [Planned] {
        let calendar = Calendar.current
        var bestPerDay: [String: (memory: Memory, fire: Date, years: Int)] = [:]
        for memory in memories {
            guard let day = memory.day else { continue }
            var parts = calendar.dateComponents([.month, .day], from: day)
            parts.hour = 9
            parts.minute = 0
            guard let next = calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) else { continue }
            let years = calendar.component(.year, from: next) - calendar.component(.year, from: day)
            guard years >= 1 else { continue }
            let key = String(memory.date.dropFirst(5)) // "MM-dd"
            if let current = bestPerDay[key] {
                let better = (memory.photos.isEmpty ? 0 : 1, memory.date) > (current.memory.photos.isEmpty ? 0 : 1, current.memory.date)
                if better { bestPerDay[key] = (memory, next, years) }
            } else {
                bestPerDay[key] = (memory, next, years)
            }
        }
        return bestPerDay.values
            .sorted { $0.fire < $1.fire }
            .prefix(limit)
            .map { item in
                let ago = item.years == 1 ? "A year ago" : "\(item.years) years ago"
                return Planned(memoryId: item.memory.id, fireDate: item.fire,
                               body: "\(ago): \(item.memory.displayTitle), \(item.memory.placeLine)",
                               flag: Country.flag(for: item.memory.countryCode))
            }
    }
}
