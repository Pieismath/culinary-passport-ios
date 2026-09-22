import SwiftUI

// The dining room the app is set in: the world served on a plate, meals as
// plates, tables seen from above with everyone seated around them, gingham
// cloth, and a round spin button. Circles on purpose — a food app that draws
// everything as cards wastes the table it's set on.

/// A dinner plate from above: porcelain rim, a fine band, a sunken well.
/// `content` fills the well and is clipped to it.
struct Plate<Content: View>: View {
    /// Rim width as a fraction of the plate's radius.
    var rim: CGFloat = 0.13
    var band: Color = Color.brand.opacity(0.28)
    var shadow = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let well = side * (1 - rim)
            ZStack {
                Circle()
                    .fill(Color.card)
                    .shadow(color: .black.opacity(shadow ? 0.16 : 0), radius: side * 0.05, y: side * 0.025)
                Circle()
                    .strokeBorder(band, lineWidth: max(1, side * 0.004))
                    .padding(side * 0.022)
                // The well: a touch darker at its edge, as if sunken.
                Circle()
                    .fill(RadialGradient(colors: [Color.card, Color.sunken.opacity(0.7)], center: .center,
                                         startRadius: well * 0.32, endRadius: well * 0.5))
                    .frame(width: well, height: well)
                    .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 0.8))
                content()
                    .frame(width: well, height: well)
                    .clipShape(Circle())
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// How much of each continent you've eaten, set around a plate's rim: one
/// arc per continent, inked as far as you've got, its name curved along it.
struct ContinentRim: View {
    let progress: [Continent: FoodStats.Progress]
    var tint: Color = .brand
    /// Where the arcs run, as a fraction of the plate's radius.
    var radius: CGFloat = 0.955
    var showsLabels = true
    var highlighted: Continent?

    private static let gap = 10.0

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let arcRadius = side / 2 * radius
            let line = max(2.5, side * 0.009)
            let span = 360.0 / Double(FoodStats.continents.count)
            ZStack {
                ForEach(Array(FoodStats.continents.enumerated()), id: \.element) { index, continent in
                    let centre = span * Double(index)
                    let start = centre - (span - Self.gap) / 2
                    let length = (span - Self.gap) / 360
                    let fraction = progress[continent]?.fraction ?? 0
                    let lit = highlighted == nil || highlighted == continent
                    ZStack {
                        Circle()
                            .trim(from: 0, to: length)
                            .stroke(Color.hairline, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        Circle()
                            .trim(from: 0, to: length * max(fraction, fraction > 0 ? 0.02 : 0))
                            .stroke(tint.opacity(lit ? 1 : 0.35), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    }
                    .frame(width: arcRadius * 2, height: arcRadius * 2)
                    .rotationEffect(.degrees(start - 90))

                    if showsLabels {
                        let tasted = progress[continent]?.tasted ?? 0
                        let total = progress[continent]?.total ?? 0
                        CurvedText(text: "\(continent.shortName.uppercased())  \(tasted)/\(total)",
                                   radius: arcRadius - line - side * 0.022,
                                   angle: centre,
                                   size: max(7, side * 0.021),
                                   color: lit ? .inkSecondary : .inkTertiary)
                    }
                }
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FoodStats.continents.map { continent in
            let p = progress[continent]
            return "\(continent.rawValue) \(p?.tasted ?? 0) of \(p?.total ?? 0)"
        }.joined(separator: ", "))
    }
}

/// Text set along a circle, centred at `angle` (degrees clockwise from 12
/// o'clock). Below the equator it runs the other way so it never reads
/// upside down.
struct CurvedText: View {
    let text: String
    let radius: CGFloat
    let angle: Double
    var size: CGFloat = 8.5
    var color: Color = .inkSecondary

