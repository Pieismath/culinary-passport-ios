import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// Where an image's bytes come from.
enum ImageSource: Hashable {
    /// A path in the private `photos` bucket — fetched with the user's session,
    /// so storage RLS decides who can see it.
    case storage(String)
    /// A public URL (avatars, group covers).
    case url(URL)

    var cacheKey: String {
        switch self {
        case .storage(let path): "storage:\(path)"
        case .url(let url): "url:\(url.absoluteString)"
        }
    }
}

/// Loads, downsamples and caches images.
///
/// Replaces AsyncImage + signed URLs, which re-downloaded every photo whenever
/// a cell reappeared and again every hour when signed URLs rotated. Storage
/// paths are unique per upload and never change, so bytes are cached on disk
/// by path — a photo downloads once per device. Decoding uses ImageIO
/// thumbnails at the size actually displayed, so a feed of 12 MP photos
/// doesn't hold full-resolution bitmaps in memory.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private var backend: (any Backend)?
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL

    init() {
        memory.totalCostLimit = 120 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func configure(backend: any Backend) {
        self.backend = backend
        memory.removeAllObjects()
    }

    /// Seed the cache with bytes we already have (a photo just uploaded), so
    /// the new memory renders instantly instead of downloading what we sent.
    func prime(_ source: ImageSource, data: Data) {
        try? data.write(to: file(for: source), options: .atomic)
    }

    func image(for source: ImageSource, maxPixel: CGFloat) async -> UIImage? {
        let size = Self.sizeBucket(maxPixel)
        let key = "\(source.cacheKey)@\(size)"
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let pending = inFlight[key] { return await pending.value }

        let file = file(for: source)
        let backend = backend
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            var data = try? Data(contentsOf: file)
            if data == nil {
                data = await Self.fetch(source, backend: backend)
                if let data { try? data.write(to: file, options: .atomic) }
            }
            guard let data else { return nil }
            return Self.downsample(data, maxPixel: size)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            memory.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    /// Keep the on-disk cache under a budget, dropping least-recently-written first.
    func trimDisk(maxBytes: Int = 400 * 1024 * 1024) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > maxBytes else { return }
        entries.sort { $0.1 < $1.1 }
        for entry in entries where total > maxBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.2
        }
    }

    func clearAll() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // ── Internals ────────────────────────────────────────────────────────────

    private func file(for source: ImageSource) -> URL {
        let digest = SHA256.hash(data: Data(source.cacheKey.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private static func fetch(_ source: ImageSource, backend: (any Backend)?) async -> Data? {
        switch source {
        case .storage(let path):
            return try? await backend?.photoData(path: path)
        case .url(let url):
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
            return data
        }
    }

    /// Round up so nearby sizes share one decoded bitmap.
    private static func sizeBucket(_ maxPixel: CGFloat) -> CGFloat {
        for bucket: CGFloat in [160, 320, 640, 1280, 2048] where maxPixel <= bucket { return bucket }
        return 2048
    }

    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// An image from the pipeline. Layout-neutral: it fills whatever frame the
/// caller gives it (and clips), so `.fill` photos never push layouts wider.
struct RemoteImage<Placeholder: View>: View {
    let source: ImageSource?
    var maxPixel: CGFloat = 1200
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else {
                    placeholder()
                }
            }
            .clipped()
            .task(id: source) {
                guard let source else { image = nil; return }
                let loaded = await ImagePipeline.shared.image(for: source, maxPixel: maxPixel)
                withAnimation(.easeOut(duration: 0.18)) { image = loaded }
            }
    }
}

extension RemoteImage where Placeholder == SkeletonBlock {
    init(source: ImageSource?, maxPixel: CGFloat = 1200, contentMode: ContentMode = .fill) {
        self.init(source: source, maxPixel: maxPixel, contentMode: contentMode) {
            SkeletonBlock(cornerRadius: 0)
        }
    }
}

/// A photo from the private bucket.
struct StoragePhoto: View {
    let path: String?
    var maxPixel: CGFloat = 1200

    var body: some View {
        RemoteImage(source: path.map(ImageSource.storage), maxPixel: maxPixel)
    }
}
