import Foundation
import Photos
import ImageIO
import CoreLocation
import UIKit

/// Where and when a photo was taken.
struct PhotoMetadata: Equatable {
    var latitude: Double?
    var longitude: Double?
    var date: Date?

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// EXIF/GPS straight from the image bytes (what PhotosPicker hands us).
    static func read(from data: Data) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return PhotoMetadata()
        }
        var meta = PhotoMetadata()
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lng = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" { lng = -lng }
            if !(lat == 0 && lng == 0) {
                meta.latitude = lat
                meta.longitude = lng
            }
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        if let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String {
            meta.date = exifDate(raw)
        }
        return meta
    }

    /// "2024:04:12 08:03:55" is the clock on the wall where the photo was
    /// taken, with no zone. Read it in the device's zone so it lands on the
    /// same calendar day here — 12 April in Tokyo stays 12 April in New York.
    static func exifDate(_ raw: String, in zone: TimeZone = .current) -> Date? {
        let fields = raw.split(whereSeparator: { ":- T".contains($0) }).prefix(6).compactMap { Int($0) }
        guard fields.count == 6 else { return nil }
        return DayFormat.date(year: fields[0], month: fields[1], day: fields[2],
                              hour: fields[3], minute: fields[4], second: fields[5], in: zone)
    }

    /// Richer metadata from the Photos library when we have access and an
    /// asset id (location survives even when the transferred file lacks EXIF).
    static func read(assetIdentifier: String?) -> PhotoMetadata? {
        guard let assetIdentifier, PhotoLibraryScanner.hasReadAccess,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject
        else { return nil }
        return PhotoMetadata(latitude: asset.location?.coordinate.latitude,
                             longitude: asset.location?.coordinate.longitude,
                             date: asset.creationDate)
    }
}

/// Builds a passport from the photo library: every photo with a location is
/// resolved to a country, on-device. Nothing is uploaded.
@MainActor
@Observable
final class PhotoLibraryScanner {
    enum Phase: Equatable {
        case idle
        case denied
        case scanning
        case finished
    }

    struct Found: Identifiable, Hashable {
        let code: String
        var photoCount: Int
        var first: Date
        var last: Date
        var trips: Int
        /// A few photos to show, spread across visits.
        var samples: [String]
        var id: String { code }
    }

    var phase: Phase = .idle
    private let cancellation = ScanCancellation()
    var scanned = 0
    var total = 0
    var found: [Found] = []
    /// Trips the photos describe — runs away from home, and the places in them.
    var trips: [PhotoTrip] = []

    /// What one scan produced.
    struct Result {
        var found: [Found] = []
        var trips: [PhotoTrip] = []
    }

    nonisolated static var hasReadAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func start(demo: Bool) async {
        if demo {
            await runDemo()
            return
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }
        phase = .scanning
        scanned = 0
        found = []
        let cancellation = cancellation
        let results = await Task.detached(priority: .userInitiated) { [weak self] in
            Self.scanLibrary(cancellation: cancellation) { done, total, snapshot in
                Task { @MainActor in
                    // Progress hops can land after the final result; never
                    // let a stale snapshot overwrite it.
                    guard let self, self.phase == .scanning else { return }
                    self.scanned = done
                    self.total = total
                    self.found = snapshot
                }
            }
        }.value
        found = results.found
        trips = results.trips
        scanned = max(scanned, total)
        phase = .finished
        // Names for the places found, best effort: without a network the trip
        // still lands, just labelled by country.
        await nameStops()
    }

    private func runDemo() async {
        phase = .scanning
        total = 8_412
        let demo: [(String, Int, String, String, Int)] = [
            ("DE", 214, "2019-08-02", "2024-12-18", 3), ("NL", 96, "2021-04-20", "2021-04-26", 1),
            ("CZ", 131, "2022-05-11", "2022-05-15", 1), ("AT", 48, "2022-05-16", "2022-05-18", 1),
            ("HU", 77, "2022-05-19", "2022-05-23", 1), ("FR", 305, "2021-09-10", "2025-04-02", 2),
            ("IT", 262, "2021-09-19", "2025-05-06", 2), ("US", 3_902, "2015-01-01", "2026-09-10", 22),
        ]
        for step in 1...12 {
            try? await Task.sleep(for: .milliseconds(110))
            scanned = total * step / 12
            let visible = demo.prefix(max(1, demo.count * step / 12))
            found = visible.map { code, count, first, last, trips in
                Found(code: code, photoCount: count * step / 12 + 1,
                      first: DayFormat.date(from: first) ?? Date(), last: DayFormat.date(from: last) ?? Date(),
                      trips: trips, samples: [])
            }
        }
        found = demo.map { code, count, first, last, trips in
            Found(code: code, photoCount: count, first: DayFormat.date(from: first) ?? Date(),
                  last: DayFormat.date(from: last) ?? Date(), trips: trips, samples: [])
        }
        trips = Self.demoTrips()
        phase = .finished
    }