    var body: some View {
        let characters = Array(text)
        // Monospaced, so every character advances the same distance.
        let advance = size * 0.62 + size * 0.1
        let step = Double(advance / max(radius, 1)) * 180 / .pi
        let lower = cos(angle * .pi / 180) < -0.05
        ZStack {
            ForEach(characters.indices, id: \.self) { index in
                let offset = (Double(index) - Double(characters.count - 1) / 2) * step
                Text(String(characters[index]))
                    .font(.system(size: size, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .fixedSize()
                    .offset(y: lower ? radius : -radius)
                    .rotationEffect(.degrees(lower ? angle - 180 - offset : angle + offset))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Gingham: two sets of translucent stripes, darker where they cross.
struct Gingham: View {
    var color: Color
    var stripe: CGFloat = 11

    var body: some View {
        Canvas { context, size in
            let shade = GraphicsContext.Shading.color(color.opacity(0.2))
            var x: CGFloat = 0
            while x < size.width {
                context.fill(Path(CGRect(x: x, y: 0, width: stripe, height: size.height)), with: shade)
                x += stripe * 2
            }
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: stripe)), with: shade)
                y += stripe * 2
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One place at a table: who's sitting there (nil for an empty chair) and
/// the flag of what they ate last, on their plate.
struct TableSeat: Identifiable {
    let id: String
    var profile: Profile?
    var lastCuisine: String?

    static func empty(_ index: Int) -> TableSeat { TableSeat(id: "empty-\(index)") }
}

/// A table from above: the cloth, a place setting and a chair for everyone
/// around the edge, and whatever sits in the middle — a name card, or the
/// lazy Susan globe.
struct RoundTable<Center: View>: View {
    let seats: [TableSeat]
    var cloth: Color
    var seatSize: CGFloat = 38
    /// Each diner's plate, with the flag of their last meal on it.
    var showsPlates = true
    /// False for a table not set yet: a dashed outline on the floor.
    var isSet = true
    var onEmptySeat: (() -> Void)?
    @ViewBuilder var center: () -> Center

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let table = side - seatSize * 1.35
            let seatRadius = table / 2 + seatSize * 0.3
            let plateRadius = table / 2 * 0.76
            let plateSize = max(18, table * 0.13)
            let middle = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                if isSet {
                    Circle()
                        .fill(Color.card)
                        .overlay { Gingham(color: cloth, stripe: max(7, table * 0.045)).clipShape(Circle()) }
                        .overlay { Circle().strokeBorder(cloth.opacity(0.55), lineWidth: 1.5) }
                        .frame(width: table, height: table)
                        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
                        .position(middle)
                } else {
                    Circle()
                        .strokeBorder(Color.inkTertiary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                        .background(Circle().fill(Color.paper.opacity(0.6)))
                        .frame(width: table, height: table)
                        .position(middle)
                }

                if showsPlates {
                    ForEach(Array(seats.enumerated()), id: \.element.id) { index, seat in
                        let point = Self.point(index, of: seats.count, radius: plateRadius, around: middle)
                        ZStack {
                            Circle().fill(Color.card)
                            Circle().strokeBorder(Color.hairline, lineWidth: 0.8).padding(plateSize * 0.16)
                            if let code = seat.lastCuisine {
                                Text(Country.flag(for: code)).font(.system(size: plateSize * 0.42))
                            }
                        }
                        .frame(width: plateSize, height: plateSize)
                        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                        .opacity(seat.profile == nil ? 0.45 : 1)
                        .position(point)
                    }
                }

                center()
                    .position(middle)

                ForEach(Array(seats.enumerated()), id: \.element.id) { index, seat in
                    seatView(seat)
                        .position(Self.point(index, of: seats.count, radius: seatRadius, around: middle))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder private func seatView(_ seat: TableSeat) -> some View {
        if let profile = seat.profile {
            AvatarView(profile: profile, size: seatSize)
                .overlay(Circle().strokeBorder(Color.card, lineWidth: max(2, seatSize * 0.07)))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
        } else {
            Button { onEmptySeat?() } label: {
                Image(systemName: "plus")
                    .font(.system(size: seatSize * 0.36, weight: .bold))
                    .foregroundStyle(Color.inkTertiary)
                    .frame(width: seatSize, height: seatSize)
                    .background(Color.paper, in: Circle())
                    .overlay(Circle().strokeBorder(Color.inkTertiary.opacity(0.6),
                                                   style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])))
            }
            .buttonStyle(.plain)
            .disabled(onEmptySeat == nil)
            .accessibilityLabel("Empty seat — invite someone")
        }
    }

    /// Seats go round from 12 o'clock.
    static func point(_ index: Int, of count: Int, radius: CGFloat, around middle: CGPoint) -> CGPoint {
        let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(max(count, 1))
        return CGPoint(x: middle.x + radius * CGFloat(cos(angle)), y: middle.y + radius * CGFloat(sin(angle)))
    }
}

/// The spin button: a round knob with an arrow chasing itself around it,
/// which keeps turning while the globe does.
struct SpinButton: View {
    var spinning = false
    var size: CGFloat = 76
    var title = "Spin"
    let action: () -> Void

    @State private var turn = 0.0

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.brand)
                Circle()
                    .trim(from: 0.04, to: 0.86)
                    .stroke(Color.onBrand.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(size * 0.1)
                    .overlay(alignment: .top) {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: size * 0.11))
                            .foregroundStyle(Color.onBrand.opacity(0.75))
                            .offset(x: size * 0.13, y: size * 0.045)
                    }
                    .rotationEffect(.degrees(turn))
                Text(title.uppercased())
                    .font(.system(size: size * 0.2, weight: .heavy, design: .rounded))
                    .tracking(size * 0.012)
                    .foregroundStyle(Color.onBrand)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.24), radius: 10, y: 5)
        }
        .buttonStyle(PressScale())
        .onChange(of: spinning) { _, on in
            if on {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) { turn += 360 }
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { turn = (turn / 360).rounded() * 360 }
            }
        }
    }
}

