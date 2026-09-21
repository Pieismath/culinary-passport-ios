import SwiftUI

// The passport as a booklet rather than a stack of cards: a gold-blocked
// cover, a data page with the traveller's details and a machine-readable
// strip, and stamp pages with a stitched spine and page numbers.
//
// Everything here is decoration over real data — the numbers are the same
// ones the stats card showed, just set the way a passport would set them.

/// The cover: dark board, gold leaf, the traveller's name blocked into it.
struct PassportCover: View {
    let name: String
    let countries: Int
    var cuisines = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("STAMPD")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(3)
                Spacer()
                Text("WORLD PASSPORT")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.5)
            }

            Image(systemName: "globe.europe.africa")
                .font(.system(size: 34, weight: .light))
                .padding(.top, 2)

            VStack(spacing: 3) {
                Text(name.isEmpty ? "TRAVELLER" : name.uppercased())
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .tracking(2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(cuisines > 0
                     ? "\(countries.counted("COUNTRY", "COUNTRIES").uppercased()) · \(cuisines.counted("CUISINE").uppercased())"
                     : countries.counted("COUNTRY", "COUNTRIES").uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .opacity(0.75)
            }
        }
        .foregroundStyle(Color.foil)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .fill(Color.brandDeep)
                .overlay {
                    // Blind-embossed rule, a few millimetres in from the edge.
                    RoundedRectangle(cornerRadius: Metrics.cornerLarge - 7, style: .continuous)
                        .strokeBorder(Color.foil.opacity(0.35), lineWidth: 0.8)
                        .padding(7)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name)'s passport, \(countries.counted("country", "countries")), \(cuisines.counted("cuisine")) tasted")
    }
}

/// The passport photo: squared off, not a circle, because that's what a data
/// page mounts. Falls back to the traveller's colour and initial.
struct PassportPhoto: View {
    let profile: Profile?
    var width: CGFloat = 84
    var height: CGFloat = 108

