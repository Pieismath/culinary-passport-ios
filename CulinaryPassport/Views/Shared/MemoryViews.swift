import SwiftUI

/// Swipeable photos for one memory. Text-only memories get a postcard in
/// the country's stamp ink instead of an empty frame.
struct PhotoPager: View {
    let memory: Memory
    var aspect: CGFloat = 4.0 / 5.0
    var cornerRadius: CGFloat = 18
    var maxPixel: CGFloat = 1400

    @State private var page = 0

    var body: some View {
        SwiftUI.Group {
            if memory.photos.isEmpty {
                PostcardPlaceholder(code: memory.countryCode, title: memory.displayTitle)
            } else if memory.photos.count == 1 {
                StoragePhoto(path: memory.photos[0], maxPixel: maxPixel)
            } else {
                TabView(selection: $page) {
                    // Keyed by path: editing a memory's photos must not hand
                    // an existing page a different photo.
                    ForEach(Array(memory.photos.enumerated()), id: \.element) { index, path in
                        StoragePhoto(path: path, maxPixel: maxPixel).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay(alignment: .bottom) {
                    HStack(spacing: 5) {
                        ForEach(memory.photos.indices, id: \.self) { index in
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
        .accessibilityLabel(memory.photos.isEmpty
                            ? "No photos"
                            : "\(memory.photos.count) photo\(memory.photos.count == 1 ? "" : "s") from \(memory.displayTitle)")
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

/// A memory in a feed: who, where, photos, words, reactions.
struct MemoryCard: View {
    let memory: Memory
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
                            Text(author?.name ?? "Traveller")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.ink)
                            Text("\(memory.country?.flag ?? "") \(memory.placeLine) · \(RelativeTime.short(memory.createdAt))")
                                .font(.caption)
                                .foregroundStyle(Color.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                if let badge {
                    Pill(systemImage: "seal.fill", text: badge, tint: .brand, background: .brandSoft)
                }
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    PhotoPager(memory: memory, cornerRadius: 16, maxPixel: 1200)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(memory.displayTitle)
                            .font(.headline)
                            .foregroundStyle(Color.ink)
                        if let notes = memory.notes, !notes.isEmpty {
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
                if memory.userId != app.myId {
                    SavePlaceButton(memory: memory)
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

/// Square photo tile with the place written on it.
struct MemoryTile: View {
    let memory: Memory
    var showTitle = true

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let first = memory.photos.first {
                    StoragePhoto(path: first, maxPixel: 500)
                } else {
                    PostcardPlaceholder(code: memory.countryCode, title: nil)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showTitle {
                    Text("\(memory.country?.flag ?? "") \(memory.displayTitle)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                                   startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay(alignment: .topTrailing) {
                if memory.photos.count > 1 {
                    Image(systemName: "square.on.square.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(memory.displayTitle), \(memory.placeLine), \(DayFormat.pretty(memory.date))")
    }
}

/// "I want to go there" — keeps a friend's place for a trip of your own.
struct SavePlaceButton: View {
    let memory: Memory
    var showsLabel = false

    @Environment(AppModel.self) private var app

    private var saved: Bool { app.savedPlace(from: memory) != nil }

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            Task { await app.toggleSavedPlace(from: memory) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: saved ? "bookmark.fill" : "bookmark")
                if showsLabel { Text(saved ? "Saved for a trip" : "Save this place") }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(saved ? Color.bucket : Color.inkSecondary)
            .padding(.horizontal, showsLabel ? 12 : 8)
            .padding(.vertical, 6)
            .background(saved ? Color.bucketSoft : Color.sunken, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved ? "Saved for a trip" : "Save this place for a trip")
    }
}

/// An inferred trip: cover photo, where, when.
struct TripCard: View {
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    if let cover = trip.coverPhoto {
                        StoragePhoto(path: cover, maxPixel: 900)
                    } else {
                        PostcardPlaceholder(code: trip.countryCodes.first ?? "UN", title: nil)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trip.flags).font(.title3)
                        Text(trip.title)
                            .font(.displayXSmall)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                }
                .clipped()
            HStack {
                Text(trip.dateRangeText)
                Spacer()
                Text("\(trip.memories.count) memor\(trip.memories.count == 1 ? "y" : "ies")\(trip.photoCount > 0 ? " · \(trip.photoCount) photos" : "")")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.inkSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
            .strokeBorder(Color.hairline.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
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
