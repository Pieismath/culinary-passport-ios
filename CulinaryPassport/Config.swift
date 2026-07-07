import Foundation

/// Supabase credentials come from Config.xcconfig → Info.plist at build time.
/// Copy Config.example.xcconfig to Config.xcconfig and fill in your project's values.
enum Config {
    static let supabaseURL = URL(string: plist("SUPABASE_URL"))!
    static let supabaseAnonKey = plist("SUPABASE_ANON_KEY")

    private static func plist(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            fatalError("Missing \(key) — copy Config.example.xcconfig to Config.xcconfig and fill it in")
        }
        return value
    }
}
