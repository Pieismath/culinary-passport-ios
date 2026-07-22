import SwiftUI
import Supabase

/// Signs storage paths in the private `photos` bucket and caches the URLs
/// until shortly before they expire (Finding 4, Option A — the bucket is no
/// longer public). Access control lives in the DB: the storage SELECT policy
/// only signs objects whose owning entry is visible to the caller, so a
/// failed sign means "not yours to see", and the placeholder stays up.
actor PhotoURLCache {
    static let shared = PhotoURLCache()

    private let ttl: TimeInterval = 3600
    private var cache: [String: (url: URL, expires: Date)] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]

    func url(for path: String) async -> URL? {
        // refresh with 5 minutes still on the clock so a URL never dies mid-render
        if let hit = cache[path], hit.expires.timeIntervalSinceNow > 300 { return hit.url }
        // unbounded growth guard: drop dead entries, then oldest if still fat
        if cache.count > 400 {
            cache = cache.filter { $0.value.expires > Date() }
            if cache.count > 400 { cache.removeAll() }
        }
        if let pending = inFlight[path] { return await pending.value }
        let task = Task<URL?, Never> {
            try? await SupabaseService.shared.client.storage.from("photos")
                .createSignedURL(path: path, expiresIn: Int(ttl))
        }
        inFlight[path] = task
        let url = await task.value
        inFlight[path] = nil
        if let url { cache[path] = (url, Date().addingTimeInterval(ttl)) }
        return url
    }
}

/// AsyncImage for a path in the private photos bucket: resolves a signed URL,
/// then renders exactly like AsyncImage(url:content:placeholder:).
struct SignedPhotoImage<Content: View, Placeholder: View>: View {
    let path: String
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var url: URL?

    init(
        path: String,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.path = path
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        SwiftUI.Group {
            if let url {
                AsyncImage(url: url, content: content, placeholder: placeholder)
            } else {
                placeholder()
            }
        }
        .task(id: path) { url = await PhotoURLCache.shared.url(for: path) }
    }
}
