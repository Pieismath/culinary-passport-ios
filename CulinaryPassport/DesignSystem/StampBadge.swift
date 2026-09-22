import SwiftUI

/// A passport stamp for one country — the app's signature visual. Each
/// country gets a stable ink, shape and tilt, so a page of them looks like a
/// real, well-used passport rather than a grid of icons.
struct StampBadge: View {
    let code: String
    var subtitle: String?
    var size: CGFloat = 104
    /// Ghost stamps (not tasted yet) render faint and dashed.
    var inked = true
    /// The Tasted stamp: the cuisine's name ("GEORGIAN") and a fork and
    /// knife where a visa stamp would have its border crossing.
    var tasted = false

    private var country: Country? { CountryStore.byCode[code] }
    private var ink: Color { inked ? StampInk.color(for: code) : .inkTertiary }
    /// Tasted stamps take a different shape from the visa stamp for the same
    /// country, so the two sit side by side on a page without matching.
    private var shapeKind: Int { StampInk.stableHash(code + (tasted ? "taste" : "shape")) % 3 }

    var body: some View {
        ZStack {
            outline
            // Name in the middle row: round and capsule stamps are widest
            // there, so long names ("UNITED KINGDOM") don't run into the ring.
            VStack(spacing: size * 0.03) {
                Text(Country.flag(for: code))
                    .font(.system(size: size * 0.24))
                    .grayscale(inked ? 0 : 1)
                    .opacity(inked ? 1 : 0.5)
                if tasted {
                    Image(systemName: "fork.knife")
                        .font(.system(size: size * 0.075, weight: .bold))
                        .padding(.top, -size * 0.01)
                }
                Text(label)
                    .font(.system(size: size * 0.085, weight: .heavy, design: .rounded))
                    .tracking(size * 0.008)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .padding(.horizontal, size * 0.13)
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(.system(size: size * 0.075, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, size * 0.16)
                }
            }
            .foregroundStyle(ink)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(inked ? StampInk.tilt(for: code) : 0))
        .opacity(inked ? 0.94 : 0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tasted
                            ? "\(Cuisine.name(for: code)) food, tasted\(subtitle.map { ", \($0)" } ?? "")"
                            : "\(country?.name ?? code)\(subtitle.map { ", \($0)" } ?? "")")
    }

    private var label: String {
        (tasted ? Cuisine.name(for: code) : country?.name ?? code).uppercased()
    }

    @ViewBuilder private var outline: some View {
        let line = size * 0.03
        let dash: [CGFloat] = inked ? [] : [size * 0.04, size * 0.03]
        switch shapeKind {
        case 0:
            Circle()
                .strokeBorder(ink, style: StrokeStyle(lineWidth: line, dash: dash))
            Circle()
                .strokeBorder(ink.opacity(0.7), lineWidth: line * 0.45)
                .padding(size * 0.07)
        case 1:
            RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                .strokeBorder(ink, style: StrokeStyle(lineWidth: line, dash: dash))
                .padding(.vertical, size * 0.1)
            RoundedRectangle(cornerRadius: size * 0.1, style: .continuous)
                .strokeBorder(ink.opacity(0.7), lineWidth: line * 0.45)
                .padding(.vertical, size * 0.16)
                .padding(.horizontal, size * 0.06)
        default:
            Capsule()
                .strokeBorder(ink, style: StrokeStyle(lineWidth: line, dash: dash))
                .padding(.vertical, size * 0.14)
            Capsule()
                .strokeBorder(ink.opacity(0.7), lineWidth: line * 0.45)
                .padding(.vertical, size * 0.2)
                .padding(.horizontal, size * 0.06)
        }
    }
}

/// A perforated postage-stamp frame (the app icon's shape).
struct PerforatedRectangle: Shape {
    var toothRadius: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let base = Path(rect)
        var bites = Path()
        let r = toothRadius
        let spacing = r * 2.6
        func bite(_ x: CGFloat, _ y: CGFloat) {
            bites.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        let across = max(1, Int((rect.width / spacing).rounded()))
        let stepX = rect.width / CGFloat(across)
        for i in 0...across {
            bite(rect.minX + CGFloat(i) * stepX, rect.minY)
            bite(rect.minX + CGFloat(i) * stepX, rect.maxY)
        }
        let down = max(1, Int((rect.height / spacing).rounded()))
        let stepY = rect.height / CGFloat(down)
        for i in 0...down {
            bite(rect.minX, rect.minY + CGFloat(i) * stepY)
            bite(rect.maxX, rect.minY + CGFloat(i) * stepY)
        }
        return base.subtracting(bites)
    }
}

/// A big celebratory postage stamp: flag, country (or cuisine), "Nº 24", date.
struct PostageStamp: View {
    let code: String
    var number: Int?
    var date: String?
    var width: CGFloat = 230
    var tasted = false

    private var country: Country? { CountryStore.byCode[code] }

    var body: some View {
        let ink = StampInk.color(for: code)
        VStack(spacing: 10) {
            HStack {
                Text("STAMPD")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(2)
                Spacer()
                if let number {
                    Text("Nº \(number)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                }
            }
            .foregroundStyle(ink)

            Text(Country.flag(for: code))
                .font(.system(size: width * 0.34))
                .padding(.vertical, 6)

            if tasted {
                Label("FIRST TASTE", systemImage: "fork.knife")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink)
            }
            Text((tasted ? Cuisine.name(for: code) : country?.name ?? code).uppercased())
                .font(.system(size: 20, weight: .bold, design: .serif))
                .tracking(1.5)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Color.ink)

            if let date {
                Text(date.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink)
            }
        }
        .padding(22)
        .frame(width: width)
        .background {
            ZStack {
                Color.card
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(ink.opacity(0.55), lineWidth: 2)
                    .padding(10)
            }
        }
        .clipShape(PerforatedRectangle(toothRadius: width * 0.03))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
    }
}