/// Where a spin landed, set down on the plate like a coaster: the flag, the
/// cuisine, and a dashed ring waiting for its first stamp.
struct SpinCoaster: View {
    let code: String
    var size: CGFloat = 170

    private var ink: Color { StampInk.color(for: code) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.card)
                .shadow(color: .black.opacity(0.28), radius: size * 0.09, y: size * 0.05)
            Circle()
                .strokeBorder(ink, style: StrokeStyle(lineWidth: size * 0.018, dash: [size * 0.035, size * 0.025]))
                .padding(size * 0.06)
            Circle()
                .strokeBorder(ink.opacity(0.4), lineWidth: 0.8)
                .padding(size * 0.1)
            VStack(spacing: size * 0.02) {
                Text("TONIGHT")
                    .font(.system(size: size * 0.065, weight: .heavy, design: .monospaced))
                    .tracking(size * 0.012)
                    .foregroundStyle(ink)
                Text(Country.flag(for: code))
                    .font(.system(size: size * 0.3))
                Text(Cuisine.name(for: code).uppercased())
                    .font(.system(size: size * 0.1, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(StampInk.tilt(for: code)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The globe landed on \(Cuisine.name(for: code))")
    }
}

/// Shrinks a little under the finger.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A meal, served: its photo in the well of a plate, the cuisine's flag
/// clipped to the rim. Fills what it's given when `size` is nil.
struct MealPlate: View {
    let meal: Meal
    var size: CGFloat?
    var showsFlag = true

    var body: some View {
        GeometryReader { geometry in
            let side = size ?? min(geometry.size.width, geometry.size.height)
            plate(side)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meal.displayTitle), \(Cuisine.name(for: meal.countryCode)), \(DayFormat.pretty(meal.date))")
    }

    private func plate(_ side: CGFloat) -> some View {
        Plate(rim: 0.16, band: StampInk.color(for: meal.countryCode).opacity(0.45), shadow: true) {
            if let first = meal.photos.first {
                StoragePhoto(path: first, maxPixel: side * 3)
            } else {
                ZStack {
                    StampInk.color(for: meal.countryCode).opacity(0.14)
                    Text(Country.flag(for: meal.countryCode)).font(.system(size: side * 0.34))
                }
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .bottomTrailing) {
            if showsFlag, !meal.photos.isEmpty {
                Text(Country.flag(for: meal.countryCode))
                    .font(.system(size: side * 0.2))
                    .padding(side * 0.03)
                    .background(Color.card, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(x: -side * 0.02, y: -side * 0.02)
            }
        }
    }
}

/// Plates laid out the way they'd crowd a table: rows offset by half a plate,
/// nesting into each other's gaps.
struct PlateStack: Layout {
    var columns = 3
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let side = plateSide(width)
        let rows = rowCount(subviews.count)
        guard rows > 0 else { return CGSize(width: width, height: 0) }
        let pitch = (side + spacing) * 0.88
        return CGSize(width: width, height: side + CGFloat(rows - 1) * pitch)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let side = plateSide(bounds.width)
        let pitch = (side + spacing) * 0.88
        var index = 0
        var row = 0
        while index < subviews.count {
            let offsetRow = row % 2 == 1
            // A short last row is centred like the rest, not left behind.
            let perRow = min(offsetRow ? columns - 1 : columns, subviews.count - index)
            let rowWidth = CGFloat(perRow) * side + CGFloat(perRow - 1) * spacing
            let startX = bounds.minX + (bounds.width - rowWidth) / 2
            for column in 0..<perRow where index < subviews.count {
                let x = startX + CGFloat(column) * (side + spacing)
                let y = bounds.minY + CGFloat(row) * pitch
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: side, height: side))
                index += 1
            }
            row += 1
        }
    }

    private func plateSide(_ width: CGFloat) -> CGFloat {
        (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
    }

    private func rowCount(_ count: Int) -> Int {
        var remaining = count
        var rows = 0
        while remaining > 0 {
            remaining -= rows % 2 == 1 ? columns - 1 : columns
            rows += 1
        }
        return rows
    }
}
