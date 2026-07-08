import UIKit

// ROADMAP item 17 — avatar unlockable accessories, ship-path 1: preset overlays
// composited client-side (v2 is prompt-regenerated variants). Accessories are
// gated by the user's dining progress, so the avatar visibly grows with the map.
// Art is rendered locally (emoji glyphs + drawn rings) — no bundled assets yet;
// swap AvatarComposer's rendering for real PNGs when the art lands.

enum AccessorySlot: String, CaseIterable, Codable {
    case hat, frame, badge

    var title: String {
        switch self {
        case .hat: "Hats"
        case .frame: "Frames"
        case .badge: "Badges"
        }
    }
}

/// A snapshot of what the user has eaten, used to evaluate unlock rules.
struct AvatarProgress {
    let countryCount: Int
    let continents: Set<String>
    let cuisineCodes: Set<String>
    let hasRare: Bool
    let totalMeals: Int

    static func from(entries: [Entry]) -> AvatarProgress {
        let codes = Set(entries.map(\.countryCode))
        let continents = Set(codes.compactMap { CountryStore.byCode[$0]?.continent }.filter { !$0.isEmpty })
        let hasRare = codes.contains { Country.rareCodes.contains($0) }
        return AvatarProgress(
            countryCount: codes.count,
            continents: continents,
            cuisineCodes: codes,
            hasRare: hasRare,
            totalMeals: entries.count
        )
    }

    static let empty = AvatarProgress(countryCount: 0, continents: [], cuisineCodes: [], hasRare: false, totalMeals: 0)
}

struct AvatarAccessory: Identifiable {
    let id: String
    let name: String
    let slot: AccessorySlot
    let glyph: String?          // emoji for hat / badge
    let ringColor: UIColor?     // for frame
    let unlockHint: String
    let isUnlocked: (AvatarProgress) -> Bool

    func unlocked(_ p: AvatarProgress) -> Bool { isUnlocked(p) }
}

extension AvatarAccessory: Hashable {
    static func == (lhs: AvatarAccessory, rhs: AvatarAccessory) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AvatarCatalog {
    // A set of spicy / noodle cuisines for themed badges.
    private static let spicy: Set<String> = ["TH", "MX", "IN", "KR", "ID", "MY", "ET"]
    private static let noodle: Set<String> = ["JP", "CN", "VN", "KR", "TH", "IT"]

    static let all: [AvatarAccessory] = [
        // Hats — gated on breadth (distinct countries).
        AvatarAccessory(id: "cap", name: "Explorer Cap", slot: .hat, glyph: "🧢", ringColor: nil,
                        unlockHint: "Try 3 cuisines") { $0.countryCount >= 3 },
        AvatarAccessory(id: "topper", name: "Gourmand's Topper", slot: .hat, glyph: "🎩", ringColor: nil,
                        unlockHint: "Try 15 cuisines") { $0.countryCount >= 15 },
        AvatarAccessory(id: "crown", name: "Globe Crown", slot: .hat, glyph: "👑", ringColor: nil,
                        unlockHint: "Try 30 cuisines") { $0.countryCount >= 30 },

        // Frames — gated on volume (total meals logged).
        AvatarAccessory(id: "bronze", name: "Bronze Ring", slot: .frame, glyph: nil,
                        ringColor: UIColor(red: 0.80, green: 0.50, blue: 0.20, alpha: 1),
                        unlockHint: "Log 5 meals") { $0.totalMeals >= 5 },
        AvatarAccessory(id: "silver", name: "Silver Ring", slot: .frame, glyph: nil,
                        ringColor: UIColor(red: 0.75, green: 0.75, blue: 0.78, alpha: 1),
                        unlockHint: "Log 25 meals") { $0.totalMeals >= 25 },
        AvatarAccessory(id: "gold", name: "Gold Ring", slot: .frame, glyph: nil,
                        ringColor: UIColor(red: 0.85, green: 0.68, blue: 0.28, alpha: 1),
                        unlockHint: "Log 50 meals") { $0.totalMeals >= 50 },

        // Badges — themed achievements.
        AvatarAccessory(id: "continental", name: "Continental", slot: .badge, glyph: "🌏", ringColor: nil,
                        unlockHint: "Eat across 3 continents") { $0.continents.count >= 3 },
        AvatarAccessory(id: "rare", name: "Rare Palate", slot: .badge, glyph: "✦", ringColor: nil,
                        unlockHint: "Try a rare cuisine") { $0.hasRare },
        AvatarAccessory(id: "heat", name: "Heat Seeker", slot: .badge, glyph: "🌶️", ringColor: nil,
                        unlockHint: "Try a fiery cuisine") { !$0.cuisineCodes.isDisjoint(with: spicy) },
        AvatarAccessory(id: "noodle", name: "Noodle Nomad", slot: .badge, glyph: "🍜", ringColor: nil,
                        unlockHint: "Try a noodle cuisine") { !$0.cuisineCodes.isDisjoint(with: noodle) },
    ]

    static func accessory(id: String) -> AvatarAccessory? { all.first { $0.id == id } }
    static func inSlot(_ slot: AccessorySlot) -> [AvatarAccessory] { all.filter { $0.slot == slot } }
}

/// Which accessory is equipped per slot — device-local (v1). Social display of
/// customized avatars is a v2 concern (prompt-regenerated variants).
struct EquippedStore {
    private static let key = "avatar.equipped.v1"

    static func load() -> [AccessorySlot: String] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
            AccessorySlot(rawValue: k).map { ($0, v) }
        })
    }

    static func save(_ equipped: [AccessorySlot: String]) {
        let raw = Dictionary(uniqueKeysWithValues: equipped.map { ($0.key.rawValue, $0.value) })
        UserDefaults.standard.set(raw, forKey: key)
    }
}
