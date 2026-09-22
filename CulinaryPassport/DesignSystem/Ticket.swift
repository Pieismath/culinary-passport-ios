import SwiftUI

// Paper that goes with dinner: a ticket for tonight's pick (a torn stub with
// the distance on it), a tag for a restaurant you've saved, the back of a
// postcard for a note. Real shapes with a stub and a punched hole, not
// rounded rectangles with a different tint.

/// A ticket: rounded card with a stub torn off the trailing edge.
struct TicketShape: InsettableShape {
    /// Distance from the trailing edge to the tear line.
    var stubWidth: CGFloat = 92
    var notch: CGFloat = 8
    var corner: CGFloat = Metrics.cornerLarge
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let tearX = max(rect.minX, rect.maxX - stubWidth)
        var bites = Path()
        for y in [rect.minY, rect.maxY] {
            bites.addEllipse(in: CGRect(x: tearX - notch, y: y - notch, width: notch * 2, height: notch * 2))
        }
        return Path(roundedRect: rect, cornerRadius: corner, style: .continuous).subtracting(bites)
    }

    func inset(by amount: CGFloat) -> TicketShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// The dashed line between a ticket and its stub.
struct TicketTear: Shape {
    var stubWidth: CGFloat
    var inset: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = max(rect.minX, rect.maxX - stubWidth)
        path.move(to: CGPoint(x: x, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: x, y: rect.maxY - inset))
        return path
    }
}

/// A tag: clipped corners on its leading end, and the string hole punched
/// through it — the shape a restaurant you're saving hangs from.
struct LuggageTagShape: InsettableShape {
    var corner: CGFloat = Metrics.corner
    var hole: CGFloat = 6
    var chamfer: CGFloat = 18
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = min(chamfer, rect.height / 2)
        let r = min(corner, rect.height / 2)
        var tag = Path()
        tag.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        tag.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        tag.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                   tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        tag.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        tag.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                   tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        tag.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        tag.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
        tag.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        tag.closeSubpath()
        var punch = Path()
        punch.addEllipse(in: CGRect(x: rect.minX + 17 - hole, y: rect.midY - hole,
                                    width: hole * 2, height: hole * 2))
        return tag.subtracting(punch)
    }

    func inset(by amount: CGFloat) -> LuggageTagShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// A till receipt: straight sides, zig-zag tear at the top and bottom.
struct ReceiptShape: Shape {
    var tooth: CGFloat = 12
    var depth: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = max(1, Int(rect.width / tooth))
        let step = rect.width / CGFloat(count)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + depth))
        for index in 0..<count {
            let x = rect.minX + CGFloat(index) * step
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.minY))
            path.addLine(to: CGPoint(x: x + step, y: rect.minY + depth))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - depth))
        for index in (0..<count).reversed() {
            let x = rect.minX + CGFloat(index) * step
            path.addLine(to: CGPoint(x: x + step / 2, y: rect.maxY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY - depth))
        }
        path.closeSubpath()
        return path
    }
}

/// A dashed line across a receipt.
struct DashedRule: View {
    var body: some View {
        Line()
            .stroke(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// Dots leading from a label to its value.
struct DottedLeader: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
            }
            .stroke(Color.inkTertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 4]))
        }
        .accessibilityHidden(true)
    }
}

/// Content on the ticket, content on the stub, torn line down the middle.
struct TicketCard<Main: View, Stub: View>: View {
    var stubWidth: CGFloat = 92
    var stubTint: Color = .sunken
    @ViewBuilder var main: () -> Main
    @ViewBuilder var stub: () -> Stub

    var body: some View {
        HStack(spacing: 0) {
            main()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
            stub()
                .frame(width: stubWidth)
                .frame(maxHeight: .infinity)
        }
        .background(alignment: .trailing) {
            stubTint.frame(width: stubWidth)
        }
        .background(Color.card)
        .overlay {
            TicketTear(stubWidth: stubWidth)
                .stroke(Color.hairline, style: StrokeStyle(lineWidth: 1, dash: [3.5, 3.5]))
        }
        .clipShape(TicketShape(stubWidth: stubWidth))
        .overlay {
            TicketShape(stubWidth: stubWidth).strokeBorder(Color.hairline.opacity(0.8), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }
}

/// The back of a postcard: what you wrote, the stamp, the postmark.
struct PostcardNote: View {
    let text: String
    let code: String
    var tasted = false
    var stampSubtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(Color.hairline)
                .frame(width: 1)
                .padding(.vertical, 2)

            VStack(spacing: 7) {
                StampBadge(code: code, subtitle: stampSubtitle, size: 62, tasted: tasted)
                VStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(Color.hairline).frame(height: 1.5)
                    }
                }
                .frame(width: 52)
                .accessibilityHidden(true)
            }
        }
        .padding(15)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .strokeBorder(Color.hairline.opacity(0.8), lineWidth: 0.5)
        }
    }
}

/// Overlapping avatars — who's in, without a row of names.
struct AvatarStack: View {
    let profiles: [Profile]
    var size: CGFloat = 22
    var max = 4

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(profiles.prefix(max)) { profile in
                AvatarView(profile: profile, size: size)
                    .overlay(Circle().strokeBorder(Color.card, lineWidth: 1.5))
            }
            if profiles.count > max {
                Text("+\(profiles.count - max)")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Color.inkSecondary)
                    .frame(width: size, height: size)
                    .background(Color.sunken, in: Circle())
                    .overlay(Circle().strokeBorder(Color.card, lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}
