import SwiftUI
import UIKit

// Stampd's visual language: a travel journal. Warm paper, sepia ink, the
// brand's passport green, and stamp-pad inks for accents. Every color is a
// light/dark pair — screens never hard-code a paper tone and then draw
// `.primary` text on it (that combination is what went white-on-cream in
// Dark Mode before).

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255,
                  green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255,
                  alpha: alpha)
    }

    /// Parses "#rrggbb" / "rrggbb" (profiles.color). nil if malformed.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(rgb: value)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) }
    }

    /// Flatten `self` at `alpha` over `base` into an opaque color (SceneKit
    /// caps render opaque so overlapping transparent geometry never sorts).
    func composited(alpha: CGFloat, over base: UIColor) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        base.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
        let t = max(0, min(1, alpha))
        return UIColor(red: r1 * t + r0 * (1 - t),
                       green: g1 * t + g0 * (1 - t),
                       blue: b1 * t + b0 * (1 - t),
                       alpha: 1)
    }
}

enum Palette {
    // Surfaces
    static let paper = UIColor.dynamic(light: 0xF6F1E7, dark: 0x13110D)
    static let card = UIColor.dynamic(light: 0xFFFCF6, dark: 0x1F1C17)
    static let sunken = UIColor.dynamic(light: 0xEDE5D6, dark: 0x2A261F)
    static let hairline = UIColor.dynamic(light: 0xE2D9C8, dark: 0x3A342B)

    // Ink
    static let ink = UIColor.dynamic(light: 0x1E1A14, dark: 0xF3EEE4)
    static let inkSecondary = UIColor.dynamic(light: 0x6B6254, dark: 0xB0A799)
    static let inkTertiary = UIColor.dynamic(light: 0x9E9484, dark: 0x7D7568)

    // Brand + accents
    static let brand = UIColor.dynamic(light: 0x2F5A45, dark: 0x86C2A2)
    static let brandDeep = UIColor(rgb: 0x324E3D)          // icon/launch green, both modes
    static let brandSoft = UIColor.dynamic(light: 0xDCE8DF, dark: 0x1E3328)
    static let onBrand = UIColor.dynamic(light: 0xFFFCF6, dark: 0x0F1A14)
    static let stampRed = UIColor.dynamic(light: 0xB4452D, dark: 0xE88468)
    static let bucket = UIColor.dynamic(light: 0xC0832A, dark: 0xE4AE55)
    static let bucketSoft = UIColor.dynamic(light: 0xF4E4C6, dark: 0x3A2E19)
    static let danger = UIColor.dynamic(light: 0xB3261E, dark: 0xF2877E)
    /// Gold leaf on the passport cover. The cover is dark in both modes, so
    /// this one colour is right in both.
    static let foil = UIColor(rgb: 0xD9B877)
}

extension Color {
    static let paper = Color(uiColor: Palette.paper)
    static let card = Color(uiColor: Palette.card)
    static let sunken = Color(uiColor: Palette.sunken)
    static let hairline = Color(uiColor: Palette.hairline)
    static let ink = Color(uiColor: Palette.ink)
    static let inkSecondary = Color(uiColor: Palette.inkSecondary)
    static let inkTertiary = Color(uiColor: Palette.inkTertiary)
    static let brand = Color(uiColor: Palette.brand)
    static let brandDeep = Color(uiColor: Palette.brandDeep)
    static let brandSoft = Color(uiColor: Palette.brandSoft)
    static let onBrand = Color(uiColor: Palette.onBrand)
    static let stampRed = Color(uiColor: Palette.stampRed)
    static let bucket = Color(uiColor: Palette.bucket)
    static let bucketSoft = Color(uiColor: Palette.bucketSoft)
    static let danger = Color(uiColor: Palette.danger)
    static let foil = Color(uiColor: Palette.foil)

    init(hex: String, fallback: UIColor = .systemGray) {
        self.init(uiColor: UIColor(hex: hex) ?? fallback)
    }
}

// ── Type ────────────────────────────────────────────────────────────────────
// Serif (New York) for editorial headings — it's what makes a screen read as
// a journal rather than a settings page. Rounded for numbers and the
// wordmark. Body stays SF. Text styles, so Dynamic Type still scales.

extension Font {
    static let displayLarge = Font.system(.largeTitle, design: .serif).weight(.semibold)
    static let display = Font.system(.title, design: .serif).weight(.semibold)
    static let displaySmall = Font.system(.title2, design: .serif).weight(.semibold)
    static let displayXSmall = Font.system(.title3, design: .serif).weight(.semibold)
    static let wordmark = Font.system(.title2, design: .rounded).weight(.bold)
    static let eyebrow = Font.system(.caption2, design: .default).weight(.semibold)

    static func number(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

enum Metrics {
    static let cornerLarge: CGFloat = 22
    static let corner: CGFloat = 16
    static let cornerSmall: CGFloat = 10
    static let gutter: CGFloat = 16
}

// ── Stamp inks ──────────────────────────────────────────────────────────────

enum StampInk {
    private static let inks: [(light: UInt32, dark: UInt32)] = [
        (0xB4452D, 0xE88468), // postal red
        (0x2E5C8A, 0x7FAAD6), // customs blue
        (0x2F6B4F, 0x7CC0A0), // visa green
        (0x6B4E8C, 0xB49AD6), // violet
        (0x2A7373, 0x74C2C2), // teal
        (0x8A5A2B, 0xD4A06A), // sepia
    ]

    /// Same ink for the same country everywhere, every launch.
    static func color(for code: String) -> Color {
        let pair = inks[stableHash(code) % inks.count]
        return Color(uiColor: .dynamic(light: pair.light, dark: pair.dark))
    }

    /// A small, stable tilt so a page of stamps looks hand-pressed.
    static func tilt(for code: String) -> Double {
        Double(stableHash(code + "tilt") % 13) - 6
    }

    static func stableHash(_ s: String) -> Int {
        // FNV-1a — deterministic across launches, unlike String.hashValue.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(Int.max))
    }
}
