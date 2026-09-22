import Foundation
import UIKit

/// Stable, distinct color per group member. Profile colors are respected the
/// first time each appears, but the signup trigger gives almost everyone the
/// same green — duplicates fall through to the next unused palette hue, keyed
/// on sorted member ids so every device shows the same mapping.
enum GroupPalette {
    static let fallbacks = [
        "#3b82e0", // blue
        "#2fbf8a", // green
        "#8b6fd8", // purple
        "#e8883a", // orange
        "#e05c5c", // red
        "#2fa8bf", // teal
        "#d86fb4", // pink
        "#a8763e", // brown
    ]

    /// Same color for the same id on every launch and every device. (Swift's
    /// `hashValue` is randomly seeded per process, so a hash-based pick made
    /// group monograms change color each time the app started.)
    static func stableColor(for id: UUID) -> String {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return fallbacks[sum % fallbacks.count]
    }

    static func assign(memberIds: [UUID], profiles: [UUID: Profile]) -> [UUID: String] {
        var used = Set<String>()
        var assigned: [UUID: String] = [:]
        for id in memberIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            var color = profiles[id]?.color.lowercased()
            if let c = color, used.contains(c) || UIColor(hex: c) == nil { color = nil }
            let final = color ?? fallbacks.first { !used.contains($0) } ?? "#c98a2e"
            used.insert(final)
            assigned[id] = final
        }
        return assigned
    }

    /// Average of member colors — a country two people share reads as both.
    static func blend(_ colors: [UIColor]) -> UIColor {
        guard !colors.isEmpty else { return .systemGray }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        for color in colors {
            var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
            color.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
            r += cr; g += cg; b += cb
        }
        let n = CGFloat(colors.count)
        return UIColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
    }
}
