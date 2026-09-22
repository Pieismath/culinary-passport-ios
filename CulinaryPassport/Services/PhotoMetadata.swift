import Foundation
import Photos
import ImageIO

// A meal photo knows where it was taken — that's how the editor finds the
// restaurant — and when, which dates the meal.

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

    /// Whether the app may read the library itself (only when the person has
    /// granted it — a PhotosPicker pick needs no permission).
    nonisolated static var hasReadAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Richer metadata from the Photos library when we have access and an
    /// asset id (location survives even when the transferred file lacks EXIF).
    static func read(assetIdentifier: String?) -> PhotoMetadata? {
        guard let assetIdentifier, hasReadAccess,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject
        else { return nil }
        return PhotoMetadata(latitude: asset.location?.coordinate.latitude,
                             longitude: asset.location?.coordinate.longitude,
                             date: asset.creationDate)
    }
}