    /// Stop a scan in progress (the user left the screen).
    func cancel() {
        cancellation.cancel()
    }

    /// Walks the library oldest → newest. Locations are bucketed into small
    /// cells so the polygon test runs once per place, not once per photo.
    /// Reverse-geocode each stop to a city name, in the order they'd be read.
    /// Apple rate-limits this hard, so it's capped and never blocks the result.
    private func nameStops() async {
        var budget = 40
        for tripIndex in trips.indices {
            for stopIndex in trips[tripIndex].stops.indices where budget > 0 {
                guard !cancellation.isCancelled else { return }
                let stop = trips[tripIndex].stops[stopIndex]
                budget -= 1
                let place = await PlaceSearch.reverseGeocode(latitude: stop.lat, longitude: stop.lng)
                guard !place.city.isEmpty else { continue }
                trips[tripIndex].stops[stopIndex].city = place.city
            }
        }
    }

    nonisolated static func scanLibrary(cancellation: ScanCancellation = ScanCancellation(),
                                        progress: @escaping (Int, Int, [Found]) -> Void) -> Result {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        let total = assets.count

        struct Accumulator {
            var count = 0
            var first = Date.distantFuture
            var last = Date.distantPast
            var tripStarts = 0
            var lastDate: Date?
            var ids: [String] = []
        }
        var byCode: [String: Accumulator] = [:]
        var cellCache: [Int64: String] = [:]
        var missCells = Set<Int64>()
        var located: [LocatedPhoto] = []
        located.reserveCapacity(min(total, 40_000))

        func snapshot() -> [Found] {
            byCode.map { code, acc in
                Found(code: code, photoCount: acc.count, first: acc.first, last: acc.last,
                      trips: max(1, acc.tripStarts), samples: sample(acc.ids, count: 6))
            }
            .sorted { $0.photoCount > $1.photoCount }
        }

        assets.enumerateObjects { asset, index, stop in
            if index % 400 == 0 {
                if cancellation.isCancelled {
                    stop.pointee = true
                    return
                }
                progress(index, total, snapshot())
            }
            guard let location = asset.location else { return }
            let lat = location.coordinate.latitude
            let lng = location.coordinate.longitude
            guard CLLocationCoordinate2DIsValid(location.coordinate), !(lat == 0 && lng == 0) else { return }

            // ~500 m cells. The old 5 km cell let the first photo in a square
            // decide the country for every later one there, so one shot in
            // Rome could keep every Vatican photo out of the Vatican.
            let cell = Int64((lat * 200).rounded()) * 1_000_000 + Int64((lng * 200).rounded())
            let code: String
            if let cached = cellCache[cell] {
                code = cached
            } else if missCells.contains(cell) {
                return
            } else if let resolved = PlaceLocator.country(lat: lat, lng: lng) {
                cellCache[cell] = resolved
                code = resolved
            } else {
                missCells.insert(cell)
                return
            }

            let date = asset.creationDate ?? Date.distantPast
            var acc = byCode[code] ?? Accumulator()
            acc.count += 1
            acc.first = min(acc.first, date)
            acc.last = max(acc.last, date)
            // A gap of more than ten days since the last photo here = a new trip.
            if let previous = acc.lastDate, date.timeIntervalSince(previous) <= 10 * 86_400 {
                // same trip
            } else {
                acc.tripStarts += 1
            }
            acc.lastDate = date
            acc.ids.append(asset.localIdentifier)
            byCode[code] = acc
            located.append(LocatedPhoto(id: asset.localIdentifier, date: date,
                                        lat: lat, lng: lng, countryCode: code))
        }

        let results = snapshot()
        guard !cancellation.isCancelled else { return Result(found: results) }
        LocalPhotoIndex.save(byCode.mapValues { sample($0.ids, count: 120) }, located: located)
        let trips = PhotoTripBuilder.trips(from: located, home: PhotoTripBuilder.home(in: located))
        progress(total, total, results)
        return Result(found: results, trips: trips)
    }

