import SwiftUI

/// One logged meal, in full: photos, rating, dish, notes — reached by tapping
/// an entry anywhere (globe panel, timeline, photo map). Your own entries get
/// Edit and Delete; someone else's (group globe) are read-only.
struct EntryDetailView: View {
    let entry: Entry
    /// Shown as "logged by …" when the viewer isn't the author (group views).
    var author: Profile? = nil
    /// Called after an edit or delete lands so the presenter can reload.
    var onChanged: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var myId: UUID?
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var reactions: [EntryReaction] = []
    @State private var comments: [EntryComment] = []
    @State private var commentAuthors: [UUID: Profile] = [:]
    @State private var draft = ""
    @State private var pickingEmoji = false
    @State private var reporting = false
    @State private var reportReason = ""
    @State private var status: String?

    private var country: Country? { CountryStore.byCode[entry.countryCode] }
    private var isMine: Bool { myId == entry.userId }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    Text(String(repeating: "★", count: entry.rating))
                        .font(.title3)
                        .foregroundStyle(.orange)

                    if let dish = entry.signatureDish, !dish.isEmpty {
                        Label(dish, systemImage: "fork.knife")
                    }

                    ForEach(entry.photos, id: \.self) { path in
                        SignedPhotoImage(path: path) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color(.secondarySystemBackground)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if let notes = entry.notes, !notes.isEmpty {
                        Text(notes)
                    }

                    footerBadges
                    reactionsRow
                    commentsSection
                }
                .padding()
            }
            .navigationTitle(entry.restaurantName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if isMine {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editing = true }
                    }
                } else {
                    // UGC moderation entry points (App Store 1.2).
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(role: .destructive) { reporting = true } label: {
                                Label("Report this meal", systemImage: "flag")
                            }
                            if let author {
                                Button(role: .destructive) {
                                    Task {
                                        try? await SupabaseService.shared.setBlocked(author.id, true)
                                        status = "\(author.name) blocked. They disappear from your feeds."
                                    }
                                } label: {
                                    Label("Block \(author.name)", systemImage: "hand.raised")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert("Report this meal", isPresented: $reporting) {
                TextField("What's wrong?", text: $reportReason)
                Button("Cancel", role: .cancel) { reportReason = "" }
                Button("Report", role: .destructive) {
                    Task {
                        try? await SupabaseService.shared.report(
                            contentType: "entry", contentId: entry.id,
                            reason: reportReason.isEmpty ? "inappropriate" : reportReason)
                        reportReason = ""
                        status = "Reported. We'll take a look."
                    }
                }
            } message: {
                Text("Tell us what's wrong and we'll review it.")
            }
            .sheet(isPresented: $pickingEmoji) {
                EmojiPickerSheet { emoji in
                    Task { await react(emoji, on: true) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isMine {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label(deleting ? "Deleting…" : "Delete this meal", systemImage: "trash")
                            .font(.subheadline)
                    }
                    .disabled(deleting)
                    .padding(.bottom, 6)
                }
            }
            .task {
                myId = try? await SupabaseService.shared.client.auth.session.user.id
                await loadSocial()
            }
            .sheet(isPresented: $editing) {
                EntrySheet(mode: .edit(entry)) {
                    await onChanged?()
                    dismiss() // the entry shown here is now stale
                }
            }
            .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            } message: {
                Text("\(entry.restaurantName) and its photos will be removed.")
            }
        }
    }

    // ── Reactions & comments (the social loop on a meal) ─────────────────────

    private var tallies: [(emoji: String, count: Int, mine: Bool)] {
        Dictionary(grouping: reactions, by: \.emoji)
            .map { (emoji: $0.key, count: $0.value.count,
                    mine: $0.value.contains { $0.userId == myId }) }
            .sorted { ($0.count, $1.emoji) > ($1.count, $0.emoji) }
    }

    private var reactionsRow: some View {
        HStack(spacing: 6) {
            ForEach(tallies, id: \.emoji) { tally in
                Button {
                    Task { await react(tally.emoji, on: !tally.mine) }
                } label: {
                    HStack(spacing: 3) {
                        Text(tally.emoji)
                        Text("\(tally.count)").monospacedDigit()
                    }
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(tally.mine ? Color.accentColor.opacity(0.18) : Color(.systemGray6),
                                in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Button { pickingEmoji = true } label: {
                Image(systemName: "face.smiling")
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color(.systemGray6), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(.secondaryLabel))
            .accessibilityLabel("Add a reaction")
            Spacer()
        }
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !comments.isEmpty {
                Divider()
                ForEach(comments) { comment in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(commentAuthors[comment.authorId]?.name ?? "Someone")
                            .font(.caption.bold())
                        Text(comment.text).font(.callout)
                        Spacer(minLength: 0)
                    }
                    .contextMenu {
                        if comment.authorId == myId || isMine {
                            Button(role: .destructive) {
                                Task {
                                    try? await SupabaseService.shared.deleteEntryComment(id: comment.id)
                                    comments.removeAll { $0.id == comment.id }
                                }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        if comment.authorId != myId {
                            Button(role: .destructive) {
                                Task {
                                    try? await SupabaseService.shared.report(
                                        contentType: "comment", contentId: comment.id,
                                        reason: "inappropriate")
                                    status = "Reported."
                                }
                            } label: { Label("Report", systemImage: "flag") }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("Say something…", text: $draft)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 16))
                Button {
                    Task { await sendComment() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title3)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
        }
    }

    private func loadSocial() async {
        reactions = (try? await SupabaseService.shared.entryReactions(entryIds: [entry.id])) ?? []
        comments = (try? await SupabaseService.shared.entryComments(entryId: entry.id)) ?? []
        let ids = Array(Set(comments.map(\.authorId)))
        let people = (try? await SupabaseService.shared.profiles(ids: ids)) ?? []
        commentAuthors = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
    }

    private func react(_ emoji: String, on: Bool) async {
        try? await SupabaseService.shared.toggleEntryReaction(entryId: entry.id, emoji: emoji, on: on)
        reactions = (try? await SupabaseService.shared.entryReactions(entryIds: [entry.id])) ?? reactions
    }

    private func sendComment() async {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        do {
            try await SupabaseService.shared.addEntryComment(entryId: entry.id, text: text)
            draft = ""
            await loadSocial()
        } catch { status = error.localizedDescription }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(country?.flagEmoji ?? "🌍").font(.largeTitle)
            VStack(alignment: .leading, spacing: 2) {
                Text(country?.cuisineName ?? entry.countryCode).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
            Spacer()
        }
    }

    private var subtitle: String {
        var parts = [Self.pretty(entry.dateTried)]
        if let city = entry.city, !city.isEmpty { parts.append(city) }
        if let author, !isMine { parts.append("logged by \(author.name)") }
        return parts.joined(separator: " · ")
    }

    private var footerBadges: some View {
        HStack(spacing: 8) {
            if let visibility = entry.visibility {
                Label(visibilityText(visibility), systemImage: visibilityIcon(visibility))
            }
            if entry.wouldReturn {
                Label("Would return", systemImage: "arrow.uturn.left.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(Color(.secondaryLabel))
    }

    private func visibilityText(_ v: Entry.Visibility) -> String {
        switch v {
        case .public: "Public"
        case .groups: "My groups"
        case .private: "Only me"
        }
    }

    private func visibilityIcon(_ v: Entry.Visibility) -> String {
        switch v {
        case .public: "globe"
        case .groups: "person.3"
        case .private: "lock"
        }
    }

    private func delete() async {
        deleting = true
        defer { deleting = false }
        do {
            try await SupabaseService.shared.deleteEntry(entry)
            await onChanged?()
            dismiss()
        } catch {
            // leave the sheet up; the button re-enables for a retry
        }
    }

    private static let parse: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func pretty(_ raw: String) -> String {
        guard let date = parse.date(from: raw) else { return raw }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
