import SwiftUI

/// One meal in full: photos, where, what, reactions and comments. Yours get
/// Edit / Share / Delete; other people's get Save the restaurant, Report,
/// Block.
struct MealDetailView: View {
    let meal: Meal

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current: Meal
    @State private var reactions: [Reaction] = []
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var reporting = false
    @State private var confirmBlock = false
    @State private var shareImage: UIImage?

    init(meal: Meal) {
        self.meal = meal
        _current = State(initialValue: meal)
    }

    private var isMine: Bool { current.userId == app.myId }
    private var author: Profile? { app.profile(current.userId) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // A print on the table, not a card: white border, a
                    // deeper bottom edge, set down a little crooked.
                    PhotoPager(meal: current, aspect: 4.0 / 5.0, cornerRadius: 4, maxPixel: 1800)
                        .padding(10)
                        .padding(.bottom, 24)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.16), radius: 14, y: 8)
                        .rotationEffect(.degrees(-1.2))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.displayTitle)
                            .font(.display)
                            .foregroundStyle(Color.ink)
                        HStack(spacing: 6) {
                            Text(current.feedLine)
                            Text("·").foregroundStyle(Color.inkTertiary)
                            Text(DayFormat.pretty(current.date))
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        if isMine {
                            Pill(systemImage: current.visibility.systemImage, text: current.visibility.label)
                        } else {
                            SavePlaceButton(meal: current, showsLabel: true)
                                .padding(.top, 2)
                        }
                    }

                    if !isMine {
                        NavigationLink {
                            ProfileView(userId: current.userId)
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(profile: author, size: 40)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(author?.name ?? "Someone").font(.headline).foregroundStyle(Color.ink)
                                    if let handle = author?.handle {
                                        Text(handle).font(.caption).foregroundStyle(Color.inkSecondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.inkTertiary)
                            }
                            .card(padding: 12)
                        }
                        .buttonStyle(.plain)
                    }

                    if let notes = current.notes, !notes.isEmpty {
                        PostcardNote(text: notes, code: current.countryCode, tasted: true,
                                     stampSubtitle: String(current.date.prefix(4)))
                    }

                    ReactionBar(
                        tallies: ReactionTally.tally(reactions.map { ($0.emoji, $0.userId) }, me: app.myId),
                        onToggle: { emoji, on in Task { await react(emoji, on: on) } }
                    )

                    Divider()

                    CommentsSection(meal: current)
                }
                .padding(Metrics.gutter)
                .padding(.bottom, 24)
            }
            .paperBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) { menu }
            }
            .sheet(isPresented: $editing) { MealEditorView(mode: .edit(current)) }
            .sheet(isPresented: $reporting) {
                ReportSheet(title: "Report meal") { reason in
                    Task { await app.report("entry", id: current.id, reason: reason) }
                }
            }
            .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("Its photos are deleted too. The cuisine stays stamped unless this was your only meal of it.")
            }
            .confirmationDialog("Block \(author?.name ?? "this person")?", isPresented: $confirmBlock,
                                titleVisibility: .visible) {
                Button("Block", role: .destructive) {
                    Task {
                        await app.block(current.userId)
                        dismiss()
                    }
                }
            } message: {
                Text("They won't show up in your feeds, and you'll stop following them.")
            }
            .overlay { if deleting { SavingOverlay(text: "Deleting…") } }
            .task { await load() }
            .task(id: current) { if isMine { await renderPostcard() } }
            .onChange(of: app.meals) { _, mine in
                // Pick up edits made from the editor sheet.
                if let fresh = mine.first(where: { $0.id == current.id }) { current = fresh }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Menu {
            if isMine {
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                if let shareImage {
                    ShareLink(item: Image(uiImage: shareImage),
                              preview: SharePreview(current.displayTitle, image: Image(uiImage: shareImage))) {
                        Label("Share postcard", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } else {
                Button(role: .destructive) { reporting = true } label: { Label("Report", systemImage: "flag") }
                Button(role: .destructive) { confirmBlock = true } label: {
                    Label("Block \(author?.firstName ?? "")", systemImage: "hand.raised")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }

    private func load() async {
        _ = await app.profiles(for: [current.userId])
        reactions = (try? await app.backend.reactions(mealIds: [current.id])) ?? []
        _ = await app.profiles(for: reactions.map(\.userId))
    }

    private func react(_ emoji: String, on: Bool) async {
        guard let me = app.myId else { return }
        let before = reactions
        reactions.removeAll { $0.userId == me && $0.emoji == emoji }
        if on { reactions.append(Reaction(entryId: current.id, userId: me, emoji: emoji, createdAt: Date())) }
        do {
            try await app.backend.setReaction(mealId: current.id, emoji: emoji, on: on)
        } catch {
            reactions = before
            app.show(error)
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await app.deleteMeal(current)
            app.celebrate("Meal deleted")
            dismiss()
        } catch {
            app.show(error)
        }
    }

    @MainActor
    private func renderPostcard() async {
        var photo: UIImage?
        if let first = current.photos.first {
            photo = await ImagePipeline.shared.image(for: .storage(first), maxPixel: 1280)
        }
        let card = ShareCard {
            VStack(alignment: .leading, spacing: 12) {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 332, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(current.displayTitle)
                            .font(.system(size: 24, weight: .semibold, design: .serif))
                            .foregroundStyle(Color(red: 0.12, green: 0.1, blue: 0.08))
                            .lineLimit(2)
                        Text("\(current.placeLine) · \(DayFormat.pretty(current.date))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(red: 0.42, green: 0.38, blue: 0.33))
                    }
                    Spacer()
                    StampBadge(code: current.countryCode, subtitle: String(current.date.prefix(4)), size: 76, tasted: true)
                }
            }
        }
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        shareImage = renderer.uiImage
    }
}
