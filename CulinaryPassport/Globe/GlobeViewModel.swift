import Foundation
import SwiftUI

// MVP steps 3+6 feeding the globe: which cuisines have been tried, by whom, and
// therefore what color each country's cap should be. Ports capColor() from the
// web GlobeView.tsx — untried is parchment, one taster shows their profile color,
// two-or-more shows the shared purple.

@MainActor
final class GlobeViewModel: ObservableObject {
    @Published var statusByCountry: [String: Set<UUID>] = [:]
    @Published var usersById: [UUID: Profile] = [:]
    @Published var entriesByCountry: [String: [Entry]] = [:]
    @Published var loading = false
    @Published var error: String?

    /// Shared "both have tried it" tint — web config.ts PURPLE (#8b6fd8).
    static let purple = UIColor(red: 0x8b/255, green: 0x6f/255, blue: 0xd8/255, alpha: 1)
    /// Fallback tint — web config.ts AMBER (#c98a2e).
    static let amber = UIColor(red: 0xc9/255, green: 0x8a/255, blue: 0x2e/255, alpha: 1)
    /// Untouched interactive land — web UNTOUCHED rgba(214,207,191).
    static let parchment = UIColor(red: 214/255, green: 207/255, blue: 191/255, alpha: 1)
    /// Ocean sphere color — caps are composited over this and rendered opaque, so
    /// SceneKit never has to depth-sort transparent overlapping country caps
    /// (that produced ocean-colored holes where caps met).
    static let ocean = UIColor(red: 0.85, green: 0.89, blue: 0.92, alpha: 1)

    /// Flatten `color` at `alpha` onto the ocean → an opaque tint that reads the
    /// same as the web's rgba-over-globe compositing.
    static func opaque(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a: CGFloat = 0
        var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0
        color.getRed(&r1, green: &g1, blue: &b1, alpha: &a)
        ocean.getRed(&r0, green: &g0, blue: &b0, alpha: &a)
        let t = min(1, alpha)
        return UIColor(red: r1 * t + r0 * (1 - t),
                       green: g1 * t + g0 * (1 - t),
                       blue: b1 * t + b0 * (1 - t),
                       alpha: 1)
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            // RLS scopes this to entries the signed-in user may see (their own +
            // anything shared). Enough to color a personal globe; group/together
            // views layer on top later.
            let entries = try await SupabaseService.shared.myEntries()
            guard let me = try await SupabaseService.shared.myProfile() else {
                // Profile row is gone (deleted user / stale session) — sign out
                // cleanly rather than surfacing an error on the globe.
                await SupabaseService.shared.signOut()
                return
            }

            var status: [String: Set<UUID>] = [:]
            var byCountry: [String: [Entry]] = [:]
            for entry in entries {
                status[entry.countryCode, default: []].insert(entry.userId)
                byCountry[entry.countryCode, default: []].append(entry)
            }

            // Resolve any authors we don't already know (beyond the current user).
            var users: [UUID: Profile] = [me.id: me]
            let unknown = Set(entries.map(\.userId)).subtracting(users.keys)
            if !unknown.isEmpty {
                for profile in (try? await SupabaseService.shared.profiles(ids: Array(unknown))) ?? [] {
                    users[profile.id] = profile
                }
            }

            statusByCountry = status
            entriesByCountry = byCountry
            usersById = users
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// capColor() port. `selected` gets a small opacity boost, like the web hover.
    func color(for code: String, selected: Bool) -> UIColor {
        let boost: CGFloat = selected ? 0.22 : 0
        let tasters = statusByCountry[code] ?? []

        if tasters.isEmpty {
            return Self.opaque(Self.parchment, 0.55 + boost)
        }
        if tasters.count >= 2 {
            return Self.opaque(Self.purple, 0.66 + boost)
        }
        // Single taster → their profile color.
        let taster = tasters.first.flatMap { usersById[$0] }
        let base = taster.flatMap { UIColor(hex: $0.color) } ?? Self.amber
        return Self.opaque(base, 0.62 + boost)
    }

    /// Human-readable "who's tried it" for the detail panel.
    func tasterNames(for code: String) -> [String] {
        (statusByCountry[code] ?? []).compactMap { usersById[$0]?.name }.sorted()
    }
}

extension UIColor {
    /// Parses "#rrggbb" / "rrggbb" (profiles.color from the schema). nil if malformed.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
