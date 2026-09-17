import SwiftUI

// Paper the app already implies: a boarding pass for a trip, a luggage tag
// for a place you've saved. Both are real shapes with a torn stub and a
// punched hole, not rounded rectangles with a different tint — a passport app
// that renders everything as a card wastes the metaphor it was built on.

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
private struct TicketTear: Shape {
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

/// A luggage tag: a card with the strap hole punched out of its leading edge.
struct LuggageTagShape: InsettableShape {
    var corner: CGFloat = Metrics.corner
    var hole: CGFloat = 6
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var punch = Path()
        punch.addEllipse(in: CGRect(x: rect.minX + 17 - hole, y: rect.midY - hole,
                                    width: hole * 2, height: hole * 2))
        return Path(roundedRect: rect, cornerRadius: corner, style: .continuous).subtracting(punch)
    }

    func inset(by amount: CGFloat) -> LuggageTagShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Content on the ticket, content on the stub, torn line down the middle.
struct BoardingPass<Main: View, Stub: View>: View {
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

/// "IN 92 DAYS" · "DAY 3 OF 10" · "SOMEDAY" — the state of a plan, in the
/// monospaced type a ticket would use.
struct CountdownChip: View {
    let plan: TripPlan

    private var isNow: Bool { if case .now = plan.phase() { return true } else { return false } }

    var body: some View {
        Text(plan.countdownText().uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(isNow ? Color.onBrand : Color.brand)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isNow ? Color.brand : Color.brandSoft, in: Capsule())
    }
}

/// A trip you're planning, as a boarding pass.
struct TripPlanCard: View {
    let plan: TripPlan
    /// Who's coming, when it's a group trip.
    var members: [Profile] = []
    var savedCount: Int = 0

    var body: some View {
        BoardingPass {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    CountdownChip(plan: plan)
                    if !members.isEmpty {
                        AvatarStack(profiles: members, size: 20)
                    }
                }
                Text(plan.title)
                    .font(.displayXSmall)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !plan.flags.isEmpty { Text(plan.flags).font(.subheadline) }
                    Text(plan.dateRangeText ?? "No dates yet")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                }
                if savedCount > 0 {
                    Label(savedCount.counted("place"), systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.inkSecondary)
                }
            }
        } stub: {
            VStack(spacing: 1) {
                if let days = plan.days {
                    Text("\(days)")
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.ink)
                    Text(days == 1 ? "DAY" : "DAYS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Color.inkTertiary)
                } else {
                    Image(systemName: "airplane.departure")
                        .font(.title3)
                        .foregroundStyle(Color.inkTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(plan.title), \(plan.countdownText())")
    }
}

/// The back of a postcard: what you wrote, the stamp, the postmark.
struct PostcardNote: View {
    let text: String
    let code: String
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
                StampBadge(code: code, subtitle: stampSubtitle, size: 62)
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

/// Overlapping avatars — who's on a trip, without a row of names.
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
