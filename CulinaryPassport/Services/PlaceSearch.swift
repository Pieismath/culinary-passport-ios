import Foundation
import MapKit
import CoreLocation

/// A resolved place: usually the restaurant a meal was at.
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

    /// Restaurants serving a cuisine near a point — what a spin shows once
    /// the globe lands. Apple Maps understands "Georgian restaurant".
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
