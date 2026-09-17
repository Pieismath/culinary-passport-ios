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
            meta.date = exifFormatter.date(from: raw)
        }
        return meta
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

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}

/// Point → stampable place, tuned for photo locations rather than globe taps:
/// small places (Singapore, Vatican City, Hong Kong…) win within their radius
/// — they sit inside or beside big polygons — and coastal shots just off the
/// coarse 110m shoreline snap to the nearest country within a few kilometres.
enum PlaceLocator {
    /// Rough radius (km) around each small place's centroid.
    private static let radiusKm: [String: Double] = [
        "VA": 1, "MC": 3, "GI": 4, "SM": 8, "MO": 9, "SX": 12, "LI": 13, "JE": 13, "GG": 13, "AD": 16,
        "NR": 10, "AW": 22, "BB": 25, "LC": 26, "SG": 26, "MT": 28, "KN": 28, "BM": 28, "BH": 32,
        "HK": 34, "GD": 32, "IM": 32, "GU": 32, "DM": 32, "CW": 36, "AG": 42, "VI": 42, "VG": 32,
        "MQ": 42, "BQ": 55, "VC": 55, "KY": 65, "GP": 65, "RE": 65, "AS": 65, "AX": 70, "FO": 80,
        "TC": 90, "WS": 100, "PW": 130, "MU": 130, "MP": 160, "ST": 160, "KM": 170, "CV": 260,
        "SJ": 280, "TO": 280, "SC": 320, "TV": 380, "MV": 500, "KI": 520, "MH": 600, "FM": 650,
        "CK": 700, "PF": 800,
    ]

    private static let small: [(code: String, lat: Double, lng: Double, radius: Double)] =
        CountryStore.markers.compactMap { country in
            radiusKm[country.code].map { (country.code, country.centroid.lat, country.centroid.lng, $0) }
        }

    static func country(lat: Double, lng: Double, coastalSnapKm: Double = 12) -> String? {
        var best: (code: String, fit: Double)?
        for place in small {
            // Cheap bounding check before the trig.
            guard abs(place.lat - lat) < place.radius / 100 + 0.5 else { continue }
            let d = Geo.distanceKm(lat, lng, place.lat, place.lng)
            if d <= place.radius {
                let fit = d / place.radius
                if best == nil || fit < best!.fit { best = (place.code, fit) }
            }
        }
        if let best { return best.code }
        if let code = CountryGeometry.country(atLat: lat, lng: lng) { return code }
        return CountryGeometry.nearestCountry(atLat: lat, lng: lng, withinKm: coastalSnapKm)
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
    var scanned = 0
    var total = 0
    var found: [Found] = []

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
        let results = await Task.detached(priority: .userInitiated) { [weak self] in
            Self.scanLibrary { done, total, snapshot in
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
        found = results
        scanned = max(scanned, total)
        phase = .finished
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
        phase = .finished
    }

    /// Walks the library oldest → newest. Locations are bucketed into ~5 km
    /// cells so the polygon test runs once per place, not once per photo.
    nonisolated static func scanLibrary(progress: @escaping (Int, Int, [Found]) -> Void) -> [Found] {
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

        func snapshot() -> [Found] {
            byCode.map { code, acc in
                Found(code: code, photoCount: acc.count, first: acc.first, last: acc.last,
                      trips: max(1, acc.tripStarts), samples: sample(acc.ids, count: 6))
            }
            .sorted { $0.photoCount > $1.photoCount }
        }

        assets.enumerateObjects { asset, index, _ in
            if index % 400 == 0 { progress(index, total, snapshot()) }
            guard let location = asset.location else { return }
            let lat = location.coordinate.latitude
            let lng = location.coordinate.longitude
            guard CLLocationCoordinate2DIsValid(location.coordinate), !(lat == 0 && lng == 0) else { return }

            let cell = Int64((lat * 20).rounded()) * 10_000 + Int64((lng * 20).rounded())
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
        }

        let results = snapshot()
        LocalPhotoIndex.save(byCode.mapValues { sample($0.ids, count: 120) })
        progress(total, total, results)
        return results
    }

    /// Evenly spaced picks across the whole run, so samples span every visit.
    nonisolated static func sample(_ ids: [String], count: Int) -> [String] {
        guard ids.count > count else { return ids }
        let step = Double(ids.count - 1) / Double(count - 1)
        return (0..<count).map { ids[Int((Double($0) * step).rounded())] }
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

    static func save(_ index: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
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
        let meta = PhotoMetadata(latitude: asset.location?.coordinate.latitude,
                                 longitude: asset.location?.coordinate.longitude,
                                 date: asset.creationDate)
        return (data, meta)
    }
}