    var body: some View {
        ZStack {
            Color(hex: profile?.color ?? "#2f5a45").opacity(0.85)
            Text(String((profile?.name ?? "").trimmed.prefix(1)).uppercased())
                .font(.system(size: height * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let urlString = profile?.avatarUrl, let url = URL(string: urlString) {
                RemoteImage(source: .url(url), maxPixel: height * 3) { Color.clear }
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// The data page: photo, the fields a passport carries, and the two
/// machine-readable lines along the bottom.
struct PassportDataPage<Photo: View>: View {
    let profile: Profile?
    let stats: TravelStats
    let memories: Int
    @ViewBuilder var photo: () -> Photo

    private var homeCountry: Country? { profile?.homeCountry.flatMap { CountryStore.byCode[$0] } }

    private var memberSince: String {
        guard let created = profile?.createdAt else { return "—" }
        return created.formatted(.dateTime.year())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                photo()
                    .frame(width: 84, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.hairline, lineWidth: 0.5)
                    }

                VStack(alignment: .leading, spacing: 11) {
                    field("Traveller", profile?.name ?? "—", wide: true)
                    HStack(alignment: .top, spacing: 18) {
                        field("Nationality", homeCountry.map { "\($0.flag) \($0.name)" } ?? "—")
                        field("Since", memberSince)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        field("Countries", "\(stats.countries)")
                        field("Cuisines", "\(stats.cuisines)")
                        field("World", stats.worldPercentText)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 18) {
                field("Continents", "\(stats.continents)/7")
                field("Meals", "\(stats.meals)")
                field("Cities", "\(stats.cities)")
                field("Memories", "\(memories)")
                Spacer(minLength: 0)
            }

            if let remarks = profile?.bio?.trimmed, !remarks.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("REMARKS")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Color.inkTertiary)
                    Text(remarks)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            MachineReadableStrip(profile: profile, stats: stats)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .fill(Color.card)
                .overlay { Guilloche().clipShape(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .strokeBorder(Color.hairline.opacity(0.8), lineWidth: 0.5)
        }
    }

    private func field(_ label: String, _ value: String, wide: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Color.inkTertiary)
            Text(value)
                .font(.system(size: wide ? 19 : 15, weight: .medium, design: .serif))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// The two OCR lines along the bottom of a data page. Decorative, and built
/// only from what's already on the page.
struct MachineReadableStrip: View {
    let profile: Profile?
    let stats: TravelStats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.lines(profile: profile, stats: stats), id: \.self) { line in
                Text(line)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    static func lines(profile: Profile?, stats: TravelStats, width: Int = 40) -> [String] {
        let code = (profile?.homeCountry ?? "XX").uppercased()
        let parts = (profile?.name ?? "TRAVELLER").uppercased()
            .components(separatedBy: " ")
            .map { $0.filter { $0.isLetter } }
            .filter { !$0.isEmpty }
        let surname = parts.count > 1 ? parts.last! : (parts.first ?? "TRAVELLER")
        let given = parts.count > 1 ? parts.dropLast().joined(separator: "<") : ""
        let first = "P<\(code)\(surname)<<\(given)"
        let second = "\(number(for: profile?.id))\(code)\(pad(stats.countries, 3))\(pad(stats.continents, 2))<\(pad(stats.cuisines, 3))"
        return [fill(first, to: width), fill(second, to: width)]
    }

    /// A stable seven-digit "passport number" from the account id.
    private static func number(for id: UUID?) -> String {
        guard let id else { return "0000000" }
        let bytes = id.uuid
        let value = (UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3))
        return String(format: "%07d", Int(value % 9_000_000) + 1_000_000)
    }

    private static func pad(_ value: Int, _ digits: Int) -> String {
        String(format: "%0\(digits)d", min(value, Int(pow(10, Double(digits))) - 1))
    }

    private static func fill(_ text: String, to width: Int) -> String {
        text.count >= width
            ? String(text.prefix(width))
            : text + String(repeating: "<", count: width - text.count)
    }
}

/// What gets posted elsewhere: the cover, blocked in gold, over a page of
/// stamps. Rendered by ImageRenderer, so every colour here is explicit.
struct PassportShareCard: View {
    let profile: Profile?
    let stats: TravelStats
    let stamps: [Stamp]

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 7) {
                HStack {
                    Text("STAMPD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(3)
                    Spacer()
                    Text("WORLD PASSPORT")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                }
                Text((profile?.name ?? "Traveller").uppercased())
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .tracking(2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 2)
                Text("\(stats.countries.counted("COUNTRY", "COUNTRIES").uppercased()) · \(stats.cuisines.counted("CUISINE").uppercased())")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .opacity(0.8)
            }
            .foregroundStyle(Color(uiColor: Palette.foil))
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: Palette.brandDeep))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(uiColor: Palette.foil).opacity(0.35), lineWidth: 0.8)
                            .padding(6)
                    }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 4), count: 3), spacing: 8) {
                ForEach(stamps.prefix(9)) { stamp in
                    StampBadge(code: stamp.countryCode, subtitle: stamp.yearsText, size: 92)
                }
            }
        }
    }
}

/// A page of the book: cream paper, faint guilloché, a stitched spine and a
/// page number in the corner.
struct StampPage<Content: View>: View {
    let number: Int
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
            HStack {
                Spacer()
                Text("PAGE \(number)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Color.inkTertiary)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 14)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .fill(Color.card)
                .overlay { Guilloche().clipShape(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)) }
                .overlay(alignment: .leading) {
                    // The stitched spine this page is bound along.
                    Spine().padding(.leading, 11).padding(.vertical, 16)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .strokeBorder(Color.hairline.opacity(0.8), lineWidth: 0.5)
        }
    }
}

/// Faint engraved lines — the security print under everything on a page.
struct Guilloche: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let ink = GraphicsContext.Shading.color(Color.hairline.opacity(0.5))
                var line = Path()
                var y = 6.0
                while y < size.height {
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    y += 11
                }
                context.stroke(line, with: ink, lineWidth: 0.4)

                // Two engine-turned rosettes, the way real security print
                // fills the empty half of a page.
                for centre in [CGPoint(x: size.width * 0.22, y: size.height * 0.34),
                               CGPoint(x: size.width * 0.78, y: size.height * 0.7)] {
                    var rings = Path()
                    for step in stride(from: 6.0, through: 46.0, by: 8.0) {
                        rings.addEllipse(in: CGRect(x: centre.x - step, y: centre.y - step * 0.7,
                                                    width: step * 2, height: step * 1.4))
                    }
                    context.stroke(rings, with: ink, lineWidth: 0.35)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Stitch holes along the binding edge.
private struct Spine: View {
    var body: some View {
        GeometryReader { geometry in
            let count = max(4, Int(geometry.size.height / 14))
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    Capsule()
                        .fill(Color.hairline)
                        .frame(width: 1.5, height: 6)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 2)
        }
        .frame(width: 2)
        .accessibilityHidden(true)
    }
}