    /// Trips for the fixtures: two real-looking runs with their places.
    private static func demoTrips() -> [PhotoTrip] {
        func stop(_ code: String, _ city: String, _ lat: Double, _ lng: Double,
                  _ first: String, _ last: String, _ count: Int) -> PhotoStop {
            PhotoStop(countryCode: code, lat: lat, lng: lng,
                      first: DayFormat.date(from: first) ?? Date(),
                      last: DayFormat.date(from: last) ?? Date(),
                      photoCount: count, sampleIds: [], city: city)
        }
        let europe = PhotoTrip(stops: [
            stop("DE", "Berlin", 52.52, 13.40, "2022-05-08", "2022-05-10", 96),
            stop("CZ", "Prague", 50.08, 14.44, "2022-05-11", "2022-05-15", 131),
            stop("AT", "Vienna", 48.21, 16.37, "2022-05-16", "2022-05-18", 48),
            stop("HU", "Budapest", 47.50, 19.04, "2022-05-19", "2022-05-23", 77),
        ], countryCodes: ["DE", "CZ", "AT", "HU"])
        let italy = PhotoTrip(stops: [
            stop("IT", "Rome", 41.90, 12.50, "2025-05-01", "2025-05-04", 143),
            stop("IT", "Florence", 43.77, 11.26, "2025-05-05", "2025-05-06", 119),
        ], countryCodes: ["IT"])
        return [italy, europe]
    }

    /// Evenly spaced picks across the whole run, so samples span every visit.
    nonisolated static func sample(_ ids: [String], count: Int) -> [String] {
        guard ids.count > count else { return ids }
        let step = Double(ids.count - 1) / Double(count - 1)
        return (0..<count).map { ids[Int((Double($0) * step).rounded())] }
    }
}

/// Thread-safe stop flag shared with the background scan.
final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// Photos on this phone, by country — from the last library scan. Local only;
/// powers "On this phone" suggestions when adding a memory.
enum LocalPhotoIndex {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("local-photo-index.json")
    }

    /// `code` → photos in that country, and `code|yyyy-MM-dd` → that day's,
    /// so a memory can offer the photos taken where and when it happened.
    static func save(_ index: [String: [String]], located: [LocatedPhoto] = []) {
        var index = index
        var byDay: [String: [String]] = [:]
        for photo in located {
            byDay["\(photo.countryCode)|\(DayFormat.string(from: photo.date))", default: []].append(photo.id)
        }
        for (key, ids) in byDay { index[key] = PhotoLibraryScanner.sample(ids, count: 40) }
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Photos taken in this country on this day (from the last scan).
    static func assetIds(for code: String, on day: String) -> [String] {
        assetIds(for: "\(code)|\(day)")
    }

    static func assetIds(for code: String) -> [String] {
        guard PhotoLibraryScanner.hasReadAccess,
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return index[code] ?? []
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Photos on this phone from where and when a memory happened. The library
/// import deliberately uploads nothing, so this is what fills those memories
/// in — on this device, for this traveller's eyes only.
enum LocalMemoryPhotos {
    static func assetIds(for memory: Memory, limit: Int = 12) -> [String] {
        guard memory.photos.isEmpty, PhotoLibraryScanner.hasReadAccess else { return [] }
        return Array(LocalPhotoIndex.assetIds(for: memory.countryCode,
                                              on: String(memory.date.prefix(10))).prefix(limit))
    }
}

/// Thumbnails and full images for on-device assets.
enum LocalAssets {
    static func thumbnail(_ identifier: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        // highQualityFormat calls back exactly once; opportunistic can deliver
        // only a degraded image and never a final one, which would hang here.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = await MainActor.run { UIScreen.main.scale }
        let target = CGSize(width: side * scale, height: side * scale)
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFill,
                                                  options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// Original bytes + metadata for turning a library photo into a memory.
    static func imageData(_ identifier: String) async -> (Data, PhotoMetadata)? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        let data: Data? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        // The capture clock from EXIF names the local day; creationDate is an
        // instant, which lands on the wrong day when read in another zone.
        let exif = PhotoMetadata.read(from: data)
        let meta = PhotoMetadata(latitude: asset.location?.coordinate.latitude ?? exif.latitude,
                                 longitude: asset.location?.coordinate.longitude ?? exif.longitude,
                                 date: exif.date ?? asset.creationDate)
        return (data, meta)
    }
}
