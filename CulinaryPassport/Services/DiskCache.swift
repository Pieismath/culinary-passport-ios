import Foundation

/// Stale-while-refresh: every main surface renders its last-known data
/// instantly from disk, then replaces it when the network answers. Turns
/// cold tab-opens from a spinner into content.
///
/// JSON files under Caches/, keyed per user so switching accounts can't leak
/// one person's journal into another's UI. Cleared on sign-out.
enum DiskCache {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("surface-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func url(_ key: String, user: UUID?) -> URL {
        let scope = user?.uuidString.lowercased() ?? "anon"
        return directory.appendingPathComponent("\(scope)-\(key).json")
    }

    static func load<T: Decodable>(_ key: String, user: UUID?, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url(key, user: user)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String, user: UUID?) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(key, user: user), options: .atomic)
    }

    /// Sign-out hygiene: drop everything.
    static func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}
