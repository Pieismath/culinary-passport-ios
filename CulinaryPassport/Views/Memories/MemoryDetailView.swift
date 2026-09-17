import SwiftUI

/// One memory in full: photos, the story, reactions and comments. Yours get
/// Edit / Share / Delete; other people's get Report / Block.
struct MemoryDetailView: View {
    let memory: Memory

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var current: Memory
    @State private var reactions: [Reaction] = []
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var reporting = false
    @State private var confirmBlock = false
    @State private var shareImage: UIImage?

    init(memory: Memory) {
        self.memory = memory
        _current = State(initialValue: memory)
    }

    private var isMine: Bool { current.userId == app.myId }
    private var author: Profile? { app.profile(current.userId) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PhotoPager(memory: current, aspect: 4.0 / 5.0, cornerRadius: 22, maxPixel: 1800)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.displayTitle)
                            .font(.display)
                            .foregroundStyle(Color.ink)
                        HStack(spacing: 6) {
                            Text("\(current.country?.flag ?? "") \(current.placeLine)")
                            Text("·").foregroundStyle(Color.inkTertiary)
                            Text(DayFormat.pretty(current.date))
                        }
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSecondary)
                        if isMine {
                            Pill(systemImage: current.visibility.systemImage, text: current.visibility.label)
                        } else {
                            SavePlaceButton(memory: current, showsLabel: true)
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
                                    Text(author?.name ?? "Traveller").font(.headline).foregroundStyle(Color.ink)
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
                        PostcardNote(text: notes, code: current.countryCode,
                                     stampSubtitle: String(current.date.prefix(4)))
                    }

                    ReactionBar(
                        tallies: ReactionTally.tally(reactions.map { ($0.emoji, $0.userId) }, me: app.myId),
                        onToggle: { emoji, on in Task { await react(emoji, on: on) } }
                    )

                    Divider()

                    CommentsSection(memory: current)
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
            .sheet(isPresented: $editing) {
                MemoryEditorView(mode: .edit(current))
            }
            .sheet(isPresented: $reporting) {
                ReportSheet(title: "Report memory") { reason in
                    Task { await app.report("entry", id: current.id, reason: reason) }
                }
            }
            .confirmationDialog("Delete this memory?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("Its photos are deleted too. The country stays stamped unless this was your only memory there.")
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
            .onChange(of: app.memories) { _, mine in
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
        reactions = (try? await app.backend.reactions(memoryIds: [current.id])) ?? []
        _ = await app.profiles(for: reactions.map(\.userId))
    }

    private func react(_ emoji: String, on: Bool) async {
        guard let me = app.myId else { return }
        let before = reactions
        reactions.removeAll { $0.userId == me && $0.emoji == emoji }
        if on { reactions.append(Reaction(entryId: current.id, userId: me, emoji: emoji, createdAt: Date())) }
        do {
            try await app.backend.setReaction(memoryId: current.id, emoji: emoji, on: on)
        } catch {
            reactions = before
            app.show(error)
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await app.deleteMemory(current)
            app.celebrate("Memory deleted")
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
                    StampBadge(code: current.countryCode, subtitle: String(current.date.prefix(4)), size: 76)
                }
            }
        }
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        shareImage = renderer.uiImage
    }
}
