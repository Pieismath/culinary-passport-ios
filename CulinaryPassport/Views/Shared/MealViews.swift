import SwiftUI

/// Swipeable photos for one meal. A meal without photos gets a card in the
/// cuisine's stamp ink instead of an empty frame.
struct PhotoPager: View {
    let meal: Meal
    var aspect: CGFloat = 4.0 / 5.0
    var cornerRadius: CGFloat = 18
    var maxPixel: CGFloat = 1400

    @State private var page = 0

    var body: some View {
        SwiftUI.Group {
            if meal.photos.isEmpty {
                PostcardPlaceholder(code: meal.countryCode, title: meal.displayTitle)
            } else if meal.photos.count == 1 {
                StoragePhoto(path: meal.photos[0], maxPixel: maxPixel)
            } else {
                TabView(selection: $page) {
                    // Keyed by path: editing a meal's photos must not hand an
                    // existing page a different photo.
                    ForEach(Array(meal.photos.enumerated()), id: \.element) { index, path in
                        StoragePhoto(path: path, maxPixel: maxPixel).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay(alignment: .bottom) {
                    HStack(spacing: 5) {
                        ForEach(meal.photos.indices, id: \.self) { index in
                            Circle()
                                .fill(.white.opacity(index == page ? 1 : 0.5))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.25), in: Capsule())
                    .padding(.bottom, 10)
                    .accessibilityHidden(true)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meal.photos.isEmpty
                            ? "No photos"
                            : "\(meal.photos.count) photo\(meal.photos.count == 1 ? "" : "s") of \(meal.displayTitle)")
    }
}

struct PostcardPlaceholder: View {
    let code: String
    var title: String?

    var body: some View {
        ZStack {
            StampInk.color(for: code).opacity(0.14)
            VStack(spacing: 8) {
                Text(Country.flag(for: code)).font(.system(size: 54))
                if let title {
                    Text(title)
                        .font(.displayXSmall)
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 20)
                }
            }
        }
    }
}

/// A meal in a feed: who, what, where, the photo, words, reactions.
struct MealCard: View {
    let meal: Meal
    let author: Profile?
    let tallies: [ReactionTally]
    let commentCount: Int
    var badge: String?
    let onOpen: () -> Void
    let onOpenAuthor: () -> Void
    let onReact: (String, Bool) -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: onOpenAuthor) {
                    HStack(spacing: 10) {
                        AvatarView(profile: author, size: 38)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(author?.name ?? "Someone")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.ink)
                            Text("\(meal.feedLine) · \(RelativeTime.short(meal.createdAt))")
                                .font(.caption)
                                .foregroundStyle(Color.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                if let badge {
                    Pill(systemImage: "fork.knife", text: badge, tint: .brand, background: .brandSoft)
                }
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    PhotoPager(meal: meal, cornerRadius: 16, maxPixel: 1200)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meal.displayTitle)
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                        if let notes = meal.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.subheadline)
                                .foregroundStyle(Color.inkSecondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                ReactionBar(tallies: tallies, onToggle: onReact, compact: true)
                Spacer(minLength: 0)
                if meal.userId != app.myId {
                    SavePlaceButton(meal: meal)
                }
                Button(action: onOpen) {
                    Label("\(commentCount)", systemImage: "bubble.left")
                        .font(.subheadline.weight(.medium))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Color.inkSecondary)
                        .frame(minHeight: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(commentCount) comments")
            }
        }
        .card(padding: 14)
    }
}

/// "I want to eat there" — keeps a friend's restaurant on your list.
struct SavePlaceButton: View {
    let meal: Meal
    var showsLabel = false

    @Environment(AppModel.self) private var app

    private var saved: Bool { app.savedPlace(from: meal) != nil }

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            Task { await app.toggleSavedPlace(from: meal) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: saved ? "bookmark.fill" : "bookmark")
                if showsLabel { Text(saved ? "On your list" : "Save the restaurant") }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(saved ? Color.saffron : Color.inkSecondary)
            .padding(.horizontal, showsLabel ? 12 : 8)
            .padding(.vertical, 6)
            .background(saved ? Color.saffronSoft : Color.sunken, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved ? "Restaurant saved to try" : "Save this restaurant to try")
    }
}

/// Wrapping row layout (flags, chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(width, maxX), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
